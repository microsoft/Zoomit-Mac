@preconcurrency import AVFoundation
import AppKit
@preconcurrency import Speech

enum SnipDictationPhase: Equatable {
    case idle
    case preparing
    case listening
    case finalizing
    case failed
    case completed
}

enum SnipDictationFinalizationAction: Equatable {
    case none
    case waitForPreparation
    case stopAudio
}

struct SnipDictationStateMachine {
    private(set) var phase: SnipDictationPhase = .idle
    private(set) var finalizationRequested = false
    private var pendingFinalTranscript: String?

    mutating func requestStart() -> Bool {
        guard phase == .idle else { return false }
        phase = .preparing
        return true
    }

    mutating func requestFinalization() -> SnipDictationFinalizationAction {
        switch phase {
        case .preparing:
            finalizationRequested = true
            phase = .finalizing
            return .waitForPreparation
        case .listening:
            finalizationRequested = true
            phase = .finalizing
            return .stopAudio
        default:
            return .none
        }
    }

    /// Called after permissions and capture preparation finish. Returns true
    /// when mouse-up already requested finalization while preparation was in
    /// flight, so audio should be ended immediately rather than entering the
    /// listening state.
    mutating func didPrepare() -> Bool {
        guard phase == .preparing || phase == .finalizing else { return false }
        if finalizationRequested {
            phase = .finalizing
            return true
        }
        phase = .listening
        return false
    }

    mutating func fail() {
        phase = .failed
    }

    mutating func complete() {
        phase = .completed
        pendingFinalTranscript = nil
    }

    mutating func cancel() {
        phase = .idle
        finalizationRequested = false
        pendingFinalTranscript = nil
    }

    mutating func recordFinalTranscript(_ transcript: String) {
        guard phase == .listening else { return }
        pendingFinalTranscript = transcript
    }

    mutating func consumePendingFinalTranscript() -> String? {
        guard finalizationRequested else { return nil }
        defer { pendingFinalTranscript = nil }
        return pendingFinalTranscript
    }
}

struct SnipDictationKeyGate {
    private(set) var dragStarted = false
    private(set) var startRequested = false

    mutating func beginSelection() {
        dragStarted = false
        startRequested = false
    }

    mutating func noteDrag() {
        dragStarted = true
    }

    mutating func endDrag() {
        dragStarted = false
    }

    mutating func shouldStart(
        keyCode: UInt16,
        isRepeat: Bool,
        isEnabled: Bool,
        isClipboardSnip: Bool
    ) -> Bool {
        guard keyCode == 49,
              !isRepeat,
              isEnabled,
              isClipboardSnip,
              dragStarted,
              !startRequested else { return false }
        startRequested = true
        return true
    }
}

enum SnipDictationBadge: Equatable {
    case preparing
    case listening
    case transcribing
    case error(String)

    var text: String {
        switch self {
        case .preparing:
            return "Preparing dictation…"
        case .listening:
            return "Listening — release to snip"
        case .transcribing:
            return "Transcribing… Esc cancels"
        case .error(let message):
            return message
        }
    }

    var backgroundColor: NSColor {
        switch self {
        case .error:
            return NSColor.systemRed.withAlphaComponent(0.92)
        default:
            return NSColor.controlAccentColor.withAlphaComponent(0.92)
        }
    }
}

enum SnipDictationBadgeLayout {
    private static let margin: CGFloat = 8

    static func frame(selection: CGRect, container: CGRect, badgeSize: CGSize) -> CGRect {
        let preferredX = selection.midX - badgeSize.width / 2
        let minX = container.minX + margin
        let maxX = max(minX, container.maxX - margin - badgeSize.width)
        let x = min(max(preferredX, minX), maxX)

        let belowY = selection.maxY + margin
        let aboveY = selection.minY - margin - badgeSize.height
        let y: CGFloat
        if belowY + badgeSize.height <= container.maxY - margin {
            y = belowY
        } else {
            y = max(container.minY + margin, aboveY)
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: badgeSize)
    }

    static func draw(_ badge: SnipDictationBadge, selection: CGRect, in bounds: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let text = NSAttributedString(string: badge.text, attributes: attributes)
        let textSize = text.size()
        let padding = CGSize(width: 20, height: 12)
        let badgeSize = CGSize(width: textSize.width + padding.width, height: textSize.height + padding.height)
        let frame = frame(selection: selection, container: bounds, badgeSize: badgeSize)

        badge.backgroundColor.setFill()
        NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7).fill()
        text.draw(at: CGPoint(
            x: frame.minX + padding.width / 2,
            y: frame.minY + padding.height / 2
        ))
    }
}

