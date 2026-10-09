# Spec 05 — Knowledge-base folder via `.milaconfig`, and title refresh

**Agent:** Claude Sonnet · **effort: high** · read `00-overview.md` and
`01-markdown-transcripts.md` first (this builds on spec 01, already merged).

## Goal

1. **Knowledge-base folder.** The owner wants every finished transcript to land
   automatically, as Markdown, in their knowledge-base (KB) folder on their Mac.
   Mila already has the mechanism: the "Obsidian vault" exporter
   (`ObsidianExporter` + `ObsidianVaultSettings`) writes one `<date> <title>.md` per
   recording into a chosen folder/subfolder, idempotently, and spec 01 made its
   content selectable (`MarkdownExportSettings.noteContent`). What is missing is a
   way to set that folder WITHOUT the folder path ever appearing in this public
   repository, and without clicking through Settings: a local helper on the Mac
   writes a private `.milaconfig` file, the owner double-clicks it, Mila shows its
   existing confirmation sheet, and applies it.
2. **Title refresh.** When a completed recording's title changes (the
   post-recording naming sheet, an LLM auto-title, or a rename), the `.md` sidecar
   and the KB note must pick up the new title.

## Part A — `.milaconfig` gains an optional `knowledgeBase` section

File format (JSON, every field optional, absent = leave unchanged):

```json
{
  "version": 1,
  "knowledgeBase": {
    "enabled": true,
    "folder": "~/path/to/knowledge-base",
    "subfolder": "Mila transcripts",
    "noteContent": "transcript",
    "gitSync": false
  }
}
```

`noteContent` ∈ `summaryElseTranscript | transcript | summaryAndTranscript`
(`MarkdownExportSettings.NoteContent` raw values). Unknown value → ignored, logged,
listed nowhere. Official Mila builds ignore the unknown key (synthesized
`Decodable` skips unknown keys) — keep `version` at 1.

Implementation:
- `Mila/Models/MilaConfig.swift` (upstream, hook): one stored property
  `var knowledgeBase: KnowledgeBase? // FORK:`. Declare the nested type in a NEW
  file `Mila/Models/MilaConfig+KnowledgeBase.swift` as
  `extension MilaConfig { struct KnowledgeBase: Codable, Equatable { … } }`.
  `MilaConfig` uses synthesized `Codable` (no `CodingKeys`) — confirm, and confirm
  every existing memberwise/`init` use of `MilaConfig` in app code and tests still
  compiles (a new optional stored property with no default in a struct changes the
  synthesized memberwise init! Give it a default `= nil` so existing
  `MilaConfig(version:…)` calls keep compiling).
- `Mila/Models/MilaConfigImporter.swift` (upstream, hooks):
  - Two new stored properties, internal (not private) so an extension in another
    file can use them: `let obsidian: ObsidianVaultSettings?` and
    `let markdownExport: MarkdownExportSettings?`.
  - `init` gains two DEFAULTED parameters `obsidian: ObsidianVaultSettings? = nil,
    markdownExport: MarkdownExportSettings? = nil` appended at the end, so
    `MilaConfigTests` (which constructs the importer with the five existing
    arguments) compiles unchanged.
  - `plannedChanges(for:)`: one line before `return out`:
    `out += knowledgeBaseChanges(for: config) // FORK:`.
  - `apply(_:)`: one line before the final log: `applyKnowledgeBase(config) // FORK:`.
