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
import AudioToolbox

class InteractionManager: NSObject, ObservableObject {
    @Published var distance: Float? = nil
    @Published var direction: simd_float3? = nil
    @Published var isUWBSupported: Bool = InteractionManager.checkUWBSupport()
    @Published var isTracking: Bool = false
    @Published var activePeerName: String? = nil
    @Published var availableTrackedPeers: [String] = []

    // Proximity Pulse & Feedback
    @Published var pulseVisualTick: Bool = false
    @Published var isDemoMode: Bool = false
    @Published var demoDistance: Float = 2.4
    @Published var demoAngleDegrees: Double = 45.0

    // Multi-peer storage: Separate active NISession and configuration per connected peer
    private var peerSessions: [String: NISession] = [:]
    private var peerTokens: [String: NIDiscoveryToken] = [:]
    private var peerConfigurations: [String: NINearbyPeerConfiguration] = [:]
    public var peerMeasurements: [String: (distance: Float?, direction: simd_float3?)] = [:]

    // Haptics & Audible Sonar Beep
    private var sonarTimer: Timer?
    private var currentSonarInterval: TimeInterval = 0
    private let hapticGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private var demoApproachTimer: Timer?

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
        stopSonarPulse()
        stopDemoApproach()
        for session in peerSessions.values {
            session.invalidate()
        }
        peerSessions.removeAll()
        peerConfigurations.removeAll()
    }

    // MARK: - Dedicated Per-Peer NISession & Token Exchange

    /// CRITICAL FIX: The discovery token sent to a peer MUST come from the exact same NISession instance that runs for that peer
    func token(for peerID: MCPeerID) -> Data? {
        guard isUWBSupported else { return nil }

        let session = getOrCreateSession(for: peerID.displayName)
        guard let token = session.discoveryToken else {
            print("[InteractionManager] Warning: discoveryToken is nil for \(peerID.displayName)")
            return nil
        }

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

    /// Handles received discovery token and executes session.run with matching NISession
    func receiveToken(peerID: MCPeerID, tokenData: Data) {
        guard isUWBSupported else {
            print("[InteractionManager] UWB not supported on this device.")
            return
        }

        do {
            guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: tokenData) else {
                print("[InteractionManager] Failed to unarchive NIDiscoveryToken from \(peerID.displayName)")
                return
            }

            peerTokens[peerID.displayName] = token

            // Fetch the exact matching session instance
            let session = getOrCreateSession(for: peerID.displayName)
            session.delegate = self
            let config = NINearbyPeerConfiguration(peerToken: token)
            peerConfigurations[peerID.displayName] = config
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

            print("[InteractionManager] Active UWB session paired & running for \(peerID.displayName)")
        } catch {
            print("[InteractionManager] Error initializing NearbyInteraction for \(peerID.displayName): \(error.localizedDescription)")
        }
    }

    func selectActivePeer(_ peerName: String) {
        activePeerName = peerName
        if let measurement = peerMeasurements[peerName] {
            distance = measurement.distance
            direction = measurement.direction
            updateSonar(for: measurement.distance)
        } else {
            distance = nil
            direction = nil
            if !isDemoMode {
                stopSonarPulse()
            }
        }
    }

    func removePeer(displayName: String) {
        if let session = peerSessions.removeValue(forKey: displayName) {
            session.invalidate()
        }
        peerTokens.removeValue(forKey: displayName)
        peerConfigurations.removeValue(forKey: displayName)
        peerMeasurements.removeValue(forKey: displayName)

        DispatchQueue.main.async {
            self.availableTrackedPeers.removeAll { $0 == displayName }
            if self.activePeerName == displayName {
                self.activePeerName = self.availableTrackedPeers.first
                if let next = self.activePeerName, let m = self.peerMeasurements[next] {
                    self.distance = m.distance
                    self.direction = m.direction
                    self.updateSonar(for: m.distance)
                } else {
                    if !self.isDemoMode {
                        self.distance = nil
                        self.direction = nil
                        self.stopSonarPulse()
                    }
                }
            }
        }
    }

    func stopTracking() {
        stopSonarPulse()
        stopDemoApproach()
        DispatchQueue.main.async {
            self.isTracking = false
        }
    }

    // MARK: - Live Demo Simulator Mode (Available on Real Devices for Presentations)

    func toggleDemoMode(_ enabled: Bool) {
        isDemoMode = enabled
        if enabled {
            applyDemoValues()
        } else {
            stopDemoApproach()
            if let active = activePeerName, let m = peerMeasurements[active] {
                distance = m.distance
                direction = m.direction
                updateSonar(for: m.distance)
            } else {
                distance = nil
                direction = nil
                stopSonarPulse()
            }
        }
    }

    func updateDemoDistance(_ newDistance: Float) {
        demoDistance = newDistance
        if isDemoMode {
            applyDemoValues()
        }
    }

    func updateDemoAngle(_ degrees: Double) {
        demoAngleDegrees = degrees
        if isDemoMode {
            applyDemoValues()
        }
    }

    private func applyDemoValues() {
        let radians = demoAngleDegrees * .pi / 180.0
        let dir = simd_float3(x: Float(sin(radians)), y: Float(cos(radians)), z: 0.0)

        DispatchQueue.main.async {
            self.distance = self.demoDistance
            self.direction = dir
            self.isTracking = true
            self.updateSonar(for: self.demoDistance)
        }
    }

    func startSimulatedApproach() {
        stopDemoApproach()
        isDemoMode = true
        demoDistance = 3.5
        demoAngleDegrees = 30.0
        applyDemoValues()

        demoApproachTimer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            if self.demoDistance > 0.25 {
                self.demoDistance = max(0.20, self.demoDistance - 0.08)
                self.demoAngleDegrees = (self.demoAngleDegrees + 3.0).truncatingRemainder(dividingBy: 360.0)
                self.applyDemoValues()
            } else {
                timer.invalidate()
                self.demoApproachTimer = nil
            }
        }
    }

    func stopDemoApproach() {
        demoApproachTimer?.invalidate()
        demoApproachTimer = nil
    }

    // MARK: - Accelerating Sonar Beep + Heavy Haptic Heartbeat

    private func updateSonar(for targetDistance: Float?) {
        guard let dist = targetDistance, dist > 0.05, dist <= 5.0 else {
            stopSonarPulse()
            return
        }

        // Interval speeds up from 1.2s at 5.0m down to 0.15s at <= 0.3m
        let clamped = max(0.3, min(5.0, dist))
        let normalized = (clamped - 0.3) / 4.7
        let newInterval = 0.15 + Double(normalized) * (1.20 - 0.15)

        if sonarTimer == nil || abs(currentSonarInterval - newInterval) > 0.08 {
            currentSonarInterval = newInterval
            startSonarPulse(interval: newInterval)
        }
    }

    private func startSonarPulse(interval: TimeInterval) {
        sonarTimer?.invalidate()
        sonarTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.triggerPulseTick()
        }
        triggerPulseTick()
    }

    private func triggerPulseTick() {
        // Heavy haptic feedback
        hapticGenerator.impactOccurred(intensity: 1.0)

        // Audible system sonar ping (1104 is a crisp navigation tap sound; 1052 is short tick)
        AudioServicesPlaySystemSound(1104)

        // Visual flash tick trigger
        DispatchQueue.main.async {
            self.pulseVisualTick.toggle()
        }
    }

    private func stopSonarPulse() {
        sonarTimer?.invalidate()
        sonarTimer = nil
        currentSonarInterval = 0
    }
}

