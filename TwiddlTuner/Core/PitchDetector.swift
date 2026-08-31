import Foundation

/// A lightweight implementation of the YIN fundamental-frequency estimator.
/// The detector is stateless, so it can safely run away from the audio thread.
public struct PitchDetector: Sendable {
    private static let primaryConditioningCutoff = 80.0
    private static let harmonicConditioningCutoff = 500.0
    private static let harmonicFallbackMinimumFrequency = 70.0
    private static let harmonicFallbackMinimumConfidence = 0.67
    private static let shortWindowLength = 3_072
    private static let shortWindowFallbackMaximumFrequency = 100.0
    private static let shortWindowFallbackMinimumConfidence = 0.68
    private static let fallbackMaximumNormalizedDifference = 0.45

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

        let fullWindowEstimate = conditionedEstimate(
            in: input,
            sampleRate: sampleRate
        )
        if let fullWindowEstimate,
           fullWindowEstimate.frequency >= Self.harmonicFallbackMinimumFrequency {
            return fullWindowEstimate
        }

        // A quiet low-E attack can occupy only the newest part of the window
        // while traffic or handling energy dominates its older samples. Keep
        // the normal window for every successful estimate, but retry its short
        // tail when it returns only sub-bass or nothing. This is deliberately
        // restricted to the captured low-guitar band so it cannot globally
        // trade accuracy for responsiveness on the other strings.
        if input.count > Self.shortWindowLength {
            let shortInput = Array(input.suffix(Self.shortWindowLength))
            let shortEstimate = estimatePitch(
                in: shortInput,
                sampleRate: sampleRate,
                conditioningCutoff: Self.primaryConditioningCutoff
            )
            if let shortEstimate,
               shortEstimate.frequency >= Self.harmonicFallbackMinimumFrequency,
               shortEstimate.frequency <= Self.shortWindowFallbackMaximumFrequency,
               shortEstimate.confidence >= Self.shortWindowFallbackMinimumConfidence,
               isSupportedShortWindowCorrection(
                   shortEstimate,
                   fullWindowEstimate: fullWindowEstimate
               ) {
                return shortEstimate
            }
        }

