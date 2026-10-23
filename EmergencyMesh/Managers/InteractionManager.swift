//
//  InteractionManager.swift
//  EmergencyMesh
//
//  Created by Antigravity on 23/10/26.
//

import Foundation
import NearbyInteraction
import MultipeerConnectivity
import UIKit
import simd
import Combine

class InteractionManager: NSObject, ObservableObject {
    @Published var distance: Float? = nil
    @Published var direction: simd_float3? = nil
    @Published var isUWBSupported: Bool = InteractionManager.checkUWBSupport()
    @Published var isTracking: Bool = false
    @Published var activePeerName: String? = nil
    @Published var availableTrackedPeers: [String] = []

    // Multi-peer storage: Separate NISession per connected peer
    private var peerSessions: [String: NISession] = [:]
    private var peerTokens: [String: NIDiscoveryToken] = [:]
    public var peerMeasurements: [String: (distance: Float?, direction: simd_float3?)] = [:]

    // Haptics
    private var hapticTimer: Timer?
    private var currentHapticInterval: TimeInterval = 0
    private let hapticGenerator = UIImpactFeedbackGenerator(style: .rigid)

    // MARK: - Hardware Support Check

    static func checkUWBSupport() -> Bool {
        if #available(iOS 16.0, *) {
            return NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
        } else {
            return NISession.isSupported
        }
    }

    override init() {
        super.init()
        isUWBSupported = InteractionManager.checkUWBSupport()
        hapticGenerator.prepare()
    }

    deinit {
        stopHapticPulse()
        for session in peerSessions.values {
            session.invalidate()
        }
        peerSessions.removeAll()
    }

    // MARK: - Token Management for Multi-Peer Mesh

    /// Retrieves or generates a serialized discovery token for a specific peer
    func token(for peerID: MCPeerID) -> Data? {
        guard isUWBSupported else { return nil }

        let session = getOrCreateSession(for: peerID.displayName)
        guard let token = session.discoveryToken else { return nil }

        return try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private func getOrCreateSession(for peerName: String) -> NISession {
        if let existing = peerSessions[peerName] {
            return existing
        }
        let newSession = NISession()
        newSession.delegate = self
        peerSessions[peerName] = newSession
        return newSession
    }

    /// Handles a received discovery token from a peer and initiates real-time ranging
    func receiveToken(peerID: MCPeerID, tokenData: Data) {
        guard isUWBSupported else {
            print("UWB not supported on this device.")
            return
        }

        do {
            guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: tokenData) else {
                print("Failed to unarchive NIDiscoveryToken from \(peerID.displayName)")
                return
            }

            peerTokens[peerID.displayName] = token

            let session = getOrCreateSession(for: peerID.displayName)
            let config = NINearbyPeerConfiguration(peerToken: token)
            session.run(config)

            DispatchQueue.main.async {
                if !self.availableTrackedPeers.contains(peerID.displayName) {
                    self.availableTrackedPeers.append(peerID.displayName)
                }

                if self.activePeerName == nil {
                    self.activePeerName = peerID.displayName
                }

                self.isTracking = true
            }

            print("Started active UWB session with \(peerID.displayName)")
        } catch {
            print("Error initializing NearbyInteraction for \(peerID.displayName): \(error.localizedDescription)")
        }
    }

    func selectActivePeer(_ peerName: String) {
        activePeerName = peerName
        if let measurement = peerMeasurements[peerName] {
            distance = measurement.distance
            direction = measurement.direction
            updateHaptics(for: measurement.distance)
        } else {
            distance = nil
            direction = nil
        }
    }

    func removePeer(displayName: String) {
        if let session = peerSessions.removeValue(forKey: displayName) {
            session.invalidate()
        }
        peerTokens.removeValue(forKey: displayName)
        peerMeasurements.removeValue(forKey: displayName)

        DispatchQueue.main.async {
            self.availableTrackedPeers.removeAll { $0 == displayName }
            if self.activePeerName == displayName {
                self.activePeerName = self.availableTrackedPeers.first
                if let next = self.activePeerName, let m = self.peerMeasurements[next] {
                    self.distance = m.distance
                    self.direction = m.direction
                } else {
                    self.distance = nil
                    self.direction = nil
                    self.stopHapticPulse()
                }
            }
        }
    }

    func stopTracking() {
        stopHapticPulse()
        DispatchQueue.main.async {
            self.isTracking = false
        }
    }

    // MARK: - Simulation Helper (strictly for Simulator preview)

    #if targetEnvironment(simulator)
    func simulateTarget(distance: Float, direction: simd_float3) {
        DispatchQueue.main.async {
            self.distance = distance
            self.direction = direction
            self.isTracking = true
            self.updateHaptics(for: distance)
        }
    }
    #endif

    // MARK: - Haptic Heartbeat Feedback

    private func updateHaptics(for distance: Float?) {
        guard let dist = distance, dist < 2.0, dist > 0 else {
            stopHapticPulse()
            return
        }

        // Pulse rate increases as distance drops below 2 meters (0.2s interval at 0.1m, 1.2s interval at 2.0m)
        let clamped = max(0.1, min(2.0, dist))
        let normalized = Double((clamped - 0.1) / 1.9)
        let newInterval = 0.20 + (normalized * 1.0)

        if hapticTimer == nil || abs(currentHapticInterval - newInterval) > 0.12 {
            currentHapticInterval = newInterval
            startHapticPulse(interval: newInterval)
        }
    }

    private func startHapticPulse(interval: TimeInterval) {
        hapticTimer?.invalidate()
        hapticTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.hapticGenerator.impactOccurred()
        }
        hapticGenerator.impactOccurred()
    }

    private func stopHapticPulse() {
        hapticTimer?.invalidate()
        hapticTimer = nil
        currentHapticInterval = 0
    }
}

// MARK: - NISessionDelegate

extension InteractionManager: NISessionDelegate {
    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let peerObject = nearbyObjects.first else { return }

        // Find which peer this session belongs to
        let matchedPeerName = peerSessions.first(where: { $0.value === session })?.key

        DispatchQueue.main.async {
            if let peerName = matchedPeerName {
                self.peerMeasurements[peerName] = (peerObject.distance, peerObject.direction)

                if self.activePeerName == nil || self.activePeerName == peerName {
                    self.activePeerName = peerName
                    self.distance = peerObject.distance
                    self.direction = peerObject.direction
                    self.updateHaptics(for: peerObject.distance)
                }
            }
        }
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        let matchedPeerName = peerSessions.first(where: { $0.value === session })?.key
        DispatchQueue.main.async {
            if let peerName = matchedPeerName {
                self.peerMeasurements[peerName] = (nil, nil)
                if self.activePeerName == peerName {
                    self.distance = nil
                    self.direction = nil
                    self.stopHapticPulse()
                }
            }
        }
    }

    func sessionWasSuspended(_ session: NISession) {
        stopHapticPulse()
    }

    func sessionSuspensionEnded(_ session: NISession) {
        // Automatically resumes
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        let matchedPeerName = peerSessions.first(where: { $0.value === session })?.key
        if let peerName = matchedPeerName {
            peerSessions.removeValue(forKey: peerName)
        }
    }
}
