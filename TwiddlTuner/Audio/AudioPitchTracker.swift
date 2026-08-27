import AVFoundation
import Combine
import Foundation

@MainActor
final class AudioPitchTracker: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case listening
        case interrupted
        case recovering
        case permissionDenied
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var reading: TuningReading?

    var referencePitch: Double = 440

    private var engine = AVAudioEngine()
    nonisolated private let detector = PitchDetector()
    nonisolated private let analysisQueue = DispatchQueue(
        label: "app.twiddl.tuner.pitch-analysis",
        qos: .userInitiated
    )
    nonisolated private let analysisBuffer = RollingAnalysisBuffer(
        windowLength: 4_096,
        hopLength: 1_024
    )
    private var acquisitionGate = PitchAcquisitionGate()
    private var transitionGate = PitchAcquisitionGate(requiredMatches: 3)
    private var smoother = PitchSmoother()
    private var lastDetection = Date.distantPast
    private var notificationObservers: [NSObjectProtocol] = []
    private var tapInstalled = false
    private var wantsToListen = false
    private var shouldResumeAfterInterruption = false

    private let visibleReadingTimeout = 0.70
    private let pitchMemoryTimeout = 3.0
    private let subBassAcquisitionFrequency = 45.0
    private let subBassAcquisitionConfidence = 0.85

    init() {
        let center = NotificationCenter.default

        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleInterruption(notification)
            }
        })

        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleRouteChange(notification)
            }
        })

        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMediaServicesReset()
            }
        })
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start() {
        wantsToListen = true
        guard state != .listening, state != .requestingPermission else { return }
        state = .requestingPermission

        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    self.startEngine()
                } else {
                    self.state = .permissionDenied
                }
            }
        }
    }

    func stop() {
        wantsToListen = false
        shouldResumeAfterInterruption = false
        tearDownEngine(deactivateSession: true)
        state = .idle
    }

    private func startEngine() {
        guard wantsToListen else {
            state = .idle
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                state = .failed("No microphone input is available.")
                return
            }

            analysisBuffer.reset()
            acquisitionGate.reset()
            transitionGate.reset()
            smoother.reset()
            reading = nil
            if tapInstalled {
                input.removeTap(onBus: 0)
                tapInstalled = false
            }
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
                self?.enqueue(buffer: buffer, sampleRate: format.sampleRate)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            state = .listening
        } catch {
            tearDownEngine(deactivateSession: true)
            state = .failed(error.localizedDescription)
        }
    }

    private func tearDownEngine(deactivateSession: Bool) {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()

        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }

        analysisBuffer.reset()
        acquisitionGate.reset()
        transitionGate.reset()
        smoother.reset()
        reading = nil
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            shouldResumeAfterInterruption = wantsToListen
            tearDownEngine(deactivateSession: false)
            if shouldResumeAfterInterruption {
                state = .interrupted
            }

        case .ended:
            guard shouldResumeAfterInterruption, wantsToListen else { return }
            shouldResumeAfterInterruption = false

            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if options.contains(.shouldResume) {
                state = .recovering
                startEngine()
            } else {
                state = .idle
            }

        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard wantsToListen, state == .listening,
              let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }

        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange:
            state = .recovering
            tearDownEngine(deactivateSession: false)
            startEngine()
        default:
            break
        }
    }

    private func handleMediaServicesReset() {
        tapInstalled = false
        engine = AVAudioEngine()
        analysisBuffer.reset()
        acquisitionGate.reset()
        transitionGate.reset()
        smoother.reset()
        reading = nil

        guard wantsToListen else {
            state = .idle
            return
        }

        state = .recovering
        startEngine()
    }

    nonisolated private func enqueue(buffer: AVAudioPCMBuffer, sampleRate: Double) {
        guard let channel = buffer.floatChannelData?[0] else { return }

        let frameCount = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channel, count: frameCount))
        guard let window = analysisBuffer.offer(samples) else { return }
        analyze(window, sampleRate: sampleRate)
    }

    nonisolated private func analyze(_ firstWindow: AnalysisWindow, sampleRate: Double) {
        analysisQueue.async { [weak self] in
            guard let self else { return }
            var work: AnalysisWindow? = firstWindow

            while let window = work {
                let estimate = self.detector.detectPitch(
                    in: window.samples,
                    sampleRate: sampleRate
                )

                Task { @MainActor [weak self] in
                    self?.consume(estimate: estimate)
                }

                work = self.analysisBuffer.complete(generation: window.generation)
            }
        }
    }

    private func consume(estimate: PitchEstimate?) {
        guard state == .listening else { return }

        guard let estimate, estimate.confidence >= 0.52 else {
            if reading == nil {
                acquisitionGate.reset()
            }
            transitionGate.reset()
            let timeSinceDetection = Date().timeIntervalSince(lastDetection)
            if timeSinceDetection > visibleReadingTimeout {
                acquisitionGate.reset()
                transitionGate.reset()
                reading = nil
            }
            if timeSinceDetection > pitchMemoryTimeout {
                smoother.reset()
            }
            return
        }

        let acceptedEstimate: PitchEstimate
        if reading == nil {
            guard canAcquire(estimate) else {
                acquisitionGate.reset()
                return
            }
            guard let acquired = acquisitionGate.process(estimate) else { return }
            acceptedEstimate = acquired
        } else if let currentFrequency = reading?.frequency,
                  abs(1_200 * log2(estimate.frequency / currentFrequency)) > 350 {
            // An unrelated note must persist briefly before replacing the note
            // the player is already tuning. Rejected transients intentionally
            // do not refresh `lastDetection`.
            guard canAcquire(estimate),
                  let transitioned = transitionGate.process(estimate) else { return }
            acceptedEstimate = transitioned
        } else {
            acquisitionGate.reset()
            transitionGate.reset()
            acceptedEstimate = estimate
        }

        lastDetection = Date()
        let stabilizedFrequency = smoother.process(
            frequency: acceptedEstimate.frequency,
            signalLevel: acceptedEstimate.signalLevel
        )
        reading = TuningReading(
            frequency: stabilizedFrequency,
            referencePitch: referencePitch,
            confidence: acceptedEstimate.confidence
        )
    }

    /// Very low room and handling resonances are easy to mistake for notes when
    /// they first appear. A real sub-bass attack is strongly periodic; after it
    /// is acquired, the normal lower confidence threshold follows its decay.
    private func canAcquire(_ estimate: PitchEstimate) -> Bool {
        Date().timeIntervalSince(lastDetection) <= pitchMemoryTimeout
            || estimate.frequency >= subBassAcquisitionFrequency
            || estimate.confidence >= subBassAcquisitionConfidence
    }
}

