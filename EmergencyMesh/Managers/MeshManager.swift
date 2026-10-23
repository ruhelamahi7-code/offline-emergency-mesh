//
//  MeshManager.swift
//  EmergencyMesh
//
//  Created by MAHI RUHELA on 23/10/26.
//

import Foundation
import MultipeerConnectivity
import CryptoKit
import Combine
import UIKit

// MARK: - Packet Types

enum MeshPacketType: String, Codable {
    case message
    case discoveryToken
    case heartbeat
}

// MARK: - Mesh Packet

struct MeshPacket: Codable, Identifiable {
    var id: UUID = UUID()
    var senderID: String
    var timestamp: Date = Date()
    var ttl: Int = 5 // Default TTL: 5 hops
    var isEncrypted: Bool
    var payload: Data
    var packetType: MeshPacketType = .message
}

// MARK: - Routed Message for UI Feed

struct RoutedMessage: Identifiable, Equatable {
    let id: UUID
    let senderID: String
    let content: String
    let timestamp: Date
    let hops: Int
    let isEncrypted: Bool
    let isTokenExchange: Bool
}

// MARK: - Mesh Manager

class MeshManager: NSObject, ObservableObject {
    // Exactly matches _emerg-mesh._tcp and _emerg-mesh._udp from Info.plist
    private let serviceType = "emerg-mesh"
    private static let callsignKey = "user_callsign"

    static func getStoredCallsign() -> String {
        if let saved = UserDefaults.standard.string(forKey: callsignKey),
           !saved.trimmingCharacters(in: .whitespaces).isEmpty {
            return saved
        }
        let fallback = "Survivor-\(Int.random(in: 100...999))"
        UserDefaults.standard.set(fallback, forKey: callsignKey)
        return fallback
    }

    @Published var userCallsign: String
    public private(set) var myPeerID: MCPeerID

    private var serviceAdvertiser: MCNearbyServiceAdvertiser
    private var serviceBrowser: MCNearbyServiceBrowser
    private var session: MCSession

    private var seenPacketIDs: Set<UUID> = []
    private let cacheLock = NSLock()
    private var heartbeatTimer: Timer?

    // Shared mesh symmetric key (AES-256 GCM)
    public var symmetricKey: SymmetricKey = {
        let keyMaterial = "EmergencyMesh-Secured-AdHoc-Network-2026"
        let digest = SHA256.hash(data: Data(keyMaterial.utf8))
        return SymmetricKey(data: digest)
    }()

    @Published var connectedPeers: [MCPeerID] = []
    @Published var receivedMessages: [String] = []
    @Published var routedMessages: [RoutedMessage] = []
    @Published var receivedPeerTokens: [String: Data] = [:]

    // Closures
    var onTokenReceived: ((MCPeerID, Data) -> Void)?
    var onPeerConnected: ((MCPeerID) -> Void)?
    var onPeerDisconnected: ((MCPeerID) -> Void)?
    var localDiscoveryTokenProvider: ((MCPeerID) -> Data?)?

    override init() {
        let callsign = Self.getStoredCallsign()
        self.userCallsign = callsign
        let peer = MCPeerID(displayName: callsign)
        self.myPeerID = peer

        self.session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        self.serviceAdvertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: nil, serviceType: serviceType)
        self.serviceBrowser = MCNearbyServiceBrowser(peer: peer, serviceType: serviceType)

        super.init()

        self.session.delegate = self
        self.serviceAdvertiser.delegate = self
        self.serviceBrowser.delegate = self

