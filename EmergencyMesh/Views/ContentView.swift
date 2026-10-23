import SwiftUI
import MultipeerConnectivity
import simd

struct ContentView: View {
    @StateObject private var meshManager = MeshManager()
    @StateObject private var soundManager = SoundListenerManager()
    @StateObject private var interactionManager = InteractionManager()

    @State private var messageText = ""
    @State private var isEmergencyTriggered = false
    @State private var activeEmergencyMessage: String? = nil
    @State private var activeEmergencySender: String? = nil
    @State private var showFinderSheet = false

    // Callsign Alert State
    @State private var showCallsignAlert = false
    @State private var callsignInputText = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                VStack(spacing: 10) {
                    // Profile Callsign Bar
                    callsignProfileBar

                    // Layer 1: Pinned Active Critical SOS Alert
                    if let activeEmergency = activeEmergencyMessage {
                        pinnedSOSBanner(message: activeEmergency)
                    }

                    // Header Status Bar (Mesh Peers & Acoustic Guard)
                    headerStatusBar

                    // Layer 2: Live On-Device ML Sound Guard Card
                    soundAnalysisCard

                    // Mesh Network Feed Header
                    meshFeedHeader

                    // Multi-hop Decrypted Mesh Feed
                    messageFeedSection

                    // Quick SOS Resource Grid
                    quickResourceGridSection

                    // Bottom Encrypted Broadcast Bar
                    broadcastBarSection
                }
            }
            .navigationTitle("EmergencyMesh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showFinderSheet = true
                    }) {
                        Image(systemName: "location.viewfinder")
                            .font(.headline)
                            .foregroundColor(.blue)
                    }
                }
            }
            .sheet(isPresented: $showFinderSheet) {
                DirectionalFinderSheet(
                    interactionManager: interactionManager,
                    meshManager: meshManager
                )
            }
            .alert("Edit Callsign", isPresented: $showCallsignAlert) {
                TextField("Callsign (e.g. Survivor-42)", text: $callsignInputText)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    meshManager.updateCallsign(callsignInputText)
                }
            } message: {
                Text("Set a distinct identifier so nearby rescue devices recognize you across the offline mesh.")
            }
            .onAppear {
                setupEventCallbacks()
                soundManager.startListening()
            }
        }
    }

    // MARK: - Wiring Up Event Callbacks

    private func setupEventCallbacks() {
        meshManager.localDiscoveryTokenProvider = { peerID in
            return interactionManager.token(for: peerID)
        }

        meshManager.onTokenReceived = { peerID, tokenData in
            interactionManager.receiveToken(peerID: peerID, tokenData: tokenData)
        }

        meshManager.onPeerDisconnected = { peerID in
            interactionManager.removePeer(displayName: peerID.displayName)
        }

        soundManager.onEmergencySoundVerified = { detectedSound in
            triggerEmergencyConsensus(reason: detectedSound)
        }
    }

    // MARK: - Callsign Profile Bar

    private var callsignProfileBar: some View {
        HStack {
            Button(action: {
                callsignInputText = meshManager.userCallsign
                showCallsignAlert = true
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.caption)
                        .foregroundColor(.blue)

                    Text("Callsign: \(meshManager.userCallsign)")
                        .font(.caption.bold())
                        .foregroundColor(.primary)

                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
            }

            Spacer()

            HStack(spacing: 5) {
                Circle()
                    .fill(meshManager.connectedPeers.isEmpty ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(meshManager.connectedPeers.isEmpty ? "Mesh: Scanning" : "\(meshManager.connectedPeers.count) Peer(s) Live")
                    .font(.caption.bold())
                    .foregroundColor(meshManager.connectedPeers.isEmpty ? .orange : .green)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(8)
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    // MARK: - Header Status Bar

    private var headerStatusBar: some View {
        HStack {
            Image(systemName: soundManager.isListening ? "ear.and.waveform" : "ear.badge.exclamationmark")
                .foregroundColor(soundManager.isListening ? .green : .orange)

            Text(soundManager.isListening ? "Neural Acoustic Guard Active" : "Sound Guard Paused")
                .font(.subheadline.bold())
                .foregroundColor(.primary)

            Spacer()
        }
        .padding(.horizontal)
    }

    // MARK: - Layer 1: Pinned SOS Alert

    private func pinnedSOSBanner(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ACTIVE CRITICAL EMERGENCY")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                    if let sender = activeEmergencySender {
                        Text(sender == "Me" ? "From: You" : "From: \(sender)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                    }
                }

                Spacer()

                Button(action: {
                    withAnimation {
                        let ackMessage = "✅ [RESOLVED] Emergency acknowledged & handled by \(meshManager.userCallsign)."
                        meshManager.send(message: ackMessage, isEncrypted: true)
                        activeEmergencyMessage = nil
                        activeEmergencySender = nil
                        isEmergencyTriggered = false
                    }
                }) {
                    Text("Resolve & Broadcast")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white)
                        .foregroundColor(.red)
                        .cornerRadius(6)
                }
            }

            Text(message)
                .font(.subheadline)
                .foregroundColor(.white)
                .lineLimit(2)

            Button(action: {
                if let sender = activeEmergencySender, sender != "Me" {
                    interactionManager.selectActivePeer(sender)
                }
                showFinderSheet = true
            }) {
                HStack {
                    Image(systemName: "location.viewfinder")
                    Text("Open UWB Precision Finder")
                        .font(.caption.bold())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.2))
                .foregroundColor(.white)
                .cornerRadius(6)
            }
        }
        .padding(12)
        .background(Color.red)
        .cornerRadius(12)
        .shadow(color: Color.red.opacity(0.3), radius: 6, y: 2)
        .padding(.horizontal)
    }

    // MARK: - Layer 2: Live Sound Guard Card

    private var soundAnalysisCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Apple Neural Engine SoundAnalysis", systemImage: "waveform.badge.magnifyingglass")
                    .font(.subheadline.bold())
                Spacer()
                if soundManager.isListening {
                    Text(String(format: "%.1f dB", soundManager.currentDecibels))
                        .font(.caption.monospaced().bold())
                        .foregroundColor(soundManager.currentDecibels > -20.0 ? .red : .primary)
                }
            }

            Text(soundManager.isListening
                 ? (soundManager.detectedEmergencySound != nil
                    ? "Listening with Apple Neural Engine... Active / Last heard: \(soundManager.detectedEmergencySound!)"
                    : "Listening with Apple Neural Engine... Active (Zero-Disk RAM Buffer)")
                 : "Acoustic Guard Paused (Tap Start to enable on-device detection)")
                .font(.caption)
                .foregroundColor(soundManager.detectedEmergencySound != nil ? .red : .secondary)

            HStack(spacing: 10) {
                Button(action: {
                    if soundManager.isListening {
                        soundManager.stopListening()
                    } else {
                        soundManager.startListening()
                    }
                }) {
                    Text(soundManager.isListening ? "Stop Guard" : "Start Guard")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(soundManager.isListening ? Color.orange : Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }

                Button(action: {
                    soundManager.simulateDetection(sound: "Fire Alarm")
                }) {
                    Text("Simulate Alarm")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.9))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }
        }
        .padding(12)
        .background(Color(.systemBackground))
        .cornerRadius(14)
        .shadow(color: Color.black.opacity(0.03), radius: 2, y: 1)
        .padding(.horizontal)
    }

    // MARK: - Mesh Feed Header

    private var meshFeedHeader: some View {
        HStack {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundColor(.blue)
            Text("Multi-Hop Mesh Feed")
                .font(.subheadline.bold())
            Spacer()
        }
        .padding(.horizontal)
    }

    // MARK: - Mesh Messages Feed Section

    private var messageFeedSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if meshManager.routedMessages.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "wifi.slash")
                                .font(.system(size: 26))
                                .foregroundColor(.secondary)
                            Text("Encrypted Mesh Active. Hop-routed alerts will appear here.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 16)
                    } else {
                        ForEach(meshManager.routedMessages) { msg in
                            routedMessageRow(for: msg)
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("BottomAnchor")
                }
                .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: meshManager.routedMessages.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("BottomAnchor", anchor: .bottom)
                }

                if let latest = meshManager.routedMessages.last {
                    if latest.content.contains("SOS") || latest.content.contains("HAZARD") ||
                       latest.content.contains("WATER") || latest.content.contains("MEDICAL") ||
                       latest.content.contains("FOOD") {
                        isEmergencyTriggered = true
                        activeEmergencyMessage = latest.content
                        if latest.senderID != "Me" {
                            activeEmergencySender = latest.senderID
                        } else {
                            activeEmergencySender = "Me"
                        }
                    }

                    if latest.content.contains("RESOLVED") {
                        withAnimation {
                            activeEmergencyMessage = nil
                            activeEmergencySender = nil
                            isEmergencyTriggered = false
                        }
                    }
                }
            }
        }
    }

    // MARK: - Routed Message Row

    @ViewBuilder
    private func routedMessageRow(for msg: RoutedMessage) -> some View {
        let isCritical = msg.content.contains("🚨") || msg.content.contains("SOS") ||
                         msg.content.contains("HAZARD") || msg.content.contains("WATER") ||
                         msg.content.contains("MEDICAL") || msg.content.contains("FOOD")
        let isSafe = msg.content.contains("SAFE") || msg.content.contains("RESOLVED")
        let isMe = msg.senderID == "Me" || msg.senderID == meshManager.userCallsign

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(isCritical ? "CRITICAL ALERT" : (isSafe ? "STATUS UPDATE" : "MESH BROADCAST"))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(isCritical ? .red : (isSafe ? .green : .blue))

                Text(isMe ? "You" : (msg.hops == 0 ? "Direct from \(msg.senderID)" : "\(msg.senderID) (\(msg.hops) hop\(msg.hops == 1 ? "" : "s"))"))
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(isMe ? Color.blue.opacity(0.15) : Color(.secondarySystemBackground))
                    .foregroundColor(isMe ? .blue : .secondary)
                    .cornerRadius(4)

                if msg.isEncrypted {
                    HStack(spacing: 2) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8))
                        Text("AES-GCM")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundColor(.purple)
                }

                Spacer()

                Text(msg.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }

            Text(msg.content)
                .font(.subheadline)
                .foregroundColor(.primary)

            if isCritical && !isMe {
                Button(action: {
                    interactionManager.selectActivePeer(msg.senderID)
                    showFinderSheet = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "location.viewfinder")
                        Text("Locate \(msg.senderID) via UWB")
                    }
                    .font(.caption.bold())
                    .foregroundColor(.red)
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(isCritical ? Color.red.opacity(0.1) : (isSafe ? Color.green.opacity(0.1) : Color(.systemBackground)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isCritical ? Color.red.opacity(0.4) : (isSafe ? Color.green.opacity(0.4) : Color.clear), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    // MARK: - Quick Resource Buttons

    private var quickResourceGridSection: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                resourceButton(title: "💧 Need Water", message: "🚨 [SOS WATER] Water rations requested from \(meshManager.userCallsign)!")
                resourceButton(title: "🩹 Need Medical", message: "🚨 [SOS MEDICAL] Medical aid requested from \(meshManager.userCallsign)!")
            }
            HStack(spacing: 6) {
                resourceButton(title: "🍞 Need Food", message: "🚨 [SOS FOOD] Food rations requested from \(meshManager.userCallsign)!")
                resourceButton(title: "🟢 I Am Safe", message: "🟢 [STATUS SAFE] Verified safe status reported by \(meshManager.userCallsign).")
            }
        }
        .padding(.horizontal)
    }

    private func resourceButton(title: String, message: String) -> some View {
        Button(action: {
            if message.contains("SOS") {
                isEmergencyTriggered = true
                activeEmergencyMessage = message
                activeEmergencySender = "Me"
            }
            meshManager.send(message: message, isEncrypted: true)
        }) {
            Text(title)
                .font(.footnote.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(message.contains("SAFE") ? Color.green : Color.red)
                .foregroundColor(.white)
                .cornerRadius(8)
        }
    }

    // MARK: - Broadcast Bar

    private var broadcastBarSection: some View {
        HStack(spacing: 8) {
            TextField("Type encrypted mesh broadcast...", text: $messageText)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            Button(action: {
                guard !messageText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                meshManager.send(message: messageText, isEncrypted: true)
                messageText = ""
            }) {
                Image(systemName: "paperplane.fill")
                    .padding(8)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    // MARK: - Emergency Consensus Trigger

    private func triggerEmergencyConsensus(reason: String) {
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        let alertMessage = "🚨 [SOS HAZARD] Acoustic Sound Analysis detected \(reason) at \(timestamp) from \(meshManager.userCallsign)."
        activeEmergencyMessage = alertMessage
        activeEmergencySender = "Me"
        isEmergencyTriggered = true
        meshManager.send(message: alertMessage, isEncrypted: true)
    }
}

// MARK: - Layer 3: Directional Finder Sheet (NearbyInteraction / UWB)

struct DirectionalFinderSheet: View {
    @ObservedObject var interactionManager: InteractionManager
    @ObservedObject var meshManager: MeshManager
    @Environment(\.dismiss) private var dismiss

    #if targetEnvironment(simulator)
    @State private var isSimulating = false
    @State private var simulationTimer: Timer?
    @State private var simDistance: Float = 1.9
    @State private var simAngle: Float = 0.0
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Header Details
                VStack(spacing: 4) {
                    Text("Layer 3 Precision Rescue")
                        .font(.caption.bold())
                        .foregroundColor(.blue)
                    Text("Ultra Wideband Directional Finder")
                        .font(.title3.bold())
                }
                .padding(.top, 8)

                // Multi-Peer Selector Bar
                if !interactionManager.availableTrackedPeers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Select Peer to Track:")
                            .font(.caption2.bold())
                            .foregroundColor(.secondary)
                            .padding(.horizontal)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(interactionManager.availableTrackedPeers, id: \.self) { peerName in
                                    let isSelected = (interactionManager.activePeerName == peerName)
                                    Button(action: {
                                        interactionManager.selectActivePeer(peerName)
                                    }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "location.north.circle.fill")
                                            Text(peerName)
                                                .font(.caption.bold())
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(isSelected ? Color.blue : Color(.secondarySystemBackground))
                                        .foregroundColor(isSelected ? .white : .primary)
                                        .cornerRadius(8)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }

                Spacer()

                // UWB Hardware Support or Fallback Indicator
                if !interactionManager.isUWBSupported {
                    uwbFallbackCard
                } else {
                    uwbTrackingVisualizer
                }

                Spacer()

                // Centimeter Distance Readout
                VStack(spacing: 4) {
                    if let peer = interactionManager.activePeerName {
                        Text("Target: \(peer)")
                            .font(.caption.bold())
                            .foregroundColor(.blue)
                    }

                    if let distance = interactionManager.distance {
                        Text(String(format: "%.1f m away", distance))
                            .font(.system(size: 38, weight: .heavy, design: .rounded))
                            .foregroundColor(.primary)

                        Text(String(format: "(%d cm)", Int(distance * 100)))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else if !interactionManager.isUWBSupported {
                        Text("Mesh Signal Connected")
                            .font(.title3.bold())
                            .foregroundColor(.orange)
                        Text("Centimeter UWB unavailable on this model")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Acquiring Real-Time UWB Signal...")
                            .font(.title3.bold())
                            .foregroundColor(.secondary)
                        Text("Point your iPhone toward the peer to establish lock")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Simulator Mode helper (strictly compiled out on physical iPhones)
                #if targetEnvironment(simulator)
                VStack(spacing: 4) {
                    Button(action: toggleSimulation) {
                        Label(isSimulating ? "Stop Simulator Mode" : "Test Radar (Simulator Only)",
                              systemImage: isSimulating ? "stop.circle.fill" : "play.circle.fill")
                            .font(.caption.bold())
                            .foregroundColor(.purple)
                    }
                    Text("Physical iPhones use real UWB hardware automatically")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 8)
                #endif
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        #if targetEnvironment(simulator)
                        stopSimulation()
                        #endif
                        dismiss()
                    }
                }
            }
            .onDisappear {
                #if targetEnvironment(simulator)
                stopSimulation()
                #endif
            }
        }
    }

    // MARK: - Visualizer with Glowing Pointing Arrow

    private var uwbTrackingVisualizer: some View {
        ZStack {
            Circle()
                .stroke(Color.blue.opacity(0.15), lineWidth: 2)
                .frame(width: 220, height: 220)

            Circle()
                .stroke(Color.blue.opacity(0.25), lineWidth: 2)
                .frame(width: 150, height: 150)

            Circle()
                .stroke(Color.blue.opacity(0.35), lineWidth: 2)
                .frame(width: 80, height: 80)

            if let direction = interactionManager.direction {
                let angle = Angle(radians: Double(atan2(direction.x, direction.y)))

                Image(systemName: "location.north.fill")
                    .font(.system(size: 72, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.cyan, .blue],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .rotationEffect(angle)
                    .shadow(color: .cyan.opacity(0.8), radius: 18, x: 0, y: 0)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: angle)
            } else {
                Image(systemName: "rays")
                    .font(.system(size: 60))
                    .foregroundColor(.blue.opacity(0.5))
            }
        }
    }

    // MARK: - Fallback Card for Non-UWB Devices

    private var uwbFallbackCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundColor(.orange)

            Text("UWB Hardware Unavailable")
                .font(.headline.bold())
                .foregroundColor(.orange)

            Text("This device lacks Apple Ultra Wideband hardware. Directional rescue falls back to local mesh status.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            HStack(spacing: 8) {
                Circle()
                    .fill(meshManager.connectedPeers.isEmpty ? Color.red : Color.green)
                    .frame(width: 8, height: 8)
                Text(meshManager.connectedPeers.isEmpty ? "Mesh Signal: Offline" : "Mesh Signal: Connected (\(meshManager.connectedPeers.count) peer(s))")
                    .font(.caption.bold())
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(8)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(16)
    }

    // MARK: - Simulation Helper (Simulator only)

    #if targetEnvironment(simulator)
    private func toggleSimulation() {
        if isSimulating {
            stopSimulation()
        } else {
            startSimulation()
        }
    }

    private func startSimulation() {
        isSimulating = true
        simDistance = 1.9
        simAngle = 0.0

        simulationTimer?.invalidate()
        simulationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            simDistance = max(0.2, simDistance - 0.05)
            simAngle += 0.08

            let x = sin(simAngle)
            let y = cos(simAngle)
            let dir = simd_float3(x: x, y: y, z: 0.0)

            interactionManager.simulateTarget(distance: simDistance, direction: dir)
        }
    }

    private func stopSimulation() {
        simulationTimer?.invalidate()
        simulationTimer = nil
        isSimulating = false
    }
    #endif
}
