import Foundation

public struct TuningReading: Equatable, Sendable {
    public let frequency: Double
    public let midiNote: Int
    public let noteName: String
    public let octave: Int
    public let cents: Double
    public let confidence: Double

    public init(frequency: Double, referencePitch: Double = 440, confidence: Double = 1) {
        let fractionalNote = 69 + 12 * log2(frequency / referencePitch)
        let nearestNote = Int(fractionalNote.rounded())
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        let nameIndex = ((nearestNote % 12) + 12) % 12
        let targetFrequency = referencePitch * pow(2, Double(nearestNote - 69) / 12)

        self.frequency = frequency
        self.midiNote = nearestNote
        self.noteName = names[nameIndex]
        self.octave = (nearestNote / 12) - 1
        self.cents = 1_200 * log2(frequency / targetFrequency)
        self.confidence = confidence
    }

    public var isInTune: Bool { abs(cents) <= 3 }
}
