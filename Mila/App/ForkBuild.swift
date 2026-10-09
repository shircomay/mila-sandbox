import Foundation

/// Fork-only: marks this binary as the owner's personal build and registers the
/// personal-build defaults. See FORK.md and docs/fork/designs/04-fork-maintenance.md.
///
/// Defaults are registered (not written): `register(defaults:)` only supplies a
/// fallback for keys the user never set, lives in memory only, and never affects
/// a `UserDefaults(suiteName:)` other than the one passed in.
enum ForkBuild {
    /// Info.plist key written by project.yml (`MilaForkPersonalBuild: true`).
    static let infoPlistKey = "MilaForkPersonalBuild"

    /// True when Info.plist carries MilaForkPersonalBuild = YES.
    static var isPersonalBuild: Bool {
        let value = Bundle.main.object(forInfoDictionaryKey: infoPlistKey)
        if let flag = value as? Bool { return flag }
        if let text = value as? String {
            return ["yes", "true", "1"].contains(text.lowercased())
        }
        return false
    }

    /// Personal-build defaults (docs/fork/designs/00-overview.md, ground rule 6).
    /// String-literal keys on purpose: the settings classes live in other specs.
    static let personalDefaults: [String: Any] = [
        "markdownExport.sidecarEnabled": true,
        "markdownExport.paragraphTimestamps": true,
        "markdownExport.noteContent": "summaryAndTranscript",
        "echoCancellation.enabled": true,
        "echoCancellation.saveDebugAudio": false,
    ]

    /// Only fills keys the user never set; never touches suites other than the
    /// one passed. Call before any settings object reads its defaults.
    static func registerDefaults(on defaults: UserDefaults = .standard) {
        defaults.register(defaults: personalDefaults)
    }
}
