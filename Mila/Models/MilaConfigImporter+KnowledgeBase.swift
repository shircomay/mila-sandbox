import Foundation
import OSLog

// Every path this file logs is a folder the user chose (a knowledge base is
// someone's personal notes tree), so paths are `.private`; the log lines that
// are public name no user content. The main importer's `log` is `private`, so
// this extension keeps its own logger under the same category.
private let kbLog = Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaConfig")

/// The `knowledgeBase` section of a `.milaconfig` (spec 05): point the existing
/// Obsidian-vault exporter at a folder, choose what the notes contain, and
/// switch it on, without the path ever being typed into Settings or committed
/// to a repository. See `MilaConfig.KnowledgeBase`.
///
/// Absent fields leave the current setting alone. An importer constructed
/// without `obsidian:` / `markdownExport:` (the pre-fork call shape) simply
/// ignores the parts that need them.
extension MilaConfigImporter {

    // MARK: - Diff (for the confirmation sheet)

    /// The changes the section would make against the current settings; only
    /// real differences, like the rest of the sheet.
    func knowledgeBaseChanges(for config: MilaConfig) -> [PlannedChange] {
        guard let kb = config.knowledgeBase else { return [] }
        var out: [PlannedChange] = []

        if let obsidian {
            var folderURL: URL?
            if let raw = kb.folder {
                if let url = MilaConfig.KnowledgeBase.expandedFolderURL(raw) {
                    folderURL = url
                } else {
                    out.append(.init(label: "Knowledge base folder",
                                     value: "Ignored (not an absolute path)"))
                }
            }
            let currentVault = obsidian.vaultURL
            let currentSub = obsidian.subfolder.trimmingCharacters(in: .whitespacesAndNewlines)
            let newSub = kb.subfolder?.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveSub = newSub ?? currentSub

            let folderChanged = folderURL.map { !Self.sameFolder($0, currentVault) } ?? false
            let subChanged = newSub.map { $0 != currentSub } ?? false

            if folderChanged || subChanged {
                if let base = folderURL ?? currentVault {
                    var value = (base.path as NSString).abbreviatingWithTildeInPath
                    if !effectiveSub.isEmpty { value += " / \(effectiveSub)" }
                    out.append(.init(label: "Knowledge base folder", value: value))
                } else {
                    out.append(.init(label: "Knowledge base subfolder",
                                     value: effectiveSub.isEmpty ? "(folder root)" : effectiveSub))
                }
            }
            if let enabled = kb.enabled, enabled != obsidian.enabled {
                out.append(.init(label: "Save transcripts there automatically",
                                 value: enabled ? "On" : "Off"))
            }
        }
        if let markdownExport, let content = kb.resolvedNoteContent,
           content != markdownExport.noteContent {
            out.append(.init(label: "Knowledge base notes contain", value: content.displayName))
        }
        if let obsidian, let git = kb.gitSync, git != obsidian.gitSyncEnabled {
            out.append(.init(label: "Commit & push the folder with git", value: git ? "On" : "Off"))
        }
        return out
    }

    // MARK: - Apply

    /// Apply the section: folder, subfolder, note content, git sync, and the
    /// enabled switch LAST so the exporter never runs half-configured.
    func applyKnowledgeBase(_ config: MilaConfig) {
        guard let kb = config.knowledgeBase else { return }

        if kb.noteContent != nil, kb.resolvedNoteContent == nil {
            // The value itself is a config string, not ours to publish.
            kbLog.notice("ignored an unrecognised knowledgeBase.noteContent value")
        }

        if let raw = kb.folder {
            guard let url = MilaConfig.KnowledgeBase.expandedFolderURL(raw) else {
                kbLog.error("knowledgeBase.folder is not an absolute path; skipping the knowledge-base section")
                errorMessage = "The knowledge-base folder in this configuration isn't an absolute path, "
                    + "so the knowledge-base settings were not applied."
                return
            }
            guard let obsidian else {
                kbLog.notice("no vault settings available; ignoring knowledgeBase.folder")
                return
            }
            guard Self.ensureDirectory(url) else {
                errorMessage = "Mila couldn't create the knowledge-base folder from this configuration. "
                    + "Check that its parent folder exists, then try again."
                return
            }
            guard obsidian.setVault(url) else {
                kbLog.error("""
                    could not use \(url.path, privacy: .private) as the knowledge-base folder
                    """)
                errorMessage = "Mila couldn't use the knowledge-base folder from this configuration. "
                    + "The other knowledge-base settings were not applied."
                return
            }
        }
        if let sub = kb.subfolder, let obsidian {
            obsidian.subfolder = sub.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let content = kb.resolvedNoteContent, let markdownExport {
            markdownExport.noteContent = content
        }
        if let git = kb.gitSync, let obsidian {
            obsidian.gitSyncEnabled = git
        }
        if let enabled = kb.enabled, let obsidian {
            obsidian.enabled = enabled
        }
        kbLog.log("applied knowledge-base configuration")
    }

    // MARK: - Helpers

    /// Create `url` (and nothing above it) when it does not exist. True when
    /// a directory is there afterwards.
    private static func ensureDirectory(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
            return true
        } catch {
            let ns = error as NSError
            kbLog.error("""
                failed to create the knowledge-base folder \
                [\(ns.domain, privacy: .public) \(ns.code, privacy: .public)]: \
                \(url.path, privacy: .private)
                """)
            return false
        }
    }

    /// Whether two folder URLs name the same place. A bookmark-resolved vault
    /// URL and a freshly expanded path can differ only by a `/private` prefix
    /// (temporary directories), so both sides are symlink-resolved.
    private static func sameFolder(_ a: URL, _ b: URL?) -> Bool {
        guard let b else { return false }
        return a.resolvingSymlinksInPath().standardizedFileURL.path
            == b.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