enum SnipDictationFailure: Error, Equatable {
    case message(String)

    var message: String {
        switch self {
        case .message(let message): message
        }
    }
}

private final class SnipDictationAudioOutput: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let stateLock = NSLock()
    private var finished = false

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: streamDescription),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }

        buffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return }
        stateLock.lock()
        defer { stateLock.unlock() }
        if !finished {
            request.append(buffer)
        }
    }

    func finish() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !finished else { return }
        finished = true
        request.endAudio()
    }
}

private struct SnipDictationRecognitionError: Sendable {
    let domain: String
    let code: Int
    let message: String
}

private final class SnipDictationRecognitionRelay: @unchecked Sendable {
    private let generation: Int
    private let callback: @MainActor @Sendable (String?, Bool, SnipDictationRecognitionError?, Int) -> Void

    init(
        generation: Int,
        callback: @escaping @MainActor @Sendable (String?, Bool, SnipDictationRecognitionError?, Int) -> Void
    ) {
        self.generation = generation
        self.callback = callback
    }

    func receive(result: SFSpeechRecognitionResult?, error: Error?) {
        let transcript = result?.bestTranscription.formattedString
        let isFinal = result?.isFinal ?? false
        let recognitionError = (error as NSError?).map {
            SnipDictationRecognitionError(
                domain: $0.domain,
                code: $0.code,
                message: $0.localizedDescription
            )
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.callback(transcript, isFinal, recognitionError, self.generation)
            }
        }
    }
}

@MainActor
final class SnipDictationSession {
    static let finalizationTimeout: TimeInterval = 20

    var onBadgeChange: ((SnipDictationBadge?) -> Void)?

    private let permissionService: PermissionService
    private var stateMachine = SnipDictationStateMachine()
    private var captureSession: AVCaptureSession?
    private var audioOutput: SnipDictationAudioOutput?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRelay: SnipDictationRecognitionRelay?
    private var preparationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finalizationCompletion: ((Result<String, SnipDictationFailure>) -> Void)?
    private var latestTranscript = ""
    private var pendingFailure: SnipDictationFailure?
    private var audioEnded = false
    private var generation = 0
    private let sampleQueue = DispatchQueue(label: "com.zoomitmac.snip-dictation.samples")

    init(permissionService: PermissionService) {
        self.permissionService = permissionService
    }

