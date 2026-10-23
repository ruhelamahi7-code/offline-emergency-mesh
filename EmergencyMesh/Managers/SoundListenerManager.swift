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

    // Closures triggered when emergency sounds or spikes are recognized
    var onEmergencySoundVerified: ((String) -> Void)?
    var onSpikeDetected: (() -> Void)?

    private var audioEngine: AVAudioEngine?
    private var streamAnalyzer: SNAudioStreamAnalyzer?
    private let analysisQueue = DispatchQueue(label: "com.emergencymesh.soundanalysis", qos: .userInitiated)

    // Emergency identifier keywords mapped to human-readable names
    private let emergencySoundCatalog: [String: String] = [
        "fire_alarm": "Fire Alarm",
        "smoke_detector": "Smoke Detector",
        "screaming": "Screaming",
        "glass_breaking": "Glass Breaking"
    ]

    func startListening() {
        guard !isListening else { return }

        // Request microphone permission before starting engine
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                guard granted else {
                    print("Microphone access denied by user.")
                    return
                }
                DispatchQueue.main.async {
                    self?.setupAndStartEngine()
                }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                guard granted else {
                    print("Microphone access denied by user.")
                    return
                }
                DispatchQueue.main.async {
                    self?.setupAndStartEngine()
                }
            }
        }
    }

    private func setupAndStartEngine() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let busFormat = inputNode.outputFormat(forBus: 0)

            guard busFormat.sampleRate > 0 else {
                print("Invalid audio format with zero sample rate.")
                return
            }

            // Zero-disk privacy: Analyzer operates purely on RAM buffers
            let analyzer = SNAudioStreamAnalyzer(format: busFormat)
            let classifyRequest = try SNClassifySoundRequest(classifierIdentifier: .version1)
            try analyzer.add(classifyRequest, withObserver: self)

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: busFormat) { [weak self] buffer, when in
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
            print("Failed to start sound analysis engine: \(error.localizedDescription)")
            stopListening()
        }
    }

    func stopListening() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        streamAnalyzer?.removeAllRequests()
        streamAnalyzer = nil
        audioEngine = nil

        DispatchQueue.main.async {
            self.isListening = false
        }
    }

    /// Simulation helper for manual testing or previewing without live sirens
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

        // Find matches in top predictions with confidence > 0.70
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
        print("Sound classifier request failed: \(error.localizedDescription)")
    }

    func requestDidComplete(_ request: SNRequest) {
        print("Sound classifier request completed.")
    }
}