        startNetworking()
        startHeartbeat()
    }

    deinit {
        stopHeartbeat()
        stopNetworking()
    }

    // MARK: - Callsign Management

    func updateCallsign(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != userCallsign else { return }

        UserDefaults.standard.set(trimmed, forKey: Self.callsignKey)
        self.userCallsign = trimmed

        stopHeartbeat()
        stopNetworking()

        let newPeer = MCPeerID(displayName: trimmed)
        self.myPeerID = newPeer
        self.session = MCSession(peer: newPeer, securityIdentity: nil, encryptionPreference: .required)
        self.serviceAdvertiser = MCNearbyServiceAdvertiser(peer: newPeer, discoveryInfo: nil, serviceType: serviceType)
        self.serviceBrowser = MCNearbyServiceBrowser(peer: newPeer, serviceType: serviceType)

        self.session.delegate = self
        self.serviceAdvertiser.delegate = self
        self.serviceBrowser.delegate = self

        startNetworking()
        startHeartbeat()
    }

    func updateUserCallsign(_ name: String) {
        updateCallsign(name)
    }

    // MARK: - Networking Lifecycle

    func startNetworking() {
        serviceAdvertiser.startAdvertisingPeer()
        serviceBrowser.startBrowsingForPeers()
    }

    func stopNetworking() {
        serviceAdvertiser.stopAdvertisingPeer()
        serviceBrowser.stopBrowsingForPeers()
        session.disconnect()
    }

    // MARK: - 3.5s Untethered Radio Keep-Alive Heartbeat

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: true) { [weak self] _ in
            self?.sendHeartbeat()
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func sendHeartbeat() {
        guard !session.connectedPeers.isEmpty else { return }
        let ping = MeshPacket(
            id: UUID(),
            senderID: myPeerID.displayName,
            timestamp: Date(),
            ttl: 1,
            isEncrypted: false,
            payload: Data([0x01]),
            packetType: .heartbeat
        )

        _ = registerPacketIfUnseen(id: ping.id)
        if let data = try? JSONEncoder().encode(ping) {
            let targetPeers = session.connectedPeers
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else { return }
                try? self.session.send(data, toPeers: targetPeers, with: .unreliable)
            }
        }
    }

    // MARK: - Thread-Safe Deduplication Cache

    private func registerPacketIfUnseen(id: UUID) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if seenPacketIDs.contains(id) {
            return false
        }
        seenPacketIDs.insert(id)
        return true
    }

    // MARK: - CryptoKit Helpers (AES.GCM)

    func encrypt(text: String, using key: SymmetricKey) -> Data {
        guard let data = text.data(using: .utf8),
              let sealedBox = try? AES.GCM.seal(data, using: key),
              let combined = sealedBox.combined else {
            return Data()
        }
        return combined
    }

    func decrypt(data: Data, using key: SymmetricKey) -> String? {
        guard let sealedBox = try? AES.GCM.SealedBox(combined: data),
              let opened = try? AES.GCM.open(sealedBox, using: key),
              let decryptedString = String(data: opened, encoding: .utf8) else {
            return nil
        }
        return decryptedString
    }

    // MARK: - Broadcast and Multi-Hop Messaging

    func send(message: String, isEncrypted: Bool = true) {
        let payloadData: Data
        if isEncrypted {
            payloadData = encrypt(text: message, using: symmetricKey)
        } else {
            payloadData = message.data(using: .utf8) ?? Data()
        }

        let packet = MeshPacket(
            id: UUID(),
            senderID: myPeerID.displayName,
            timestamp: Date(),
            ttl: 5,
            isEncrypted: isEncrypted,
            payload: payloadData,
            packetType: .message
        )

        _ = registerPacketIfUnseen(id: packet.id)

        let routed = RoutedMessage(
            id: packet.id,
            senderID: "Me",
            content: message,
            timestamp: packet.timestamp,
            hops: 0,
            isEncrypted: isEncrypted,
            isTokenExchange: false
        )

        DispatchQueue.main.async {
            self.routedMessages.append(routed)
            self.receivedMessages.append("Me: \(message)")
        }

        broadcastPacket(packet)
    }

    // MARK: - Discovery Token Exchange

    func sendDiscoveryToken(_ tokenData: Data, to peer: MCPeerID) {
        let packet = MeshPacket(
            id: UUID(),
            senderID: myPeerID.displayName,
            timestamp: Date(),
            ttl: 1, // Direct point-to-point token exchange
            isEncrypted: false,
            payload: tokenData,
            packetType: .discoveryToken
        )

        _ = registerPacketIfUnseen(id: packet.id)
        if let data = try? JSONEncoder().encode(packet) {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                try? self?.session.send(data, toPeers: [peer], with: .reliable)
            }
        }
    }

    func broadcastDiscoveryToken(_ tokenData: Data) {
        guard !session.connectedPeers.isEmpty else { return }
        let packet = MeshPacket(
            id: UUID(),
            senderID: myPeerID.displayName,
            timestamp: Date(),
            ttl: 1,
            isEncrypted: false,
            payload: tokenData,
            packetType: .discoveryToken
        )

        _ = registerPacketIfUnseen(id: packet.id)
        if let data = try? JSONEncoder().encode(packet) {
            let targetPeers = session.connectedPeers
            DispatchQueue.global(qos: .utility).async { [weak self] in
                try? self?.session.send(data, toPeers: targetPeers, with: .reliable)
            }
        }
    }

    private func broadcastPacket(_ packet: MeshPacket) {
        guard !session.connectedPeers.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(packet) else { return }
        let targetPeers = session.connectedPeers

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                try self?.session.send(data, toPeers: targetPeers, with: .reliable)
            } catch {
                print("Failed to broadcast packet: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MeshManager: MCNearbyServiceAdvertiserDelegate {
    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        invitationHandler(true, session)
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MeshManager: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        print("Lost peer: \(peerID.displayName)")
    }

    func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        let shouldInvite = myPeerID.displayName > peerID.displayName
        if shouldInvite {
            print("Inviting peer: \(peerID.displayName)")
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
        }
    }
}

