import Foundation

/// Fork-only: marks this binary as the owner's personal build and applies the
/// personal-build defaults. See FORK.md and docs/fork/designs/04-fork-maintenance.md.
///
/// Defaults are WRITTEN into the given domain for keys that have no value yet,
/// not registered: `UserDefaults.register(defaults:)` fills the process-wide
/// registration domain, which every `UserDefaults(suiteName:)` also reads, so
/// it leaked the personal defaults into the test suites' isolated domains.
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

    /// Writes each personal default whose key has no value yet in `defaults`.
    /// Never overwrites a value (the owner's own choices win) and never touches
    /// any other domain. Idempotent; safe to call on every launch, so a default
    /// added in a later fork version reaches existing installs too.
    static func applyPersonalDefaults(on defaults: UserDefaults = .standard) {
        for (key, value) in personalDefaults where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
