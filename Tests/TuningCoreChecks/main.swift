import Foundation
import TuningCore

let sampleRate = 48_000.0
let detector = PitchDetector()

func sineWave(frequency: Double, count: Int = 4_096) -> [Float] {
    (0..<count).map { index in
        Float(0.6 * sin(2 * .pi * frequency * Double(index) / sampleRate))
    }
}

func verify(_ frequency: Double, accuracy: Double) {
    guard let estimate = detector.detectPitch(
        in: sineWave(frequency: frequency),
        sampleRate: sampleRate
    ) else {
        fatalError("No estimate for \(frequency) Hz")
    }
    guard abs(estimate.frequency - frequency) <= accuracy else {
        fatalError("Expected \(frequency) Hz; received \(estimate.frequency) Hz")
    }
    print(String(format: "✓ %8.3f Hz → %8.3f Hz  confidence %.3f", frequency, estimate.frequency, estimate.confidence))
}

verify(27.5, accuracy: 0.12)
verify(110, accuracy: 0.2)
verify(261.6256, accuracy: 0.3)
verify(440, accuracy: 0.35)
verify(1_760, accuracy: 3.0)
verify(4_186.009, accuracy: 18.0)

let harmonicFundamental = 196.0
let harmonicSignal = (0..<4_096).map { index in
    let time = Double(index) / sampleRate
    return Float(
        0.34 * sin(2 * .pi * harmonicFundamental * time)
        + 0.22 * sin(2 * .pi * harmonicFundamental * 2 * time)
        + 0.12 * sin(2 * .pi * harmonicFundamental * 3 * time)
    )
}
guard let harmonicEstimate = detector.detectPitch(in: harmonicSignal, sampleRate: sampleRate),
      abs(harmonicEstimate.frequency - harmonicFundamental) < 0.35 else {
    fatalError("Detector did not recover a fundamental from its harmonics")
}

guard detector.detectPitch(
    in: [Float](repeating: 0, count: 4_096),
    sampleRate: sampleRate
) == nil else {
    fatalError("Silence should not produce a pitch")
}

let concertA = TuningReading(frequency: 440)
guard concertA.noteName == "A", concertA.octave == 4, abs(concertA.cents) < 0.001 else {
    fatalError("440 Hz did not map to A4")
}

var smoother = PitchSmoother()
let initialSmoothedPitch = smoother.process(frequency: 440)
let movingSmoothedPitch = smoother.process(frequency: 442)
guard initialSmoothedPitch == 440,
      movingSmoothedPitch > 440,
      movingSmoothedPitch < 442 else {
    fatalError("Pitch smoother did not follow a small movement continuously")
}

print("✓ silence rejected")
print("✓ fundamental recovered from harmonics")
print("✓ note and cents mapping")
print("✓ continuous pitch smoothing")
print("All tuning-core checks passed.")