// MARK: - MCSessionDelegate

extension MeshManager: MCSessionDelegate {
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: (any Error)?) {}

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            self.connectedPeers = session.connectedPeers

            switch state {
            case .connected:
                print("Connected to peer: \(peerID.displayName)")
                // Pause aggressive browsing once connected to reduce 2.4GHz radio collisions; keep advertising active
                if session.connectedPeers.count >= 1 {
                    self.serviceBrowser.stopBrowsingForPeers()
                }

                if let tokenData = self.localDiscoveryTokenProvider?(peerID) {
                    self.sendDiscoveryToken(tokenData, to: peerID)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self = self else { return }
                        if let retryToken = self.localDiscoveryTokenProvider?(peerID) {
                            self.sendDiscoveryToken(retryToken, to: peerID)
                        }
                    }
                }
                self.onPeerConnected?(peerID)

            case .notConnected:
                print("Disconnected from peer: \(peerID.displayName)")
                self.receivedPeerTokens.removeValue(forKey: peerID.displayName)
                self.onPeerDisconnected?(peerID)

                // Trigger an auto-reconnect backoff (resume browsing after 1.5 seconds)
                if session.connectedPeers.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self = self, self.session.connectedPeers.isEmpty else { return }
                        print("[MeshManager] Auto-reconnect triggered: resuming browsing...")
                        self.serviceBrowser.startBrowsingForPeers()
                    }
                }

            case .connecting:
                print("Connecting to peer: \(peerID.displayName)...")

            @unknown default:
                break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let packet = try? JSONDecoder().decode(MeshPacket.self, from: data) else {
            return
        }

        // Loop Prevention: Register packet ID and drop duplicates
        guard registerPacketIfUnseen(id: packet.id) else {
            return
        }

        // Heartbeat keep-alive: silently drop without adding to UI feed
        if packet.packetType == .heartbeat {
            return
        }

        // Handle UWB Discovery Token Exchange
        if packet.packetType == .discoveryToken {
            DispatchQueue.main.async {
                self.receivedPeerTokens[packet.senderID] = packet.payload
                self.onTokenReceived?(peerID, packet.payload)

                if let myToken = self.localDiscoveryTokenProvider?(peerID) {
                    self.sendDiscoveryToken(myToken, to: peerID)
                }
            }
            return
        }

        // Handle Decrypted / Plaintext Emergency Message
        let messageText: String?
        if packet.isEncrypted {
            messageText = decrypt(data: packet.payload, using: symmetricKey)
        } else {
            messageText = String(data: packet.payload, encoding: .utf8)
        }

        if let content = messageText {
            let hops = max(0, 5 - packet.ttl)
            let routed = RoutedMessage(
                id: packet.id,
                senderID: packet.senderID,
                content: content,
                timestamp: packet.timestamp,
                hops: hops,
                isEncrypted: packet.isEncrypted,
                isTokenExchange: false
            )

            DispatchQueue.main.async {
                self.routedMessages.append(routed)
                self.receivedMessages.append("\(packet.senderID): \(content)")
            }
        }

        // Multi-Hop Relaying across mesh
        if packet.ttl > 1 {
            var relayPacket = packet
            relayPacket.ttl -= 1

            if let relayData = try? JSONEncoder().encode(relayPacket) {
                let otherPeers = session.connectedPeers.filter { $0 != peerID }
                if !otherPeers.isEmpty {
                    DispatchQueue.global(qos: .utility).async { [weak self] in
                        try? self?.session.send(relayData, toPeers: otherPeers, with: .reliable)
                    }
                }
            }
        }
    }
}
