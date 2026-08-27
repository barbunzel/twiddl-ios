import XCTest
@testable import TuningCore

final class PitchDetectorTests: XCTestCase {
    private let detector = PitchDetector()
    private let sampleRate = 48_000.0

    func testDetectsConcertA() throws {
        let estimate = try XCTUnwrap(detector.detectPitch(
            in: sineWave(frequency: 440),
            sampleRate: sampleRate
        ))
        XCTAssertEqual(estimate.frequency, 440, accuracy: 0.35)
        XCTAssertGreaterThan(estimate.confidence, 0.9)
    }

    func testDetectsLowA() throws {
        let estimate = try XCTUnwrap(detector.detectPitch(
            in: sineWave(frequency: 110),
            sampleRate: sampleRate
        ))
        XCTAssertEqual(estimate.frequency, 110, accuracy: 0.2)
    }

    func testDetectsMiddleC() throws {
        let estimate = try XCTUnwrap(detector.detectPitch(
            in: sineWave(frequency: 261.6256),
            sampleRate: sampleRate
        ))
        XCTAssertEqual(estimate.frequency, 261.6256, accuracy: 0.3)
    }

    func testFindsFundamentalAmongHarmonics() throws {
        let fundamental = 196.0
        let samples = (0..<4_096).map { index in
            let time = Double(index) / sampleRate
            return Float(
                0.34 * sin(2 * .pi * fundamental * time)
                + 0.22 * sin(2 * .pi * fundamental * 2 * time)
                + 0.12 * sin(2 * .pi * fundamental * 3 * time)
            )
        }
        let estimate = try XCTUnwrap(detector.detectPitch(in: samples, sampleRate: sampleRate))
        XCTAssertEqual(estimate.frequency, fundamental, accuracy: 0.35)
    }

    func testDetectsQuietLowGuitarE() throws {
        let estimate = try XCTUnwrap(detector.detectPitch(
            in: sineWave(frequency: 82.4069, amplitude: 0.0002),
            sampleRate: sampleRate
        ))
        XCTAssertEqual(estimate.frequency, 82.4069, accuracy: 0.25)
        XCTAssertGreaterThan(estimate.confidence, 0.9)
    }

    func testDetectsQuietLowBassE() throws {
        let estimate = try XCTUnwrap(detector.detectPitch(
            in: sineWave(frequency: 41.2034, amplitude: 0.0006),
            sampleRate: sampleRate
        ))
        XCTAssertEqual(estimate.frequency, 41.2034, accuracy: 0.15)
        XCTAssertGreaterThan(estimate.confidence, 0.9)
    }

    func testRejectsSilence() {
        XCTAssertNil(detector.detectPitch(
            in: [Float](repeating: 0, count: 4_096),
            sampleRate: sampleRate
        ))
    }

    func testRejectsVeryQuietSignalAndLowLevelNoise() {
        XCTAssertNil(detector.detectPitch(
            in: sineWave(frequency: 82.4069, amplitude: 0.0001),
            sampleRate: sampleRate
        ))

        var state: UInt64 = 7
        let noise = (0..<4_096).map { _ -> Float in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let unit = Double(state >> 11) / Double(UInt64(1) << 53)
            return Float((unit * 2 - 1) * 0.001)
        }
        XCTAssertNil(detector.detectPitch(in: noise, sampleRate: sampleRate))
    }

    func testDetectsRepresentativeNotesAcrossTheSupportedRange() throws {
        for frequency in [27.5, 41.2034, 82.4069, 440.0, 1_046.502, 4_186.009] {
            let estimate = detector.detectPitch(
                in: sineWave(frequency: frequency, amplitude: 0.05),
                sampleRate: sampleRate
            )
            try assertPitchWithinCents(
                frequency,
                estimate: estimate,
                toleranceCents: 5
            )
        }
    }

