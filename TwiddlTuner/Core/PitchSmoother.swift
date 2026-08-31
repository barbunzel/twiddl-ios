import Foundation

/// Prevents a single short sound from flashing a note before tuning begins.
/// Once a note is acquired, `AudioPitchTracker` bypasses this gate so normal
/// pitch movement remains immediate and fluid.
public struct PitchAcquisitionGate: Sendable {
    private let requiredMatches: Int
    private let toleranceCents: Double
    private var candidateLogFrequency: Double?
    private var matchCount = 0

    public init(requiredMatches: Int = 2, toleranceCents: Double = 45) {
        self.requiredMatches = max(1, requiredMatches)
        self.toleranceCents = max(0, toleranceCents)
    }

    public mutating func process(_ estimate: PitchEstimate?) -> PitchEstimate? {
        guard let estimate,
              estimate.frequency.isFinite,
              estimate.frequency > 0 else {
            reset()
            return nil
        }

        let logFrequency = log2(estimate.frequency)
        let matchesCandidate = candidateLogFrequency.map {
            abs(1_200 * (logFrequency - $0)) <= toleranceCents
        } ?? false

        if matchesCandidate {
            matchCount += 1
        } else {
            candidateLogFrequency = logFrequency
            matchCount = 1
        }

        guard matchCount >= requiredMatches else { return nil }
        reset()
        return estimate
    }

    public mutating func reset() {
        candidateLogFrequency = nil
        matchCount = 0
    }
}

/// Smooths normal pitch movement without making a new string feel sluggish.
/// Frequencies are filtered in log space so the response is even in cents.
public struct PitchSmoother: Sendable {
    private static let directFreshAcquisitionMinimumFrequency = 70.0
    private var filteredLogFrequency: Double?
    private var pendingLargeJump: Double?
    private var pendingLargeJumpCount = 0

    public init() {}

    public mutating func process(
        frequency: Double,
        signalLevel _: Double? = nil
    ) -> Double {
        guard frequency.isFinite, frequency > 0 else {
            return filteredLogFrequency.map { pow(2, $0) } ?? frequency
        }

        var rawLogFrequency = log2(frequency)
        guard let filteredLogFrequency else {
            self.filteredLogFrequency = rawLogFrequency
            return frequency
        }

        rawLogFrequency = correctedSubharmonic(
            rawLogFrequency,
            relativeTo: filteredLogFrequency
        )

        let differenceInCents = 1_200 * (rawLogFrequency - filteredLogFrequency)

        // A single octave error is common in pitch detection. Require a second
        // matching reading before accepting a very large jump, which costs only
        // one short analysis hop when the player really did change strings.
        if abs(differenceInCents) > 350 {
            let matchesPendingJump = pendingLargeJump.map {
                abs(1_200 * (rawLogFrequency - $0)) < 55
            } ?? false

            if matchesPendingJump {
                pendingLargeJumpCount += 1
            } else {
                pendingLargeJump = rawLogFrequency
                pendingLargeJumpCount = 1
            }

            guard pendingLargeJumpCount >= 2 else {
                return pow(2, filteredLogFrequency)
            }

            self.filteredLogFrequency = rawLogFrequency
            pendingLargeJump = nil
            pendingLargeJumpCount = 0
            return frequency
        }

        pendingLargeJump = nil
        pendingLargeJumpCount = 0

        // Quiet, stable notes get gentle jitter reduction. When the player turns
        // a tuning peg, the filter automatically follows the movement faster.
        let movement = min(1, abs(differenceInCents) / 35)
        let response = 0.28 + (0.50 * movement)
        let result = filteredLogFrequency + response * (rawLogFrequency - filteredLogFrequency)
        self.filteredLogFrequency = result
        return pow(2, result)
    }

    public mutating func reset() {
        filteredLogFrequency = nil
        pendingLargeJump = nil
        pendingLargeJumpCount = 0
    }

    /// A new guitar-range pitch that already passed the acquisition gate can
    /// replace hidden pitch memory immediately. Very-low estimates retain the
    /// normal outlier protection because captured room energy often appears as
    /// stable, high-confidence sub-bass.
    public mutating func prepareForFreshAcquisition(frequency: Double) {
        if frequency >= Self.directFreshAcquisitionMinimumFrequency {
            reset()
        }
    }

    /// A visible note transition has already survived the tracker's
    /// consistency gate, so a second large-jump delay would be redundant.
    /// Accept ordinary string-to-string movement immediately, while keeping
    /// the established pitch for exact harmonic relationships that can be
    /// caused by octave or subharmonic detector errors.
    public mutating func prepareForConfirmedTransition(frequency: Double) {
        guard frequency >= Self.directFreshAcquisitionMinimumFrequency,
              frequency.isFinite,
              let filteredLogFrequency else { return }

        let candidateLogFrequency = log2(frequency)
        let ratio = pow(2, abs(candidateLogFrequency - filteredLogFrequency))
        let harmonic = ratio.rounded()
        let isHarmonicRelationship: Bool
        if harmonic >= 2, harmonic <= 4 {
            let errorInCents = 1_200 * log2(ratio / harmonic)
            isHarmonicRelationship = abs(errorInCents) <= 55
        } else {
            isHarmonicRelationship = false
        }

        if !isHarmonicRelationship {
            reset()
        }
    }

    /// YIN can prefer a two-, three-, or four-period lag late in a quiet
    /// string's decay. That produces exactly 1/2, 1/3, or 1/4 of the pitch that
    /// was already stable. Keep the established fundamental in that case.
    private func correctedSubharmonic(
        _ rawLogFrequency: Double,
        relativeTo filteredLogFrequency: Double
    ) -> Double {
        guard rawLogFrequency < filteredLogFrequency else {
            return rawLogFrequency
        }

        let ratio = pow(2, filteredLogFrequency - rawLogFrequency)
        let harmonic = ratio.rounded()
        guard harmonic >= 2, harmonic <= 4 else {
            return rawLogFrequency
        }

        let corrected = rawLogFrequency + log2(harmonic)
        let correctionErrorInCents = 1_200 * (corrected - filteredLogFrequency)
        return abs(correctionErrorInCents) <= 55 ? corrected : rawLogFrequency
    }
}