    func start(deviceID: String) {
        guard stateMachine.requestStart() else { return }
        audioEnded = false
        generation += 1
        let currentGeneration = generation
        onBadgeChange?(.preparing)

        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.ensureMicrophonePermission(), !Task.isCancelled else {
                if !Task.isCancelled {
                    self.fail("Microphone permission is required for snip dictation.")
                }
                return
            }
            guard await self.ensureSpeechPermission(), !Task.isCancelled else {
                if !Task.isCancelled {
                    self.fail("Speech Recognition permission is required for snip dictation.")
                }
                return
            }
            guard currentGeneration == self.generation else { return }
            self.prepareRecognition(deviceID: deviceID, generation: currentGeneration)
        }
    }

    func stopAndFinalize(completion: @escaping (Result<String, SnipDictationFailure>) -> Void) {
        guard finalizationCompletion == nil else { return }
        finalizationCompletion = completion

        if let pendingFailure {
            complete(.failure(pendingFailure))
            return
        }

        switch stateMachine.requestFinalization() {
        case .waitForPreparation:
            onBadgeChange?(.transcribing)
            startFinalizationTimeout()
        case .stopAudio:
            onBadgeChange?(.transcribing)
            stopAudioAndFinishRequest()
            if let transcript = stateMachine.consumePendingFinalTranscript() {
                complete(.success(transcript))
            } else {
                startFinalizationTimeout()
            }
        case .none:
            if stateMachine.phase == .failed {
                complete(.failure(pendingFailure ?? .message("Dictation could not start.")))
            }
        }
    }

    func cancel() {
        generation += 1
        preparationTask?.cancel()
        preparationTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        stopCaptureAndEndAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRelay = nil
        speechRecognizer = nil
        recognitionRequest = nil
        latestTranscript = ""
        pendingFailure = nil
        finalizationCompletion = nil
        stateMachine.cancel()
        onBadgeChange?(nil)
    }

    private func ensureMicrophonePermission() async -> Bool {
        switch permissionService.microphoneStatus() {
        case .granted:
            return true
        case .denied:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                permissionService.requestMicrophoneAccess {
                    continuation.resume(returning: self.permissionService.microphoneStatus() == .granted)
                }
            }
        }
    }

    private func ensureSpeechPermission() async -> Bool {
        switch permissionService.speechRecognitionStatus() {
        case .granted:
            return true
        case .denied:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                permissionService.requestSpeechRecognitionAccess {
                    continuation.resume(returning: self.permissionService.speechRecognitionStatus() == .granted)
                }
            }
        }
    }

    private func prepareRecognition(deviceID: String, generation: Int) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) else {
            fail("Speech Recognition is not supported for the current language.")
            return
        }
        guard recognizer.isAvailable else {
            fail("Speech Recognition is currently unavailable.")
            return
        }
        guard let device = AudioDevices.microphone(forID: deviceID) else {
            fail("No microphone is available for snip dictation.")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let relay = SnipDictationRecognitionRelay(generation: generation) { [weak self] transcript, isFinal, error, generation in
            self?.handleRecognition(
                transcript: transcript,
                isFinal: isFinal,
                error: error,
                generation: generation
            )
        }
        speechRecognizer = recognizer
        recognitionRelay = relay
        recognitionRequest = request
        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            relay.receive(result: result, error: error)
        }

        do {
            let session = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                fail("The selected microphone cannot be used for dictation.")
                return
            }
            session.addInput(input)

            let output = AVCaptureAudioDataOutput()
            let audioOutput = SnipDictationAudioOutput(request: request)
            output.setSampleBufferDelegate(audioOutput, queue: sampleQueue)
            guard session.canAddOutput(output) else {
                fail("Microphone audio could not be connected to Speech Recognition.")
                return
            }
            session.addOutput(output)
            session.startRunning()
            captureSession = session
            self.audioOutput = audioOutput

            if stateMachine.didPrepare() {
                onBadgeChange?(.transcribing)
                stopAudioAndFinishRequest()
            } else {
                onBadgeChange?(.listening)
            }
        } catch {
            fail("Microphone setup failed: \(error.localizedDescription)")
        }
    }

    private func handleRecognition(
        transcript: String?,
        isFinal: Bool,
        error: SnipDictationRecognitionError?,
        generation: Int
    ) {
        guard generation == self.generation else { return }
        if let transcript {
            latestTranscript = transcript
        }

        if isFinal, stateMachine.phase == .finalizing {
            complete(.success(latestTranscript))
            return
        }
        if isFinal, stateMachine.phase == .listening {
            stateMachine.recordFinalTranscript(latestTranscript)
            return
        }

        if let error {
            if stateMachine.phase == .finalizing, isNoSpeechError(error) {
                complete(.success(latestTranscript))
            } else {
                fail("Dictation failed: \(error.message)")
            }
        }
    }

    private func isNoSpeechError(_ error: SnipDictationRecognitionError) -> Bool {
        (error.domain == "kAFAssistantErrorDomain" && [203, 1110].contains(error.code))
            || (error.domain == "SFSpeechRecognizerErrorDomain" && error.code == 203)
    }

    private func stopAudioAndFinishRequest() {
        stopCaptureAndEndAudio()
    }

    private func stopCaptureAndEndAudio() {
        guard !audioEnded else { return }
        audioEnded = true
        captureSession?.stopRunning()
        captureSession = nil
        if let audioOutput {
            audioOutput.finish()
        } else {
            recognitionRequest?.endAudio()
        }
        audioOutput = nil
    }

    private func startFinalizationTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.finalizationTimeout))
            guard !Task.isCancelled, let self else { return }
            self.fail("Dictation timed out while transcribing.")
        }
    }

    private func fail(_ message: String) {
        let failure = SnipDictationFailure.message(message)
        pendingFailure = failure
        stateMachine.fail()
        stopCaptureAndEndAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRelay = nil
        speechRecognizer = nil
        onBadgeChange?(.error(message))
        if finalizationCompletion != nil {
            complete(.failure(failure))
        }
    }

    private func complete(_ result: Result<String, SnipDictationFailure>) {
        generation += 1
        timeoutTask?.cancel()
        timeoutTask = nil
        preparationTask?.cancel()
        preparationTask = nil
        stopCaptureAndEndAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRelay = nil
        speechRecognizer = nil
        recognitionRequest = nil
        stateMachine.complete()
        let completion = finalizationCompletion
        finalizationCompletion = nil
        completion?(result)
    }
}
