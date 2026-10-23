//
//  SoundListenerManager.swift
//  EmergencyMesh
//
//  Created by MAHI RUHELA on 23/10/26.
//

import Foundation
import AVFoundation
import SoundAnalysis
import Combine

class SoundListenerManager: NSObject, ObservableObject {
    @Published var isListening = false
    @Published var currentDecibels: Float = -160.0
    @Published var localSoundSpikeDetected = false
    @Published var detectedEmergencySound: String? = nil

    var onEmergencySoundVerified: ((String) -> Void)?
    var onSpikeDetected: (() -> Void)?

    private var audioEngine: AVAudioEngine?
    private var streamAnalyzer: SNAudioStreamAnalyzer?
    private let analysisQueue = DispatchQueue(label: "com.emergencymesh.soundanalysis", qos: .userInitiated)

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    private let emergencySoundCatalog: [String: String] = [
        "fire_alarm": "Fire Alarm",
        "smoke_detector": "Smoke Detector",
        "screaming": "Screaming",
        "glass_breaking": "Glass Breaking"
    ]

    override init() {
        super.init()
        setupAudioSessionObservers()
    }

    deinit {
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = routeChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        stopListening()
    }

    // MARK: - Notification Observers

    private func setupAudioSessionObservers() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification)
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            print("[SoundListenerManager] Audio session interruption began. Pausing engine safely...")
            audioEngine?.inputNode.removeTap(onBus: 0)
            if audioEngine?.isRunning == true {
                audioEngine?.pause()
            }
        case .ended:
            print("[SoundListenerManager] Audio session interruption ended. Resuming engine...")
            guard isListening else { return }
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    setupAndStartEngine()
                }
            } else {
                setupAndStartEngine()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard isListening else { return }
        print("[SoundListenerManager] Audio route changed. Adapting engine to new route...")
        setupAndStartEngine()
    }

    // MARK: - Engine Lifecycle

    func startListening() {
        guard !isListening else { return }

        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                guard granted else {
                    print("[SoundListenerManager] Microphone access denied by user.")
                    return
                }
                DispatchQueue.main.async {
                    self?.setupAndStartEngine()
                }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                guard granted else {
                    print("[SoundListenerManager] Microphone access denied by user.")
                    return
                }
                DispatchQueue.main.async {
                    self?.setupAndStartEngine()
                }
            }
        }
    }

    private func setupAndStartEngine() {
        // Stop any running instance before configuring
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning {
                engine.stop()
            }
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let busFormat = inputNode.outputFormat(forBus: 0)

            guard busFormat.sampleRate > 0 else {
                print("[SoundListenerManager] Invalid audio format with zero sample rate.")
                return
            }

            // Zero-disk privacy: Analyzer operates purely on RAM buffers
            let analyzer = SNAudioStreamAnalyzer(format: busFormat)
            let classifyRequest = try SNClassifySoundRequest(classifierIdentifier: .version1)
            try analyzer.add(classifyRequest, withObserver: self)

            // Pass nil to automatically adopt the node's native hardware bus format safely
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, when in
                guard let self = self else { return }

                // In-memory decibel level metering (no disk write)
                if let channelData = buffer.floatChannelData?[0] {
                    let frameCount = Int(buffer.frameLength)
                    if frameCount > 0 {
                        var sum: Float = 0.0
                        for i in 0..<frameCount {
                            let sample = channelData[i]
                            sum += sample * sample
                        }
                        let rms = sqrt(sum / Float(frameCount))
                        let db = 20.0 * log10(max(rms, 0.00001))
                        DispatchQueue.main.async {
                            self.currentDecibels = max(db, -160.0)
                        }
                    }
                }

                // Stream audio buffer directly to on-device SoundAnalysis classifier in RAM
                self.analysisQueue.async {
                    self.streamAnalyzer?.analyze(buffer, atAudioFramePosition: when.sampleTime)
                }
            }

            try engine.start()
            self.audioEngine = engine
            self.streamAnalyzer = analyzer

            DispatchQueue.main.async {
                self.isListening = true
            }
        } catch {
            print("[SoundListenerManager] Failed to start sound analysis engine: \(error.localizedDescription)")
            audioEngine?.inputNode.removeTap(onBus: 0)
            stopListening()
        }
    }

    func stopListening() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning {
                engine.stop()
            }
        }
        streamAnalyzer?.removeAllRequests()
        streamAnalyzer = nil
        audioEngine = nil

        DispatchQueue.main.async {
            self.isListening = false
        }
    }

    func simulateDetection(sound: String = "Fire Alarm") {
        DispatchQueue.main.async {
            self.detectedEmergencySound = sound
            self.localSoundSpikeDetected = true
            self.onEmergencySoundVerified?(sound)
            self.onSpikeDetected?()
        }
    }
}

// MARK: - SNResultsObserving

extension SoundListenerManager: SNResultsObserving {
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classificationResult = result as? SNClassificationResult else { return }

        for classification in classificationResult.classifications {
            let identifier = classification.identifier.lowercased()
            let confidence = classification.confidence

            if confidence > 0.70 {
                for (keyword, readableName) in emergencySoundCatalog {
                    if identifier == keyword || identifier.contains(keyword) {
                        DispatchQueue.main.async {
                            self.detectedEmergencySound = readableName
                            self.localSoundSpikeDetected = true
                            self.onEmergencySoundVerified?(readableName)
                            self.onSpikeDetected?()
                        }
                        return
                    }
                }
            }
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        print("[SoundListenerManager] Sound classifier request failed: \(error.localizedDescription)")
    }

    func requestDidComplete(_ request: SNRequest) {
        print("[SoundListenerManager] Sound classifier request completed.")
    }
}
