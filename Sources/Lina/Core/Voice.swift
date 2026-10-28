import AVFoundation
import Speech

/// Hold ⌃⌥ and talk: Lina listens with Apple's on-device speech recognition, so your voice stays on your Mac
/// whenever the language supports it.
@MainActor
final class VoiceInput {
    private(set) var isListening = false
    /// Microphone level, 0...1, for the ink waveform.
    var onLevel: ((CGFloat) -> Void)?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""
    private var finished: CheckedContinuation<Void, Never>?

    /// A build without the usage strings in Info.plist (like `swift run`) would be killed by macOS on first use.
    static var isAvailable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
            && Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
    }

    /// Asks for the microphone and speech recognition if needed. Returns false if either is refused.
    func requestAccess() async -> Bool {
        guard Self.isAvailable else { return false }
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() async -> Bool {
        guard !isListening, await requestAccess(),
              let recognizer = SFSpeechRecognizer(), recognizer.isAvailable
        else { return false }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        transcript = ""

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return false }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.rms(buffer)
            DispatchQueue.main.async { self?.onLevel?(level) }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            return false
        }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || (result?.isFinal ?? false)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if done { self.finished?.resume(); self.finished = nil }
                }
            }
        }
        isListening = true
        return true
    }

    /// Stops listening and returns what was said, waiting briefly for the final words.
    func stop() async -> String {
        guard isListening else { return "" }
        isListening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            finished = c
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated {
                    self?.finished?.resume()
                    self?.finished = nil
                }
            }
        }
        task?.cancel()
        task = nil
        request = nil
        onLevel?(0)
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        guard isListening else { return }
        isListening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        onLevel?(0)
    }

    private nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        return CGFloat(sqrt(sum / Float(buffer.frameLength)))
    }
}

/// Reads Lina's question aloud with the Mac's own voices. Optional, and nothing leaves the Mac.
@MainActor
final class Speaker {
    private let synth = AVSpeechSynthesizer()

    func say(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: clean)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        synth.speak(utterance)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }
}
