import Foundation

/// A lightweight implementation of the YIN fundamental-frequency estimator.
/// The detector is stateless, so it can safely run away from the audio thread.
public struct PitchDetector: Sendable {
    private static let conditioningCutoff = 80.0

    public let minimumFrequency: Double
    public let maximumFrequency: Double
    public let threshold: Double
    public let silenceThreshold: Double

    public init(
        minimumFrequency: Double = 27.5,
        maximumFrequency: Double = 4_200,
        threshold: Double = 0.12,
        // Quiet unplugged electric strings can sit near -76 dBFS at a phone mic.
        // YIN's confidence check still rejects non-periodic room noise after this gate.
        silenceThreshold: Double = 0.00008
    ) {
        self.minimumFrequency = minimumFrequency
        self.maximumFrequency = maximumFrequency
        self.threshold = threshold
        self.silenceThreshold = silenceThreshold
    }

    public func detectPitch(in input: [Float], sampleRate: Double) -> PitchEstimate? {
        guard input.count >= 512, sampleRate > 0 else { return nil }

        // Phone microphones can contain strong handling, airflow, and room
        // energy below the useful guitar range. It can look more periodic than
        // a quiet unplugged string and pull YIN toward a false sub-bass note.
        // Conditioning suppresses that energy while preserving the timing of
        // true bass fundamentals such as E1 (41 Hz).
        let conditionedInput = highPass(
            input,
            sampleRate: sampleRate,
            cutoff: Self.conditioningCutoff
        )

        // Halving the sample rate reduces YIN's work by roughly four times while
        // preserving the complete range needed by a musical-instrument tuner.
        let samples = downsample(conditionedInput)
        let effectiveSampleRate = sampleRate / 2
        let signalLevel = rootMeanSquare(samples)
        guard signalLevel >= silenceThreshold else { return nil }

        let minimumLag = max(2, Int((effectiveSampleRate / maximumFrequency).rounded(.up)))
        let maximumLag = min(
            Int(effectiveSampleRate / minimumFrequency),
            samples.count / 2
        )
        guard maximumLag > minimumLag else { return nil }

        let comparisonLength = samples.count - maximumLag
        var difference = [Double](repeating: 0, count: maximumLag + 1)

        // The cumulative normalization depends on every preceding lag, even
        // those above the highest pitch we intend to report.
        for lag in 1...maximumLag {
            var sum = 0.0
            for index in 0..<comparisonLength {
                let delta = Double(samples[index] - samples[index + lag])
                sum += delta * delta
            }
            difference[lag] = sum
        }

        var normalized = [Double](repeating: 1, count: maximumLag + 1)
        var runningSum = 0.0
        if maximumLag >= 1 {
            for lag in 1...maximumLag {
                runningSum += difference[lag]
                if runningSum > .leastNonzeroMagnitude {
                    normalized[lag] = difference[lag] * Double(lag) / runningSum
                }
            }
        }

        var selectedLag: Int?
        if minimumLag < maximumLag {
            for lag in minimumLag..<maximumLag where normalized[lag] < threshold {
                var localMinimum = lag
                while localMinimum + 1 <= maximumLag,
                      normalized[localMinimum + 1] < normalized[localMinimum] {
                    localMinimum += 1
                }
                selectedLag = localMinimum
                break
            }
        }

        if selectedLag == nil {
            let bestLag = (minimumLag...maximumLag).min {
                normalized[$0] < normalized[$1]
            }
            guard let bestLag, normalized[bestLag] < 0.32 else { return nil }
            selectedLag = bestLag
        }

        guard let lag = selectedLag else { return nil }
        let refinedLag = parabolicMinimum(at: lag, values: normalized)
        guard refinedLag > 0 else { return nil }

        let coarseFrequency = effectiveSampleRate / refinedLag
        let frequency = refineOnOriginalSamples(
            input,
            sampleRate: sampleRate,
            coarseFrequency: coarseFrequency
        )
        guard frequency >= minimumFrequency * 0.95,
              frequency <= maximumFrequency * 1.05 else { return nil }

        return PitchEstimate(
            frequency: frequency,
            confidence: max(0, min(1, 1 - normalized[lag])),
            signalLevel: signalLevel
        )
    }