private struct AnalysisWindow: Sendable {
    let samples: [Float]
    let generation: UInt64
}

/// Keeps the newest audio available while analysis is in flight. This avoids a
/// growing queue (lag) without throwing away the tail of a decaying string.
private final class RollingAnalysisBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let windowLength: Int
    private let hopLength: Int
    private var storage: [Float]
    private var writeIndex = 0
    private var validSampleCount = 0
    private var samplesSinceAnalysis = 0
    private var analysisInFlight = false
    private var generation: UInt64 = 0

    init(windowLength: Int, hopLength: Int) {
        self.windowLength = windowLength
        self.hopLength = hopLength
        self.storage = [Float](repeating: 0, count: windowLength)
    }

    func offer(_ samples: [Float]) -> AnalysisWindow? {
        lock.lock()
        defer { lock.unlock() }

        for sample in samples {
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % windowLength
        }
        validSampleCount = min(windowLength, validSampleCount + samples.count)
        samplesSinceAnalysis += samples.count

        guard validSampleCount == windowLength,
              samplesSinceAnalysis >= hopLength,
              !analysisInFlight else { return nil }

        analysisInFlight = true
        samplesSinceAnalysis = 0
        return AnalysisWindow(samples: snapshot(), generation: generation)
    }

    func complete(generation completedGeneration: UInt64) -> AnalysisWindow? {
        lock.lock()
        defer { lock.unlock() }

        guard completedGeneration == generation else { return nil }

        if validSampleCount == windowLength, samplesSinceAnalysis >= hopLength {
            samplesSinceAnalysis = 0
            return AnalysisWindow(samples: snapshot(), generation: generation)
        }

        analysisInFlight = false
        return nil
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        storage = [Float](repeating: 0, count: windowLength)
        writeIndex = 0
        validSampleCount = 0
        samplesSinceAnalysis = 0
        analysisInFlight = false
        generation &+= 1
    }

    private func snapshot() -> [Float] {
        Array(storage[writeIndex...]) + Array(storage[..<writeIndex])
    }
}