- New file `Mila/Models/MilaConfigImporter+KnowledgeBase.swift` with
  `knowledgeBaseChanges(for:) -> [PlannedChange]` and `applyKnowledgeBase(_:)`.
  Read `ObsidianVaultSettings` first (`setVault(_:) -> Bool`, `enabled`,
  `subfolder`, `gitSyncEnabled`, `vaultURL`) and match actor isolation.
  - Path handling: `(folder as NSString).expandingTildeInPath`, standardized; must
    be absolute after expansion, else ignored with an error. Create the folder (and
    nothing above it) if it does not exist; then `obsidian.setVault(url)`. If that
    returns false, set `errorMessage` to a plain sentence and skip the rest of the
    section.
  - Apply order: folder → subfolder → noteContent → gitSync → enabled last.
  - Planned changes (only real differences, like the rest of the sheet):
    "Knowledge base folder" → abbreviated path (`abbreviatingWithTildeInPath`) plus
    `/ subfolder` when set; "Save transcripts there automatically" On/Off;
    "Knowledge base notes contain" → the same display names the Settings picker uses;
    "Commit & push the folder with git" On/Off.
  - Logs: paths only with `privacy: .private`.
- `Mila/App/MilaApp.swift` (hook): pass `obsidian: obsidianVaultSettings` (whatever
  the local variable is called where the importer is built, ~line 911) and
  `markdownExport:` the spec-01 settings object. Those objects must exist before
  the importer is constructed — reorder nothing; if they are created later in
  `init`, create the importer's references in the smallest way that compiles
  (read the init carefully) and explain in the report.
- Example file, committed: `docs/fork/knowledge-base.milaconfig.example` with the
  placeholder path above. Never commit a real path.

## Part B — title refresh

- `Mila/Models/RecordingStore.swift` (hooks):
  - Add `var onCompletedRecordingRetitled: ((Recording) -> Void)? // FORK:` next to
    the other callbacks (`onSpeakerUnnamed`).
  - In `update(_ recording:) -> Bool`: capture the old title before the
    assignment; after persisting, if the title changed and
    `recording.status == .completed`, call
    `MarkdownTranscriptExporter.writeSidecar(for: recording, in: recordingsDirectory)`
    and `onCompletedRecordingRetitled?(recording)`. Keep it a single small block.
    Check the other `update(_:…)` overload (~line 556): if it can change titles,
    hook it the same way; if it only replaces speaker maps, leave it.
  - In `rename(_:to:)`: spec 01 already rewrites the sidecar there; add the
    callback call next to it.
- `Mila/App/MilaApp.swift` (hook): set the callback where the store and the
  Obsidian exporter are both available (find where `markPending` is wired, ~line
  656): when `obsidianVaultSettings.enabled` and the exporter is NOT
  `isPending(id)` (a pending note is written by the summary hook anyway, with the
  newest title), call `exporter.export(recording)`. The exporter's sticky index
  renames the existing note instead of creating a duplicate — confirm by reading
  `noteTarget`. Main-actor isolation: match what the surrounding code does.

## Tests (new files only; custom `UserDefaults` suites; temp dirs)

- `MilaTests/MilaConfigKnowledgeBaseTests.swift`: decode with and without the
  section; unknown noteContent ignored; round-trip encode; planned changes list
  only differences; apply sets vault (temp dir, created when missing), subfolder,
  note content, git sync, enabled; tilde expansion (use a path under
  `NSTemporaryDirectory()` for the real assertion, and a pure string test for `~`);
  relative path rejected; importer built WITHOUT the new dependencies ignores the
  section without crashing.
- `MilaTests/RecordingTitleRefreshTests.swift`: `update` with a changed title on a
  completed recording fires the callback once and rewrites the sidecar (when the
  sidecar setting is on — read how spec-01 tests control that, they used
  `.standard` registered defaults); unchanged title or non-completed status → no
  callback; `rename` fires the callback.
- Upstream tests must pass unchanged (especially `MilaConfigTests`,
  `RecordingStoreTests`, `ObsidianExporterTests`).

## Deliverables

Code + tests above, the example file, a "Knowledge-base folder" section in
`FORK.md` (how it works, that the real `.milaconfig` lives only on the Mac, keep
"Commit & push" OFF unless the KB repo is private), and ledger rows.

## Acceptance

Fork CI green; no upstream test edited; `git grep -n "FORK:"` shows every hook.