    private func downsample(_ input: [Float]) -> [Float] {
        let pairCount = input.count / 2
        guard pairCount > 0 else { return input }

        var output = [Float]()
        output.reserveCapacity(pairCount)

        var index = 0
        for _ in 0..<pairCount {
            output.append((input[index] + input[index + 1]) * 0.5)
            index += 2
        }
        return output
    }

    /// A one-pole high-pass is intentionally applied per analysis window. The
    /// first sample initializes the filter, avoiding an artificial edge that
    /// could itself be mistaken for a pluck.
    private func highPass(
        _ input: [Float],
        sampleRate: Double,
        cutoff: Double
    ) -> [Float] {
        guard let first = input.first, sampleRate > 0, cutoff > 0 else {
            return input
        }

        let timeStep = 1 / sampleRate
        let timeConstant = 1 / (2 * Double.pi * cutoff)
        let coefficient = timeConstant / (timeConstant + timeStep)
        var output = [Float](repeating: 0, count: input.count)
        var previousInput = Double(first)
        var previousOutput = 0.0

        for index in input.indices {
            let currentInput = Double(input[index])
            let currentOutput = coefficient
                * (previousOutput + currentInput - previousInput)
            output[index] = Float(currentOutput)
            previousInput = currentInput
            previousOutput = currentOutput
        }
        return output
    }

    private func rootMeanSquare(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        var mean = 0.0
        for sample in samples {
            mean += Double(sample)
        }
        mean /= Double(samples.count)

        for sample in samples {
            let centered = Double(sample) - mean
            sum += centered * centered
        }
        return sqrt(sum / Double(samples.count))
    }

    private func parabolicMinimum(at index: Int, values: [Double]) -> Double {
        guard index > 0, index + 1 < values.count else { return Double(index) }
        let left = values[index - 1]
        let center = values[index]
        let right = values[index + 1]
        let denominator = left - (2 * center) + right
        guard abs(denominator) > .leastNonzeroMagnitude else { return Double(index) }
        return Double(index) + 0.5 * (left - right) / denominator
    }

    /// Downsampling is intentionally retained for YIN's broad search. Refining
    /// the selected period against the original samples preserves cents
    /// accuracy after microphone conditioning, especially on quiet low notes.
    private func refineOnOriginalSamples(
        _ input: [Float],
        sampleRate: Double,
        coarseFrequency: Double
    ) -> Double {
        let proposedLag = Int((sampleRate / coarseFrequency).rounded())
        let centerLag = min(max(proposedLag, 2), input.count / 2 - 2)
        let searchRadius = min(24, max(2, Int((Double(centerLag) * 0.02).rounded())))
        let lowerLag = max(2, centerLag - searchRadius)
        let upperLag = min(input.count / 2 - 2, centerLag + searchRadius)
        let comparisonLength = input.count - (upperLag + 1)
        guard comparisonLength > 0 else { return coarseFrequency }

        var differences = [Double](
            repeating: 0,
            count: upperLag - lowerLag + 1
        )
        for lag in lowerLag...upperLag {
            var sum = 0.0
            for index in 0..<comparisonLength {
                let delta = Double(input[index] - input[index + lag])
                sum += delta * delta
            }
            differences[lag - lowerLag] = sum
        }

        guard let bestIndex = differences.indices.min(by: {
            differences[$0] < differences[$1]
        }) else { return coarseFrequency }
        let refinedIndex = parabolicMinimum(at: bestIndex, values: differences)
        let refinedLag = Double(lowerLag) + refinedIndex
        return refinedLag > 0 ? sampleRate / refinedLag : coarseFrequency
    }
}

public struct PitchEstimate: Equatable, Sendable {
    public let frequency: Double
    public let confidence: Double
    /// RMS amplitude of the analyzed window. It never leaves the device and is
    /// used only to distinguish a new attack from a decaying-note octave error.
    public let signalLevel: Double

    public init(
        frequency: Double,
        confidence: Double,
        signalLevel: Double = 0
    ) {
        self.frequency = frequency
        self.confidence = confidence
        self.signalLevel = signalLevel
    }
}
