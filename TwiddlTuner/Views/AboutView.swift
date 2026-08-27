import SwiftUI
import UIKit

struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "tuningfork")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)

                    Text(AppInformation.name)
                        .font(.title2.weight(.semibold))

                    Text("A focused chromatic tuner for iPhone")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
            }

            Section("Privacy") {
                NavigationLink {
                    PrivacyDetailsView()
                } label: {
                    Label("How your audio and data are handled", systemImage: "hand.raised")
                }

                Label("No accounts, ads, analytics, or tracking", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)

                Link(destination: TwiddlLinks.privacy) {
                    Label("Read the Privacy Policy", systemImage: "safari")
                }
            }

            Section("Support") {
                NavigationLink {
                    TunerHelpView()
                } label: {
                    Label("Troubleshooting", systemImage: "questionmark.circle")
                }

                Link(destination: TwiddlLinks.support) {
                    Label("Contact Twiddl Support", systemImage: "envelope")
                }
            }

            Section("Version") {
                LabeledContent("Version", value: AppInformation.version)
                LabeledContent("Build", value: AppInformation.build)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrivacyDetailsView: View {
    var body: some View {
        List {
            privacySection(
                title: "Microphone",
                icon: "mic",
                text: "The microphone is used only while the tuner is listening. Audio is analyzed in memory on this iPhone. It is not recorded, saved, or transmitted."
            )

            privacySection(
                title: "Settings",
                icon: "slider.horizontal.3",
                text: "Your concert-pitch preference is stored locally so the app can remember it the next time you open it."
            )

            privacySection(
                title: "Data collection",
                icon: "lock.shield",
                text: "The app has no account system, advertising, analytics, tracking, or third-party data collection."
            )

            Section {
                Text("You can change microphone access at any time in the iPhone Settings app.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func privacySection(title: String, icon: String, text: String) -> some View {
        Section {
            Text(text)
                .foregroundStyle(.secondary)
        } header: {
            Label(title, systemImage: icon)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

private struct TunerHelpView: View {
    var body: some View {
        List {
            Section("No note appears") {
                Text("Play one steady note close to the iPhone microphone. Reduce background noise and avoid playing several strings at once.")
            }

            Section("Microphone access") {
                Text("If access was denied, enable Microphone for \(AppInformation.name) in Settings.")
                    .foregroundStyle(.secondary)

                Button {
                    openSystemSettings()
                } label: {
                    Label("Open iPhone Settings", systemImage: "gear")
                }
            }

            Section("Headphones and Bluetooth") {
                Text("The tuner reconnects when the audio input changes. If the reading seems unusual, disconnect the accessory and try the iPhone microphone.")
            }

            Section("Calls and Siri") {
                Text("Listening pauses when another audio source interrupts the app and resumes automatically when iOS allows it.")
            }
        }
        .navigationTitle("Troubleshooting")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private enum AppInformation {
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Tuner"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
}

private enum TwiddlLinks {
    static let privacy = URL(string: "https://twiddl.app/privacy")!
    static let support = URL(string: "https://twiddl.app/support")!
}

#Preview {
    NavigationStack {
        AboutView()
    }
}
