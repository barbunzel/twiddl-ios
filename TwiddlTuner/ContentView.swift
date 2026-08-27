import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var tracker = AudioPitchTracker()
    @AppStorage("referencePitch") private var referencePitch = 440.0
    @State private var showingSettings: Bool
    @Environment(\.scenePhase) private var scenePhase

    private let screenshot = ScreenshotConfiguration.current

    private let background = Color(red: 0.035, green: 0.043, blue: 0.041)
    private let tuned = Color(red: 0.48, green: 0.95, blue: 0.67)
    private let searching = Color(red: 0.93, green: 0.76, blue: 0.40)

    init() {
        _showingSettings = State(initialValue: ScreenshotConfiguration.current.opensSettings)
    }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer(minLength: 18)
                tunerReadout
                Spacer(minLength: 26)
                gauge
                Spacer(minLength: 28)
                statusArea
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSettings) {
            SettingsView(referencePitch: $referencePitch)
        }
        .onAppear {
            guard !screenshot.isEnabled else { return }
            tracker.referencePitch = referencePitch
            tracker.start()
        }
        .onChange(of: referencePitch) { _, newValue in
            tracker.referencePitch = newValue
        }
        .onChange(of: tracker.state) { _, newState in
            UIApplication.shared.isIdleTimerDisabled = newState == .listening
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard !screenshot.isEnabled else { return }
            switch newPhase {
            case .active:
                tracker.start()
            case .background:
                UIApplication.shared.isIdleTimerDisabled = false
                if tracker.state == .listening {
                    tracker.stop()
                }
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var header: some View {
        HStack {
            Text("TWIDDL")
                .font(.caption.weight(.bold))
                .tracking(3.2)
                .foregroundStyle(Color(red: 0.98, green: 0.50, blue: 0.45))

            Spacer()

            Button {
                showingSettings = true
            } label: {
                HStack(spacing: 7) {
                    Text("A")
                        .foregroundStyle(.white.opacity(0.48))
                    Text("\(Int(referencePitch))")
                        .monospacedDigit()
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.48))
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(.white.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings, A4 is \(Int(referencePitch)) hertz")
        }
    }

    private var tunerReadout: some View {
        VStack(spacing: 4) {
            if let reading = displayedReading {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(baseName(reading.noteName))
                        .font(.system(size: 146, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())

                    VStack(alignment: .leading, spacing: 0) {
                        Text(accidental(reading.noteName))
                            .font(.system(size: 43, weight: .semibold, design: .rounded))
                        Text("\(reading.octave)")
                            .font(.title2.monospacedDigit().weight(.medium))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .foregroundStyle(reading.isInTune ? tuned : .white)
                .frame(minHeight: 176)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(reading.noteName) \(reading.octave)")
                .accessibilityValue(readingAccessibilityValue(reading))

                Text(String(format: "%.1f Hz", reading.frequency))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.48))
            } else {
                Text("—")
                    .font(.system(size: 146, weight: .light, design: .rounded))
                    .foregroundStyle(.white.opacity(0.16))
                    .frame(minHeight: 176)

                Text(promptText)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
    }

    private var gauge: some View {
        VStack(spacing: 17) {
            TunerGauge(cents: displayedReading?.cents, activeColor: indicatorColor)

            HStack(alignment: .firstTextBaseline) {
                Text(directionLabel)
                    .font(.caption.weight(.bold))
                    .tracking(1.7)
                    .foregroundStyle(indicatorColor.opacity(tracker.reading == nil ? 0.42 : 1))

                Spacer()

                Text(centsLabel)
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white.opacity(tracker.reading == nil ? 0.25 : 0.9))
            }
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        if screenshot.isEnabled {
            listeningStatus(hasReading: displayedReading != nil)
        } else {
            liveStatusArea
        }
    }

    @ViewBuilder
    private var liveStatusArea: some View {
        switch tracker.state {
        case .idle:
            primaryButton("Start listening", icon: "mic.fill") { tracker.start() }
        case .requestingPermission:
            ProgressView("Asking for microphone access…")
                .tint(.white)
                .foregroundStyle(.white.opacity(0.7))
                .frame(height: 56)
        case .interrupted:
            ProgressView("Listening paused by another audio source…")
                .tint(.white)
                .foregroundStyle(.white.opacity(0.7))
                .frame(height: 56)
        case .recovering:
            ProgressView("Reconnecting to the microphone…")
                .tint(.white)
                .foregroundStyle(.white.opacity(0.7))
                .frame(height: 56)
        case .listening:
            listeningStatus(hasReading: tracker.reading != nil)
        case .permissionDenied:
            VStack(spacing: 10) {
                Text("Microphone access is off")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
                primaryButton("Open Settings", icon: "gear") { openSystemSettings() }
            }
        case .failed(let message):
            VStack(spacing: 10) {
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.red.opacity(0.8))
                primaryButton("Try again", icon: "arrow.clockwise") { tracker.start() }
            }
        }
    }

    private func listeningStatus(hasReading: Bool) -> some View {
        Button { tracker.stop() } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(hasReading ? tuned : searching)
                    .frame(width: 7, height: 7)
                    .shadow(color: indicatorColor.opacity(0.7), radius: 5)
                Text(hasReading ? "Listening" : "Listening for a note")
                Spacer()
                Image(systemName: "pause.fill")
                    .font(.caption)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white.opacity(0.62))
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pause listening")
        .accessibilityValue(hasReading ? "Note detected" : "Waiting for a note")
    }

    private func primaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(background)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(tuned, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private var indicatorColor: Color {
        guard let reading = displayedReading else { return searching }
        return reading.isInTune ? tuned : searching
    }

    private var directionLabel: String {
        guard let cents = displayedReading?.cents else { return "WAITING" }
        if abs(cents) <= 3 { return "IN TUNE" }
        return cents < 0 ? "FLAT" : "SHARP"
    }

    private var centsLabel: String {
        guard let cents = displayedReading?.cents else { return "— cents" }
        return String(format: "%+.1f cents", cents)
    }

    private var displayedReading: TuningReading? {
        screenshot.reading ?? tracker.reading
    }

    private var promptText: String {
        switch tracker.state {
        case .listening: "Play a steady note"
        case .interrupted: "Listening paused"
        case .recovering: "Reconnecting"
        case .permissionDenied: "Microphone needed"
        default: "Ready when you are"
        }
    }

    private func baseName(_ note: String) -> String {
        String(note.prefix(1))
    }

    private func accidental(_ note: String) -> String {
        note.contains("♯") ? "♯" : " "
    }

    private func readingAccessibilityValue(_ reading: TuningReading) -> String {
        let direction: String
        if reading.isInTune {
            direction = "in tune"
        } else if reading.cents < 0 {
            direction = String(format: "%.1f cents flat", abs(reading.cents))
        } else {
            direction = String(format: "%.1f cents sharp", reading.cents)
        }

        return String(format: "%.1f hertz, %@", reading.frequency, direction)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct ScreenshotConfiguration {
    let reading: TuningReading?
    let opensSettings: Bool

    var isEnabled: Bool { reading != nil || opensSettings }

    static var current: ScreenshotConfiguration {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments

        if arguments.contains("-twiddlScreenshotInTune") {
            return ScreenshotConfiguration(reading: TuningReading(frequency: 440), opensSettings: false)
        }

        if arguments.contains("-twiddlScreenshotFlat") {
            let frequency = 196 * pow(2, -13.8 / 1_200)
            return ScreenshotConfiguration(reading: TuningReading(frequency: frequency), opensSettings: false)
        }

        if arguments.contains("-twiddlScreenshotSettings") {
            return ScreenshotConfiguration(reading: nil, opensSettings: true)
        }
#endif

        return ScreenshotConfiguration(reading: nil, opensSettings: false)
    }
}

#Preview {
    ContentView()
}
