import SwiftUI

/// FORK (echo cancellation, spec 03). The "remove speaker echo" controls,
/// embedded in Settings → Audio beneath the automatic-gain toggle — both are
/// "what happens to the microphone signal" settings.
///
/// Carries its own leading divider so the host needs exactly one line.
struct EchoCancellationSettingsSection: View {
    @EnvironmentObject private var settings: EchoCancellationSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Remove speaker echo from meeting recordings",
                       isOn: $settings.enabled)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("audio.echoCancellation.toggle")
                Text("When you use speakers instead of headphones, your microphone also records the other participants. Mila removes that echo using the meeting audio it already captures. Works in Meeting recordings only. Changes apply to the next recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Save echo-cancellation debug audio",
                       isOn: $settings.saveDebugAudio)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("audio.echoCancellation.debugAudioToggle")
                Text("Saves three extra WAV files per meeting (raw mic, aligned meeting audio, cleaned mic) in an aec-debug folder inside your recordings folder, for tuning. Delete them when done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let summary = settings.lastSessionSummary {
                Text("Last meeting: \(summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("audio.echoCancellation.lastMeeting")
            }
        }
        // The session writes the summary straight to UserDefaults when a
        // meeting stops, so pick up a meeting that ended while Settings was
        // closed.
        .onAppear { settings.refreshLastSessionSummary() }
    }
}