    func testFollowsQuietPluckedGuitarThroughItsDecay() throws {
        for windowStart in [0.05, 0.6, 1.0] {
            let estimate = detector.detectPitch(
                in: pluckedString(
                    fundamental: 82.4069,
                    windowStartSeconds: windowStart,
                    peakAmplitude: 0.0018,
                    decaySeconds: 1.3,
                    harmonicWeights: [0.48, 0.30, 0.15, 0.07]
                ),
                sampleRate: sampleRate
            )
            try assertPitchWithinCents(82.4069, estimate: estimate, toleranceCents: 5)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(estimate).confidence, 0.52)
        }
    }

    func testFollowsBarelyAudibleHarmonicHeavyGuitarLowE() throws {
        for windowStart in [0.1, 0.7, 1.1] {
            let estimate = detector.detectPitch(
                in: pluckedString(
                    fundamental: 82.4069,
                    windowStartSeconds: windowStart,
                    peakAmplitude: 0.0008,
                    decaySeconds: 1.3,
                    harmonicWeights: [0.20, 0.42, 0.25, 0.13],
                    noiseAmplitude: 0.000015
                ),
                sampleRate: sampleRate
            )
            try assertPitchWithinCents(82.4069, estimate: estimate, toleranceCents: 5)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(estimate).confidence, 0.52)
        }
    }

    func testFollowsQuietPluckedBassWithWeakFundamental() throws {
        for windowStart in [0.05, 0.7, 1.2] {
            let estimate = detector.detectPitch(
                in: pluckedString(
                    fundamental: 41.2034,
                    windowStartSeconds: windowStart,
                    peakAmplitude: 0.002,
                    decaySeconds: 1.6,
                    harmonicWeights: [0.28, 0.42, 0.22, 0.08]
                ),
                sampleRate: sampleRate
            )
            try assertPitchWithinCents(41.2034, estimate: estimate, toleranceCents: 5)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(estimate).confidence, 0.52)
        }
    }

    func testDetectsQuietBassAfterPCM16QuantizationAt44100Hz() throws {
        let alternateSampleRate = 44_100.0
        let estimate = detector.detectPitch(
            in: pluckedString(
                fundamental: 41.2034,
                sampleRate: alternateSampleRate,
                windowStartSeconds: 0.8,
                peakAmplitude: 0.002,
                decaySeconds: 1.6,
                harmonicWeights: [0.28, 0.42, 0.22, 0.08],
                quantizeToPCM16: true
            ),
            sampleRate: alternateSampleRate
        )
        try assertPitchWithinCents(41.2034, estimate: estimate, toleranceCents: 5)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(estimate).confidence, 0.52)
    }

    func testRejectsSubThresholdElectricalHumAndRoomNoise() {
        var state: UInt64 = 19
        let input = (0..<4_096).map { index -> Float in
            let time = Double(index) / sampleRate
            let hum = 0.00008 * sin(2 * .pi * 50 * time)
            let noise = deterministicNoise(state: &state, amplitude: 0.00005)
            return Float(hum + noise)
        }
        XCTAssertNil(detector.detectPitch(in: input, sampleRate: sampleRate))
    }

    func testMapsFrequencyToNoteAndCents() {
        let a = TuningReading(frequency: 440)
        XCTAssertEqual(a.noteName, "A")
        XCTAssertEqual(a.octave, 4)
        XCTAssertEqual(a.cents, 0, accuracy: 0.001)

        let cSharp = TuningReading(frequency: 277.1826)
        XCTAssertEqual(cSharp.noteName, "C♯")
        XCTAssertEqual(cSharp.octave, 4)
        XCTAssertEqual(cSharp.cents, 0, accuracy: 0.01)
    }

    func testReportsSharpPitchInCents() {
        let reading = TuningReading(frequency: 440 * pow(2, 10.0 / 1_200.0))
        XCTAssertEqual(reading.cents, 10, accuracy: 0.001)
        XCTAssertFalse(reading.isInTune)
    }

    func testPitchSmootherFollowsMovementWithoutStepping() {
        var smoother = PitchSmoother()
        XCTAssertEqual(smoother.process(frequency: 440), 440, accuracy: 0.001)

        let firstMove = smoother.process(frequency: 442)
        let secondMove = smoother.process(frequency: 444)
        XCTAssertGreaterThan(firstMove, 440)
        XCTAssertLessThan(firstMove, 442)
        XCTAssertGreaterThan(secondMove, firstMove)
    }

    func testPitchSmootherRejectsOneLargeOutlier() {
        var smoother = PitchSmoother()
        _ = smoother.process(frequency: 110)
        XCTAssertEqual(smoother.process(frequency: 220), 110, accuracy: 0.001)
        XCTAssertEqual(smoother.process(frequency: 110), 110, accuracy: 0.001)
    }

    func testPitchSmootherAcceptsPersistentNonHarmonicJump() {
        var smoother = PitchSmoother()
        _ = smoother.process(frequency: 440)

        XCTAssertEqual(smoother.process(frequency: 293.66), 440, accuracy: 0.001)
        XCTAssertEqual(smoother.process(frequency: 293.66), 293.66, accuracy: 0.001)
    }

    func testPitchSmootherKeepsFundamentalThroughDecaySubharmonics() {
        var smoother = PitchSmoother()
        XCTAssertEqual(
            smoother.process(frequency: 110, signalLevel: 0.004),
            110,
            accuracy: 0.001
        )

        // These are the exact error families present in the guitar and bass
        // recordings: the detector selects two, three, or four periods.
        for falseFrequency in [55.0, 110.0 / 3.0, 27.5] {
            XCTAssertEqual(
                smoother.process(frequency: falseFrequency, signalLevel: 0.003),
                110,
                accuracy: 0.001
            )
        }
    }

    func testPitchSmootherDoesNotMistakeLevelRiseForOctaveChange() {
        var smoother = PitchSmoother()
        _ = smoother.process(frequency: 110, signalLevel: 0.001)

        XCTAssertEqual(
            smoother.process(frequency: 55, signalLevel: 0.004),
            110,
            accuracy: 0.001
        )
        XCTAssertEqual(
            smoother.process(frequency: 55, signalLevel: 0.0038),
            110,
            accuracy: 0.001
        )
    }

    func testPitchSmootherAcceptsLowNoteAfterReset() {
        var smoother = PitchSmoother()
        _ = smoother.process(frequency: 110, signalLevel: 0.004)
        smoother.reset()

        XCTAssertEqual(
            smoother.process(frequency: 55, signalLevel: 0.001),
            55,
            accuracy: 0.001
        )
    }

    func testAcquisitionGateRequiresTwoConsistentReadings() throws {
        var gate = PitchAcquisitionGate()
        let first = PitchEstimate(frequency: 82.2, confidence: 0.9)
        let second = PitchEstimate(frequency: 82.5, confidence: 0.9)

        XCTAssertNil(gate.process(first))
        let accepted = try XCTUnwrap(gate.process(second))
        XCTAssertEqual(accepted.frequency, second.frequency)
    }

    func testAcquisitionGateRejectsOneOffRoomSounds() throws {
        var gate = PitchAcquisitionGate()

        XCTAssertNil(gate.process(PitchEstimate(frequency: 82.4, confidence: 0.9)))
        XCTAssertNil(gate.process(PitchEstimate(frequency: 110, confidence: 0.9)))
        let accepted = try XCTUnwrap(gate.process(
            PitchEstimate(frequency: 109.8, confidence: 0.9)
        ))
        XCTAssertEqual(accepted.frequency, 109.8)
    }

    func testTransitionGateCanRequireThreeConsistentReadings() throws {
        var gate = PitchAcquisitionGate(requiredMatches: 3)

        XCTAssertNil(gate.process(PitchEstimate(frequency: 82.2, confidence: 0.9)))
        XCTAssertNil(gate.process(PitchEstimate(frequency: 82.4, confidence: 0.9)))
        let accepted = try XCTUnwrap(gate.process(
            PitchEstimate(frequency: 82.3, confidence: 0.9)
        ))
        XCTAssertEqual(accepted.frequency, 82.3)
    }

    private func sineWave(
        frequency: Double,
        count: Int = 4_096,
        amplitude: Double = 0.6
    ) -> [Float] {
        (0..<count).map { index in
            Float(amplitude * sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
    }

    private func pluckedString(
        fundamental: Double,
        sampleRate: Double = 48_000,
        windowStartSeconds: Double,
        peakAmplitude: Double,
        decaySeconds: Double,
        harmonicWeights: [Double],
        noiseAmplitude: Double = 0.00003,
        quantizeToPCM16: Bool = false,
        count: Int = 4_096
    ) -> [Float] {
        var state: UInt64 = 11
        return (0..<count).map { index in
            let time = windowStartSeconds + Double(index) / sampleRate
            let attack = 1 - exp(-time / 0.003)
            let envelope = attack * exp(-time / decaySeconds)
            let harmonics = harmonicWeights.enumerated().reduce(0.0) { partial, entry in
                let (harmonic, weight) = entry
                return partial + weight * sin(
                    2 * .pi * fundamental * Double(harmonic + 1) * time
                )
            }
            let noise = deterministicNoise(state: &state, amplitude: noiseAmplitude)
            let sample = peakAmplitude * envelope * harmonics + noise
            if quantizeToPCM16 {
                let clamped = min(max(sample, -1), 1)
                return Float((clamped * 32_767).rounded() / 32_768)
            }
            return Float(sample)
        }
    }

    private func deterministicNoise(state: inout UInt64, amplitude: Double) -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        let unit = Double(state >> 11) / Double(UInt64(1) << 53)
        return (unit * 2 - 1) * amplitude
    }

    private func assertPitchWithinCents(
        _ expectedFrequency: Double,
        estimate: PitchEstimate?,
        toleranceCents: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let estimate = try XCTUnwrap(estimate, file: file, line: line)
        let centsError = 1_200 * log2(estimate.frequency / expectedFrequency)
        XCTAssertLessThanOrEqual(
            abs(centsError),
            toleranceCents,
            "Expected \(expectedFrequency) Hz within \(toleranceCents) cents, got \(estimate.frequency) Hz (\(centsError) cents)",
            file: file,
            line: line
        )
    }
}
