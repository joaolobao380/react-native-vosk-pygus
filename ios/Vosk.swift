import Foundation
import AVFoundation
import React

// The representation of the JSON object returned by Vosk
struct VoskResult: Codable {
    // Partial result
    var partial: String?
    // Complete result
    var text: String?
}

// Structure of options for start method
struct VoskStartOptions {
    // Grammar to use
    var grammar: [String]?
    // Timeout in milliseconds
    var timeout: Int?
}
extension VoskStartOptions: Codable {
    init(dictionary: [String: Any]) throws {
        self = try JSONDecoder().decode(VoskStartOptions.self, from: JSONSerialization.data(withJSONObject: dictionary))
    }
    private enum CodingKeys: String, CodingKey {
        case grammar, timeout
    }
}

@objc(Vosk)
class Vosk: RCTEventEmitter {
    // Class properties
    var currentModel: VoskModel?
    var recognizer: OpaquePointer?
    let audioEngine = AVAudioEngine()
    var inputNode: AVAudioInputNode!
    var formatInput: AVAudioFormat!
    var processingQueue: DispatchQueue!
    var lastRecognizedResult: VoskResult?
    var timeoutTimer: Timer?
    var grammar: [String]?
    var hasListener: Bool = false

    override init() {
        super.init()
        processingQueue = DispatchQueue(label: "recognizerQueue")
        inputNode = audioEngine.inputNode
    }

    deinit {
        vosk_recognizer_free(recognizer)
    }

    override func startObserving() {
        hasListener = true
    }

    override func stopObserving() {
        hasListener = false
    }

    @objc override func supportedEvents() -> [String]! {
        return ["onError", "onResult", "onFinalResult", "onPartialResult", "onTimeout"]
    }

    @objc(loadModel:withResolver:withRejecter:)
    func loadModel(name: String, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) -> Void {
        if currentModel != nil {
            currentModel = nil
        }

        do {
            try currentModel = VoskModel(name: name)
            resolve(true)
        } catch {
            reject(nil, nil, nil)
        }
    }

    @objc(start:withResolver:withRejecter:)
    func start(rawOptions: [String: Any]?, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) -> Void {
        let audioSession = AVAudioSession.sharedInstance()

        var options: VoskStartOptions?
        do {
            options = (rawOptions != nil) ? try VoskStartOptions(dictionary: rawOptions!) : nil
        } catch {
            print(error)
        }

        var grammar: [String]?
        if let grammarOptions = options?.grammar, !grammarOptions.isEmpty {
            grammar = grammarOptions
        }

        var timeout: Int?
        if let timeoutOptions = options?.timeout {
            timeout = timeoutOptions
        }

        do {
            try audioSession.setCategory(.record, mode: .measurement, options: [])
            try audioSession.setActive(true)

            formatInput = inputNode.inputFormat(forBus: 0)
            let sampleRate = formatInput.sampleRate.isFinite && formatInput.sampleRate > 0 ? formatInput.sampleRate : 16000
            let channelCount = formatInput.channelCount > 0 ? formatInput.channelCount : 1

            let formatPcm = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: sampleRate,
                                          channels: UInt32(channelCount),
                                          interleaved: true)

            guard let formatPcm = formatPcm else {
                reject("start", "Não foi possível criar o formato PCM.", nil)
                return
            }

            if let grammar = grammar, !grammar.isEmpty {
                let jsonGrammar = try! JSONEncoder().encode(grammar)
                recognizer = vosk_recognizer_new_grm(currentModel!.model, Float(sampleRate), String(data: jsonGrammar, encoding: .utf8))
            } else {
                recognizer = vosk_recognizer_new(currentModel!.model, Float(sampleRate))
            }

            inputNode.installTap(onBus: 0,
                                 bufferSize: UInt32(sampleRate / 10),
                                 format: formatPcm) { buffer, time in
                self.processingQueue.async {
                    let res = self.recognizeData(buffer: buffer)
                    DispatchQueue.main.async {
                        let parsedResult = try! JSONDecoder().decode(VoskResult.self, from: res.result!.data(using: .utf8)!)
                        if res.completed && self.hasListener && res.result != nil {
                            self.sendEvent(withName: "onResult", body: parsedResult.text!)
                        } else if !res.completed && self.hasListener && res.result != nil {
                            if self.lastRecognizedResult == nil || self.lastRecognizedResult!.partial != parsedResult.partial && !parsedResult.partial!.isEmpty {
                                self.sendEvent(withName: "onPartialResult", body: parsedResult.partial)
                            }
                        }
                        self.lastRecognizedResult = parsedResult
                    }
                }
            }

            audioEngine.prepare()

            audioSession.requestRecordPermission { [weak self] success in
                guard success, let self = self else { return }
                try? self.audioEngine.start()
            }

            if let timeout = timeout {
                DispatchQueue.main.async {
                    self.timeoutTimer = Timer.scheduledTimer(withTimeInterval: Double(timeout) / 1000, repeats: false) { _ in
                        self.processingQueue.async {
                            self.stopInternal(withoutEvents: true)
                            self.sendEvent(withName: "onTimeout", body: "")
                        }
                    }
                }
            }

            resolve("Recognizer successfully started")
        } catch {
            if hasListener {
                sendEvent(withName: "onError", body: "Unable to start AVAudioEngine " + error.localizedDescription)
            } else {
                debugPrint("Unable to start AVAudioEngine " + error.localizedDescription)
            }
            vosk_recognizer_free(recognizer)
            reject("start", error.localizedDescription, error)
        }
    }

    @objc(unload) func unload() -> Void {
        stopInternal(withoutEvents: false)
        if currentModel != nil {
            currentModel = nil
        }
    }

    @objc(stop) func stop() -> Void {
        stopInternal(withoutEvents: false)
    }

    func stopInternal(withoutEvents: Bool) {
        inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
            if hasListener && !withoutEvents {
                sendEvent(withName: "onFinalResult", body: lastRecognizedResult?.partial)
            }
            lastRecognizedResult = nil
        }
        if recognizer != nil {
            vosk_recognizer_free(recognizer)
            recognizer = nil
        }
        if timeoutTimer != nil {
            timeoutTimer?.invalidate()
            timeoutTimer = nil
        }

        // Restore AVAudioSession to default mode
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("Error restoring AVAudioSession: \(error)")
        }
    }

    func recognizeData(buffer: AVAudioPCMBuffer) -> (result: String?, completed: Bool) {
        let dataLen = Int(buffer.frameLength * 2)
        let channels = UnsafeBufferPointer(start: buffer.int16ChannelData, count: 1)
        let endOfSpeech = channels[0].withMemoryRebound(to: Int8.self, capacity: dataLen) {
            return vosk_recognizer_accept_waveform(recognizer, $0, Int32(dataLen))
        }
        let res = endOfSpeech == 1 ?
        vosk_recognizer_result(recognizer) :
        vosk_recognizer_partial_result(recognizer)
        return (String(validatingUTF8: res!), endOfSpeech == 1)
    }
}