        return fullWindowEstimate
    }

    private func conditionedEstimate(
        in input: [Float],
        sampleRate: Double
    ) -> PitchEstimate? {

        let primaryEstimate = estimatePitch(
            in: input,
            sampleRate: sampleRate,
            conditioningCutoff: Self.primaryConditioningCutoff
        )
        if let primaryEstimate,
           primaryEstimate.frequency >= Self.harmonicFallbackMinimumFrequency {
            return primaryEstimate
        }

        // An unplugged low string can have a clear upper-harmonic stack while
        // its fundamental competes with handling and room energy. Re-run only
        // uncertain sub-bass results with stronger conditioning. Promote that
        // result only when it is a confident 2× or 3× explanation, preserving
        // genuine bass estimates from the primary path.
        let harmonicEstimate = estimatePitch(
            in: input,
            sampleRate: sampleRate,
            conditioningCutoff: Self.harmonicConditioningCutoff
        )
        guard let harmonicEstimate,
              harmonicEstimate.frequency >= Self.harmonicFallbackMinimumFrequency,
              harmonicEstimate.confidence >= Self.harmonicFallbackMinimumConfidence else {
            return primaryEstimate
        }

        guard let primaryEstimate else { return harmonicEstimate }
        let ratio = harmonicEstimate.frequency / primaryEstimate.frequency
        let harmonic = ratio.rounded()
        guard harmonic >= 2, harmonic <= 3 else { return primaryEstimate }
        let correctionErrorInCents = 1_200 * log2(ratio / harmonic)
        return abs(correctionErrorInCents) <= 55 ? harmonicEstimate : primaryEstimate
    }

    private func isSupportedShortWindowCorrection(
        _ shortEstimate: PitchEstimate,
        fullWindowEstimate: PitchEstimate?
    ) -> Bool {
        guard let fullWindowEstimate else { return true }
        let ratio = shortEstimate.frequency / fullWindowEstimate.frequency
        let harmonic = ratio.rounded()
        guard harmonic >= 2, harmonic <= 3 else { return false }
        let correctionErrorInCents = 1_200 * log2(ratio / harmonic)
        return abs(correctionErrorInCents) <= 55
    }

    private func estimatePitch(
        in input: [Float],
        sampleRate: Double,
        conditioningCutoff: Double
    ) -> PitchEstimate? {

        // Phone microphones can contain strong handling, airflow, and room
        // energy below the useful guitar range. It can look more periodic than
        // a quiet unplugged string and pull YIN toward a false sub-bass note.
        // Conditioning suppresses that energy while preserving the timing of
        // true bass fundamentals such as E1 (41 Hz).
        let conditionedInput = highPass(
            input,
            sampleRate: sampleRate,
            cutoff: conditioningCutoff
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
            // No lag crossed YIN's strict threshold. Preserve a weaker global
            // candidate for the tracker's temporal consistency gates instead
            // of discarding every noisy window independently. Real-device
            // captures contain repeatable low-E evidence in this band, while
            // isolated traffic candidates vary in pitch and fail acquisition.
            guard let bestLag,
                  normalized[bestLag] < Self.fallbackMaximumNormalizedDifference else {
                return nil
            }
            selectedLag = bestLag
        }

        guard let initiallySelectedLag = selectedLag else { return nil }
        let lag = correctedHarmonicLag(
            initiallySelectedLag,
            normalizedDifferences: normalized,
            maximumLag: maximumLag
        )
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

    /// YIN normally chooses the first strong minimum so a genuine high note is
    /// not mistaken for one of its lower periodic multiples. A 12-string's
    /// octave member, or a lower string with a dominant second or third
    /// harmonic, can make a shorter-period minimum cross the threshold first.
    /// In that case the true full period is not merely another good multiple:
    /// its normalized difference is materially deeper than the shorter-period
    /// minimum.
    ///
    /// Only promote a longer-period candidate when that extra evidence is
    /// strong. An isolated upper string has similarly deep minima at integer
    /// multiples of its period, so it remains at the selected pitch.
    private func correctedHarmonicLag(
        _ selectedLag: Int,
        normalizedDifferences: [Double],
        maximumLag: Int
    ) -> Int {
        let selectedRawScore = normalizedDifferences[selectedLag]
        guard selectedRawScore >= 0.002 else { return selectedLag }
        let selectedRefinedScore = parabolicMinimumValue(
            at: selectedLag,
            values: normalizedDifferences
        )
        guard selectedRefinedScore >= 0.002 else { return selectedLag }

        // Prefer the nearest supported full-period explanation. This retains
        // the octave correction when both two- and four-period minima are deep,
        // while allowing a third-harmonic-dominant string to reach 3× its
        // initially selected lag.
        for multiple in 2...3 {
            let targetLag = selectedLag * multiple
            guard targetLag <= maximumLag else { break }

            let searchRadius = max(2, Int((Double(targetLag) * 0.025).rounded()))
            let lowerLag = max(selectedLag + 1, targetLag - searchRadius)
            let upperLag = min(maximumLag, targetLag + searchRadius)
            guard lowerLag <= upperLag,
                  let candidateLag = (lowerLag...upperLag).min(by: {
                      normalizedDifferences[$0] < normalizedDifferences[$1]
                  }) else {
                continue
            }

            let candidateRawScore = normalizedDifferences[candidateLag]
            let candidateRefinedScore = parabolicMinimumValue(
                at: candidateLag,
                values: normalizedDifferences
            )
            let rawRatioLimit = multiple == 2 ? 0.45 : 0.35

            // A genuine high note's short period can fall between integer
            // lags, making a longer multiple look artificially deeper. Require
            // every correction to win both the integer and interpolated score
            // comparisons; the less common 3× case uses a stricter raw limit.
            if candidateRawScore <= selectedRawScore * rawRatioLimit,
               candidateRefinedScore <= selectedRefinedScore * 0.45 {
                return candidateLag
            }
        }

        return selectedLag
    }

    private func parabolicMinimumValue(at index: Int, values: [Double]) -> Double {
        guard index > 0, index + 1 < values.count else { return values[index] }

        let left = values[index - 1]
        let center = values[index]
        let right = values[index + 1]
        let curvature = left - (2 * center) + right
        guard curvature > .leastNonzeroMagnitude else { return center }

        let slope = (right - left) * 0.5
        let vertex = center - (slope * slope) / (2 * curvature)
        return max(0, min(center, vertex))
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
