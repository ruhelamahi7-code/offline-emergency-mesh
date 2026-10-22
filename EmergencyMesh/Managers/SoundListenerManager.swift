//
//  SoundListenerManager.swift
//  EmergencyMesh
//
//  Created by MAHI RUHELA on 23/10/26.
//

import Foundation
import AVFoundation
import Combine

class SoundListenerManager: NSObject, ObservableObject {
    private var audioRecorder: AVAudioRecorder?
    private var timer: Timer?
    
    @Published var isListening = false
    @Published var currentDecibels: Float = -160.0
    @Published var localSoundSpikeDetected = false
    
    // Closure triggered when a dangerous sound spike is heard
    var onSpikeDetected: (() -> Void)?

    func startListening() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try audioSession.setActive(true)
            
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatAppleLossless),
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.min.rawValue
            ]
            
            // Zero-disk privacy buffer: temporary RAM-backed buffer path
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ram_buffer.wav")
            
            audioRecorder = try AVAudioRecorder(url: tempURL, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            
            isListening = true
            
            // Poll microphone decibel levels in-memory every 0.1 seconds
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self, let recorder = self.audioRecorder else { return }
                recorder.updateMeters()
                let decibels = recorder.averagePower(forChannel: 0)
                
                DispatchQueue.main.async {
                    self.currentDecibels = decibels
                    
                    // Threshold for a loud sound spike (clap, shout, or alarm ~ -15 dB)
                    if decibels > -15.0 && !self.localSoundSpikeDetected {
                        self.localSoundSpikeDetected = true
                        self.onSpikeDetected?()
                    }
                }
            }
        } catch {
            print("Microphone access error: \(error.localizedDescription)")
        }
    }

    func stopListening() {
        audioRecorder?.stop()
        timer?.invalidate()
        isListening = false
    }
}