// MARK: - NISessionDelegate

extension InteractionManager: NISessionDelegate {
    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let peerObject = nearbyObjects.first else { return }

        let matchedPeerName = peerSessions.first(where: { $0.value === session })?.key

        DispatchQueue.main.async {
            guard !self.isDemoMode else { return }

            if let peerName = matchedPeerName {
                let fallbackDir = self.peerMeasurements[peerName]?.direction ?? simd_float3(x: 0, y: 1, z: 0)
                let resolvedDirection = peerObject.direction ?? fallbackDir

                self.peerMeasurements[peerName] = (peerObject.distance, resolvedDirection)

                if self.activePeerName == nil || self.activePeerName == peerName {
                    self.activePeerName = peerName
                    self.distance = peerObject.distance
                    self.direction = resolvedDirection
                    self.updateSonar(for: peerObject.distance)
                }
            }
        }
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        let matchedPeerName = peerSessions.first(where: { $0.value === session })?.key
        DispatchQueue.main.async {
            guard !self.isDemoMode else { return }

            if let peerName = matchedPeerName {
                self.peerMeasurements[peerName] = (nil, nil)
                if self.activePeerName == peerName {
                    self.distance = nil
                    self.direction = nil
                    self.stopSonarPulse()
                }
            }
        }
    }

    func sessionWasSuspended(_ session: NISession) {
        if !isDemoMode {
            stopSonarPulse()
        }
    }

    func sessionSuspensionEnded(_ session: NISession) {
        if let matchedPeerName = peerSessions.first(where: { $0.value === session })?.key,
           let config = peerConfigurations[matchedPeerName] {
            session.run(config)
        }
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        let matchedPeerName = peerSessions.first(where: { $0.value === session })?.key
        if let peerName = matchedPeerName {
            peerSessions.removeValue(forKey: peerName)
            peerConfigurations.removeValue(forKey: peerName)
        }
    }
}
