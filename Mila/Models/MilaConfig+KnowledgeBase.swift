import Foundation

extension MilaConfig {
    /// Optional `knowledgeBase` section of a `.milaconfig`: where finished
    /// transcripts land as Markdown notes. It drives the existing Obsidian
    /// vault exporter (`ObsidianVaultSettings`) and the note-content choice
    /// from `MarkdownExportSettings`, so a private local helper can point Mila
    /// at a knowledge-base folder without that path ever living in a
    /// repository.
    ///
    /// Every field is optional; absent means "leave the current setting
    /// alone", like the rest of `MilaConfig`. Official Mila builds ignore the
    /// unknown key (synthesized `Decodable` skips unknown keys), so the file
    /// version stays 1.
    struct KnowledgeBase: Codable, Equatable {
        /// Save every finished transcript into the folder automatically.
        var enabled: Bool?
        /// Absolute folder path, `~` allowed (expanded on apply). Created if it
        /// does not exist (the parent must).
        var folder: String?
        /// Subfolder inside `folder`; empty string means the folder root.
        var subfolder: String?
        /// A `MarkdownExportSettings.NoteContent` raw value. Kept as a string
        /// so an unknown value from a newer helper is ignored instead of
        /// failing the whole file; see `resolvedNoteContent`.
        var noteContent: String?
        /// Commit and push the folder after each note (`ObsidianVaultSettings`).
        var gitSync: Bool?

        /// `noteContent` as the enum, or nil when absent or unrecognised.
        var resolvedNoteContent: MarkdownExportSettings.NoteContent? {
            noteContent.flatMap(MarkdownExportSettings.NoteContent.init(rawValue:))
        }

        /// Expand `~` and standardize `raw` into a folder URL. Returns nil
        /// when it is empty or still not absolute after expansion (a relative
        /// path would resolve against whatever the working directory happens to
        /// be, which is never what a config file means).
        static func expandedFolderURL(_ raw: String) -> URL? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let expanded = (trimmed as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
    }
}
