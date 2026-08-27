import SwiftUI

struct SettingsView: View {
    @Binding var referencePitch: Double
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Concert pitch")
                            Text("Frequency assigned to A4")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Int(referencePitch)) Hz")
                            .font(.body.monospacedDigit().weight(.semibold))
                    }

                    Slider(value: $referencePitch, in: 430...450, step: 1)
                        .accessibilityLabel("Concert pitch")
                        .accessibilityValue("\(Int(referencePitch)) hertz")

                    HStack {
                        Button("−1") { referencePitch = max(430, referencePitch - 1) }
                            .accessibilityLabel("Lower concert pitch by one hertz")
                        Spacer()
                        Button("Standard 440") { referencePitch = 440 }
                            .accessibilityLabel("Set standard concert pitch to 440 hertz")
                        Spacer()
                        Button("+1") { referencePitch = min(450, referencePitch + 1) }
                            .accessibilityLabel("Raise concert pitch by one hertz")
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Calibration")
                } footer: {
                    Text("Most modern instruments use A4 = 440 Hz. Change this only when matching an ensemble or historical tuning.")
                }

                Section("Listening") {
                    Label("Chromatic · A0 through C8", systemImage: "waveform")
                    Label("Audio stays on this device", systemImage: "lock.shield")
                }

                Section("App") {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
