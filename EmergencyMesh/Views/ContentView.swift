import SwiftUI
import MultipeerConnectivity

struct ContentView: View {
    @StateObject private var meshManager = MeshManager()
    @StateObject private var soundManager = SoundListenerManager()
    @State private var messageText = ""
    @State private var isEmergencyTriggered = false
    @State private var activeEmergencyMessage: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                VStack(spacing: 12) {
                    
                    // Sticky Pinned SOS Card (Disappears across ALL phones when acknowledged)
                    if let activeEmergency = activeEmergencyMessage {
                        pinnedSOSBanner(message: activeEmergency)
                    }

                    headerBannerSection
                    decibelCardSection
                    peersStatusSection
                    messageFeedSection
                    quickResourceGridSection
                    broadcastBarSection
                }
            }
            .navigationTitle("EmergencyMesh")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Sub-Views

    private var headerBannerSection: some View {
        HStack {
            Image(systemName: soundManager.isListening ? "ear.and.waveform" : "ear.badge.exclamationmark")
                .foregroundColor(soundManager.isListening ? .green : .orange)
            
            Text(soundManager.isListening ? "Acoustic Guard Active (RAM Buffer)" : "Acoustic Guard Paused")
                .font(.subheadline.bold())
                .foregroundColor(.primary)
            
            Spacer()
            
            Circle()
                .fill(meshManager.connectedPeers.count > 0 ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            Text(meshManager.connectedPeers.count > 0 ? "\(meshManager.connectedPeers.count) Peer(s)" : "No Peers")
                .font(.caption.bold())
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private func pinnedSOSBanner(message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.white)
                Text("ACTIVE CRITICAL EMERGENCY")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                Spacer()
                Button("Acknowledge") {
                    withAnimation {
                        // Broadcast resolution to ALL connected peers across the mesh
                        let ackMessage = "✅ [RESOLVED] Emergency acknowledged & handled by \(UIDevice.current.name)."
                        meshManager.send(message: ackMessage)
                        activeEmergencyMessage = nil
                        isEmergencyTriggered = false
                    }
                }
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white)
                .foregroundColor(.red)
                .cornerRadius(6)
            }
            
            Text(message)
                .font(.subheadline)
                .foregroundColor(.white)
        }
        .padding(12)
        .background(Color.red)
        .cornerRadius(12)
        .shadow(radius: 4, y: 2)
        .padding(.horizontal)
    }

    private var decibelCardSection: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Ambient Sound Level", systemImage: "waveform")
                    .font(.subheadline.bold())
                Spacer()
                Text(soundManager.isListening ? String(format: "%.1f dB", soundManager.currentDecibels) : "Paused")
                    .font(.subheadline.monospaced())
                    .foregroundColor(soundManager.currentDecibels > -15.0 ? .red : .primary)
            }
            
            HStack(spacing: 12) {
                Button(action: {
                    if soundManager.isListening {
                        soundManager.stopListening()
                    } else {
                        soundManager.startListening()
                        soundManager.onSpikeDetected = {
                            triggerEmergencyConsensus()
                        }
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
                    triggerEmergencyConsensus()
                }) {
                    Text("Simulate Spike")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }
        }
        .padding(12)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(radius: 2, y: 1)
        .padding(.horizontal)
    }

    private var peersStatusSection: some View {
        HStack {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundColor(.blue)
            Text("Mesh Network Feed")
                .font(.subheadline.bold())
            Spacer()
        }
        .padding(.horizontal)
    }

    private var messageFeedSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if meshManager.receivedMessages.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "wifi.slash")
                                .font(.system(size: 28))
                                .foregroundColor(.secondary)
                            Text("Mesh active. Messages & alerts will appear here.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 20)
                    } else {
                        ForEach(Array(meshManager.receivedMessages.enumerated()), id: \.offset) { index, msg in
                            messageRow(for: msg, at: index)
                        }
                    }
                    
                    Color.clear
                        .frame(height: 1)
                        .id("BottomAnchor")
                }
                .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: meshManager.receivedMessages.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("BottomAnchor", anchor: .bottom)
                }
                
                if let latestMessage = meshManager.receivedMessages.last {
                    // If an SOS arrives, display the red banner on this phone
                    if latestMessage.contains("SOS") || latestMessage.contains("HAZARD") || latestMessage.contains("WATER") || latestMessage.contains("MEDICAL") || latestMessage.contains("FOOD") {
                        isEmergencyTriggered = true
                        activeEmergencyMessage = latestMessage
                    }
                    
                    // If an ACK/RESOLVED message arrives from ANY phone, clear the banner for everyone!
                    if latestMessage.contains("RESOLVED") {
                        withAnimation {
                            activeEmergencyMessage = nil
                            isEmergencyTriggered = false
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func messageRow(for msg: String, at index: Int) -> some View {
        let isCritical = msg.contains("🚨") || msg.contains("SOS") || msg.contains("HAZARD") || msg.contains("WATER") || msg.contains("MEDICAL") || msg.contains("FOOD")
        let isSafe = msg.contains("SAFE") || msg.contains("RESOLVED")
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(isCritical ? "CRITICAL ALERT" : (isSafe ? "STATUS UPDATE" : "Mesh Broadcast"))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(isCritical ? .red : (isSafe ? .green : .blue))
                Spacer()
                Text(timestamp)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            
            Text(msg)
                .font(.system(.subheadline, design: .default))
                .foregroundColor(.primary)
        }
        .padding(12)
        .background(isCritical ? Color.red.opacity(0.1) : (isSafe ? Color.green.opacity(0.1) : Color(.systemBackground)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isCritical ? Color.red.opacity(0.4) : (isSafe ? Color.green.opacity(0.4) : Color.clear), lineWidth: 1)
        )
        .cornerRadius(10)
        .shadow(color: Color.black.opacity(0.02), radius: 2, y: 1)
        .id(index)
    }

    private var quickResourceGridSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                resourceButton(title: "💧 Need Water", message: "🚨 [SOS WATER] Water requested from \(UIDevice.current.name)!")
                resourceButton(title: "🩹 Need Medical", message: "🚨 [SOS MEDICAL] Medical aid requested from \(UIDevice.current.name)!")
            }
            HStack(spacing: 8) {
                resourceButton(title: "🍞 Need Food", message: "🚨 [SOS FOOD] Food rations requested from \(UIDevice.current.name)!")
                resourceButton(title: "🟢 I Am Safe", message: "🟢 [STATUS SAFE] Verified safe status reported by \(UIDevice.current.name).")
            }
        }
        .padding(.horizontal)
    }

    private func resourceButton(title: String, message: String) -> some View {
        Button(action: {
            if message.contains("SOS") {
                isEmergencyTriggered = true
                activeEmergencyMessage = message
            }
            meshManager.send(message: message)
        }) {
            Text(title)
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(message.contains("SAFE") ? Color.green : Color.red)
                .foregroundColor(.white)
                .cornerRadius(8)
                .shadow(radius: 1, y: 1)
        }
    }

    private var broadcastBarSection: some View {
        HStack(spacing: 12) {
            TextField("Type emergency broadcast...", text: $messageText)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            Button(action: {
                guard !messageText.isEmpty else { return }
                meshManager.send(message: messageText)
                messageText = ""
            }) {
                Image(systemName: "paperplane.fill")
                    .padding(10)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func triggerEmergencyConsensus() {
        isEmergencyTriggered = true
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        let alertMessage = "🚨 [SOS HAZARD] Verified Acoustic Spike detected at \(timestamp) from \(UIDevice.current.name)."
        activeEmergencyMessage = alertMessage
        meshManager.send(message: alertMessage)
    }
}

#Preview {
    ContentView()
}
