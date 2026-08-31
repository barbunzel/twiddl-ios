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

    /// Mirrors the captured unplugged low-E failure: the guitar's harmonic
    /// stack says E2 while unrelated low room energy makes the primary YIN
    /// conditioning choose E1. The harmonic-focused pass recovers E2.
    func testRecoversLowGuitarEFromSubharmonicRoomEnergy() throws {
        let fundamental = 82.406_889_23
        let harmonicWeights = [0.03, 0.65, 0.45, 0.28, 0.16]
        let samples = (0..<4_096).map { index -> Float in
            let time = Double(index) / sampleRate
            let string = harmonicWeights.enumerated().reduce(0.0) { partial, entry in
                let harmonic = Double(entry.offset + 1)
                return partial + entry.element * sin(
                    2 * .pi * fundamental * harmonic * time
                        + 1.13 * harmonic
                )
            }
            let roomEnergy = 0.3 * sin(2 * .pi * 32 * time + 0.37)
            return Float(0.001 * (string + roomEnergy))
        }

        let estimate = detector.detectPitch(in: samples, sampleRate: sampleRate)
        try assertPitchWithinCents(
            fundamental,
            estimate: estimate,
            toleranceCents: 5
        )
    }

    /// Models a quiet low-E attack arriving after traffic-like low-frequency
    /// energy. The full window is pulled to A0, while its newer tail contains
    /// enough consistent string harmonics to recover E2.
    func testShortWindowRecoversLowGuitarEAfterTrafficNoise() throws {
        let fundamental = 82.406_889_23
        let harmonicWeights = [0.04, 0.72, 0.38, 0.24, 0.14]
        var state: UInt64 = 19
        let samples = (0..<4_096).map { index -> Float in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let unit = Double(state >> 11) / Double(UInt64(1) << 53)
            let time = Double(index) / sampleRate
            let trafficAmplitude = 0.0002
            let traffic = trafficAmplitude * (
                sin(2 * .pi * 31 * time + 0.31)
                    + 0.35 * sin(2 * .pi * 62 * time + 0.73)
            )
            let noise = trafficAmplitude * 0.08 * (unit * 2 - 1)
            guard index >= 512 else { return Float(traffic + noise) }

            let age = Double(index - 512) / sampleRate
            let envelope = exp(-age / 0.45)
            let string = harmonicWeights.enumerated().reduce(0.0) { partial, entry in
                let harmonic = Double(entry.offset + 1)
                return partial + entry.element * sin(
                    2 * .pi * fundamental * harmonic * time
                        + 0.61 * harmonic
                )
            }
            return Float(traffic + noise + 0.00024 * envelope * string)
        }

        try assertPitchWithinCents(
            fundamental,
            estimate: detector.detectPitch(in: samples, sampleRate: sampleRate),
            toleranceCents: 7
        )
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

    func testIdealGuitarSignalsHaveNoMeasurableCentsBias() throws {
        let guitarFrequencies = [
            82.406_889_23,
            110.0,
            146.832_383_96,
            195.997_717_99,
            246.941_650_63,
            329.627_556_91,
        ]

        for frequency in guitarFrequencies {
            for detuning in [-5.0, 0.0, 5.0] {
                let expected = frequency * pow(2, detuning / 1_200)
                let estimate = detector.detectPitch(
                    in: harmonicSignal(
                        fundamental: expected,
                        harmonicWeights: [0.20, 0.70, 0.30, 0.12],
                        phase: 0.61
                    ),
                    sampleRate: sampleRate
                )
                try assertPitchWithinCents(
                    expected,
                    estimate: estimate,
                    toleranceCents: 0.1
                )
            }
        }
    }

    /// Characterizes the reported 2–5 cent disagreement before changing the
    /// estimator. A real string's upper partials are slightly sharp, and a
    /// microphone can emphasize them relative to the fundamental.
    func testInharmonicUpperPartialsCurrentlyPullEstimateSharp() throws {
        for fundamental in [110.0, 195.997_717_99, 220.0] {
            let estimate = try XCTUnwrap(detector.detectPitch(
                in: harmonicSignal(
                    fundamental: fundamental,
                    harmonicWeights: [0.20, 0.70, 0.30, 0.12],
                    phase: 0.61,
                    inharmonicity: 0.0005
                ),
                sampleRate: sampleRate
            ))
            let centsError = 1_200 * log2(estimate.frequency / fundamental)

            XCTAssertGreaterThan(centsError, 1.5)
            XCTAssertLessThan(centsError, 3.0)
        }
    }

    /// A lower string can have a second harmonic strong enough to create the
    /// first YIN threshold crossing. The deeper full-period minimum still
    /// distinguishes it from a genuine note played one octave higher.
    func testDominantSecondHarmonicStillSelectsFundamental() throws {
        let fundamental = 195.997_717_99
        let estimate = detector.detectPitch(
            in: harmonicSignal(
                fundamental: fundamental,
                harmonicWeights: [0.04, 0.90, 0.20, 0.08],
                phase: 0.61
            ),
            sampleRate: sampleRate
        )
        try assertPitchWithinCents(
            fundamental,
            estimate: estimate,
            toleranceCents: 5
        )
    }

    /// Real unplugged electric-guitar captures contained long A2→E4 and
    /// G3→D5 errors: the selected pitches were exactly the strings' third
    /// harmonics. The full three-period minimum remains substantially deeper.
    func testDominantThirdHarmonicStillSelectsFundamental() throws {
        for sampleRate in [44_100.0, 48_000.0] {
            for fundamental in [110.0, 195.997_717_99] {
                for phase in [0.17, 0.61, 1.13] {
                    let estimate = detector.detectPitch(
                        in: twelveStringMember(
                            frequency: fundamental,
                            sampleRate: sampleRate,
                            harmonicWeights: [0.10, 0.18, 0.90, 0.08, 0.04, 0.025],
                            phase: phase
                        ),
                        sampleRate: sampleRate
                    )
                    try assertPitchWithinCents(
                        fundamental,
                        estimate: estimate,
                        toleranceCents: 5
                    )
                }
            }
        }
    }

    func testThirdPeriodCheckKeepsGenuineUpperNotesAtTheirPitch() throws {
        for sampleRate in [44_100.0, 48_000.0] {
            for frequency in [329.627_556_91, 587.329_535_83] {
                for phase in [0.17, 0.61, 1.13] {
                    for inharmonicity in [0.0, 0.0003] {
                        let estimate = detector.detectPitch(
                            in: twelveStringMember(
                                frequency: frequency,
                                sampleRate: sampleRate,
                                harmonicWeights: [0.72, 0.20, 0.06, 0.02],
                                phase: phase,
                                inharmonicity: inharmonicity
                            ),
                            sampleRate: sampleRate
                        )
                        try assertPitchWithinCents(
                            frequency,
                            estimate: estimate,
                            toleranceCents: 5
                        )
                    }
                }
            }
        }

        for sampleRate in [44_100.0, 48_000.0] {
            let estimate = detector.detectPitch(
                in: twelveStringMember(
                    frequency: 1_760,
                    sampleRate: sampleRate,
                    harmonicWeights: [1],
                    phase: 0
                ),
                sampleRate: sampleRate
            )
            try assertPitchWithinCents(
                1_760,
                estimate: estimate,
                toleranceCents: 5
            )
        }
    }

    func testTwelveStringLowerMembersRemainAtTheirFundamental() throws {
        let lowerMembers = [
            82.406_889_23,   // E2
            110.0,           // A2
            146.832_383_96,  // D3
            195.997_717_99,  // G3
        ]

        for sampleRate in [44_100.0, 48_000.0] {
            for fundamental in lowerMembers {
                for phase in [0.17, 0.61, 1.13] {
                    for inharmonicity in [0.0, 0.0003] {
                        let estimate = detector.detectPitch(
                            in: twelveStringMember(
                                frequency: fundamental,
                                sampleRate: sampleRate,
                                harmonicWeights: [0.045, 0.90, 0.20, 0.08],
                                phase: phase,
                                inharmonicity: inharmonicity
                            ),
                            sampleRate: sampleRate
                        )
                        try assertPitchWithinCents(
                            fundamental,
                            estimate: estimate,
                            toleranceCents: 5
                        )
                    }
                }
            }
        }
    }

    func testTwelveStringOctaveMembersRemainAtTheirActualPitch() throws {
        let octaveMembers = [
            164.813_778_46,  // E3
            220.0,           // A3
            293.664_767_92,  // D4
            391.995_435_98,  // G4
        ]

        for sampleRate in [44_100.0, 48_000.0] {
            for frequency in octaveMembers {
                for phase in [0.17, 0.61, 1.13] {
                    for inharmonicity in [0.0, 0.0003] {
                        let estimate = detector.detectPitch(
                            in: twelveStringMember(
                                frequency: frequency,
                                sampleRate: sampleRate,
                                harmonicWeights: [0.72, 0.20, 0.06, 0.02],
                                phase: phase,
                                inharmonicity: inharmonicity
                            ),
                            sampleRate: sampleRate
                        )
                        try assertPitchWithinCents(
                            frequency,
                            estimate: estimate,
                            toleranceCents: 5
                        )
                    }
                }
            }
        }
    }

    func testTwelveStringCoursesPreferLowerMemberWhenOctaveStringIsLouder() throws {
        let lowerMembers = [
            82.406_889_23,   // E2 + E3
            110.0,           // A2 + A3
            146.832_383_96,  // D3 + D4
            195.997_717_99,  // G3 + G4
        ]

        for sampleRate in [44_100.0, 48_000.0] {
            for fundamental in lowerMembers {
                for octaveLevel in [0.7, 1.0, 1.6] {
                    let estimate = detector.detectPitch(
                        in: twelveStringCourse(
                            fundamental: fundamental,
                            sampleRate: sampleRate,
                            lowerLevel: 0.65,
                            octaveLevel: octaveLevel,
                            lowerPhase: 0.31,
                            octavePhase: 1.07
                        ),
                        sampleRate: sampleRate
                    )
                    try assertPitchWithinCents(
                        fundamental,
                        estimate: estimate,
                        toleranceCents: 5
                    )
                }
            }
        }
    }

    func testQuietTwelveStringCoursesPreferLowerMemberThroughMicrophoneNoise() throws {
        for fundamental in [82.406_889_23, 195.997_717_99] {
            let estimate = detector.detectPitch(
                in: twelveStringCourse(
                    fundamental: fundamental,
                    sampleRate: sampleRate,
                    lowerLevel: 0.65,
                    octaveLevel: 1.6,
                    lowerPhase: 0.31,
                    octavePhase: 1.07,
                    peakAmplitude: 0.0012,
                    noiseAmplitude: 0.000015
                ),
                sampleRate: sampleRate
            )
            try assertPitchWithinCents(
                fundamental,
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

    func testFreshGuitarAcquisitionReplacesHiddenPitchImmediately() {
        var smoother = PitchSmoother()
        _ = smoother.process(frequency: 110)
        smoother.prepareForFreshAcquisition(frequency: 82.4)

        XCTAssertEqual(smoother.process(frequency: 82.4), 82.4, accuracy: 0.001)
    }

    func testFreshSubBassAcquisitionKeepsOutlierProtection() {
        var smoother = PitchSmoother()
        _ = smoother.process(frequency: 110)
        smoother.prepareForFreshAcquisition(frequency: 32.3)

        XCTAssertEqual(smoother.process(frequency: 32.3), 110, accuracy: 0.001)
    }

    func testConfirmedStringTransitionDoesNotWaitTwice() {
        var smoother = PitchSmoother()
        _ = smoother.process(frequency: 82.406_889_23)
        smoother.prepareForConfirmedTransition(frequency: 110)

        XCTAssertEqual(smoother.process(frequency: 110), 110, accuracy: 0.001)
    }

    func testConfirmedHarmonicTransitionKeepsOctaveProtection() {
        var smoother = PitchSmoother()
        _ = smoother.process(frequency: 164.813_778_46)
        smoother.prepareForConfirmedTransition(frequency: 82.406_889_23)

        XCTAssertEqual(
            smoother.process(frequency: 82.406_889_23),
            164.813_778_46,
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

    private func harmonicSignal(
        fundamental: Double,
        harmonicWeights: [Double],
        phase: Double,
        inharmonicity: Double = 0,
        count: Int = 4_096
    ) -> [Float] {
        let scale = 0.35 / max(1, harmonicWeights.reduce(0, +))
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            let value = harmonicWeights.enumerated().reduce(0.0) { partial, entry in
                let (offset, weight) = entry
                let harmonic = Double(offset + 1)
                // Normalize the stiff-string model so the first partial remains
                // exactly at `fundamental` while higher partials stretch sharp.
                let stretch = sqrt(
                    (1 + inharmonicity * harmonic * harmonic)
                        / (1 + inharmonicity)
                )
                return partial + weight * sin(
                    2 * .pi * fundamental * harmonic * stretch * time
                        + phase * harmonic
                )
            }
            return Float(scale * value)
        }
    }

    private func twelveStringMember(
        frequency: Double,
        sampleRate: Double,
        harmonicWeights: [Double],
        phase: Double,
        inharmonicity: Double = 0,
        count: Int = 4_096
    ) -> [Float] {
        let scale = 0.28 / max(1, harmonicWeights.reduce(0, +))
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            let value = harmonicWeights.enumerated().reduce(0.0) { partial, entry in
                let (offset, weight) = entry
                let harmonic = Double(offset + 1)
                let stretch = sqrt(
                    (1 + inharmonicity * harmonic * harmonic)
                        / (1 + inharmonicity)
                )
                return partial + weight * sin(
                    2 * .pi * frequency * harmonic * stretch * time
                        + phase * harmonic
                )
            }
            return Float(scale * value)
        }
    }

    private func twelveStringCourse(
        fundamental: Double,
        sampleRate: Double,
        lowerLevel: Double,
        octaveLevel: Double,
        lowerPhase: Double,
        octavePhase: Double,
        peakAmplitude: Double = 0.28,
        noiseAmplitude: Double = 0,
        count: Int = 4_096
    ) -> [Float] {
        let lowerHarmonics = [0.52, 0.30, 0.12, 0.06]
        let octaveHarmonics = [0.72, 0.20, 0.06, 0.02]
        let maximumLevel = lowerLevel * lowerHarmonics.reduce(0, +)
            + octaveLevel * octaveHarmonics.reduce(0, +)
        let scale = peakAmplitude / max(1, maximumLevel)
        var state: UInt64 = 29

        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            let lower = lowerHarmonics.enumerated().reduce(0.0) { partial, entry in
                let (offset, weight) = entry
                let harmonic = Double(offset + 1)
                return partial + weight * sin(
                    2 * .pi * fundamental * harmonic * time
                        + lowerPhase * harmonic
                )
            }
            let octave = octaveHarmonics.enumerated().reduce(0.0) { partial, entry in
                let (offset, weight) = entry
                let harmonic = Double(offset + 1)
                return partial + weight * sin(
                    2 * .pi * fundamental * 2 * harmonic * time
                        + octavePhase * harmonic
                )
            }
            let noise = deterministicNoise(state: &state, amplitude: noiseAmplitude)
            return Float(scale * (lowerLevel * lower + octaveLevel * octave) + noise)
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
