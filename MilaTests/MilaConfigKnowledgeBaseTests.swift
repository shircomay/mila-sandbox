import XCTest
@testable import Mila

// Spec 05: the optional `knowledgeBase` section of a `.milaconfig`.
// All paths are synthetic temp directories; every UserDefaults is a private suite.

// MARK: - Parsing

final class MilaConfigKnowledgeBaseDecodeTests: XCTestCase {

    func test_decode_withSection_parsesEveryField() throws {
        let json = """
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
        """.data(using: .utf8)!

        let kb = try XCTUnwrap(try MilaConfig.decode(json).knowledgeBase)
        XCTAssertEqual(kb.enabled, true)
        XCTAssertEqual(kb.folder, "~/path/to/knowledge-base")
        XCTAssertEqual(kb.subfolder, "Mila transcripts")
        XCTAssertEqual(kb.noteContent, "transcript")
        XCTAssertEqual(kb.resolvedNoteContent, .transcript)
        XCTAssertEqual(kb.gitSync, false)
    }

    func test_decode_withoutSection_isNil() throws {
        let json = #"{ "version": 1, "recordingLanguage": "en" }"#.data(using: .utf8)!
        XCTAssertNil(try MilaConfig.decode(json).knowledgeBase)
    }

    func test_decode_partialSection_leavesTheRestNil() throws {
        let json = #"{ "version": 1, "knowledgeBase": { "enabled": false } }"#.data(using: .utf8)!
        let kb = try XCTUnwrap(try MilaConfig.decode(json).knowledgeBase)
        XCTAssertEqual(kb.enabled, false)
        XCTAssertNil(kb.folder)
        XCTAssertNil(kb.subfolder)
        XCTAssertNil(kb.noteContent)
        XCTAssertNil(kb.gitSync)
    }

    func test_unknownNoteContent_decodesButResolvesToNil() throws {
        let json = #"{ "version": 1, "knowledgeBase": { "noteContent": "haiku" } }"#.data(using: .utf8)!
        let kb = try XCTUnwrap(try MilaConfig.decode(json).knowledgeBase)
        XCTAssertEqual(kb.noteContent, "haiku")
        XCTAssertNil(kb.resolvedNoteContent)
    }

    func test_allNoteContentRawValuesResolve() {
        for content in MarkdownExportSettings.NoteContent.allCases {
            XCTAssertEqual(MilaConfig.KnowledgeBase(noteContent: content.rawValue).resolvedNoteContent, content)
        }
    }

    func test_roundTrip_encodeDecode() throws {
        let original = MilaConfig(
            version: 1,
            knowledgeBase: .init(enabled: true,
                                 folder: "~/path/to/knowledge-base",
                                 subfolder: "Mila transcripts",
                                 noteContent: "summaryAndTranscript",
                                 gitSync: true)
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try MilaConfig.decode(data), original)
    }

    func test_encode_omitsAbsentFields() throws {
        let data = try JSONEncoder().encode(MilaConfig(version: 1, knowledgeBase: .init(enabled: true)))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"enabled\""))
        XCTAssertFalse(text.contains("\"folder\""))
        XCTAssertFalse(text.contains("\"gitSync\""))
    }

    func test_existingMemberwiseCalls_stillCompile_andDefaultTheSectionToNil() {
        // Mirrors the call shape in MilaConfigTests: no `knowledgeBase:` argument.
        let config = MilaConfig(version: 1, recordingLanguage: "en", diarization: .init(enabled: true))
        XCTAssertNil(config.knowledgeBase)
    }

    func test_expandedFolderURL_expandsTilde() {
        let url = MilaConfig.KnowledgeBase.expandedFolderURL("~/kb-notes")
        XCTAssertNotNil(url)
        let expectedPrefix = ("~" as NSString).expandingTildeInPath
        XCTAssertTrue(url?.path.hasPrefix(expectedPrefix) ?? false)
        XCTAssertTrue(url?.path.hasSuffix("/kb-notes") ?? false)
        XCTAssertFalse(url?.path.contains("~") ?? true)
        XCTAssertTrue(url?.path.hasPrefix("/") ?? false)
    }

    func test_expandedFolderURL_rejectsRelativeAndEmpty() {
        XCTAssertNil(MilaConfig.KnowledgeBase.expandedFolderURL("relative/path"))
        XCTAssertNil(MilaConfig.KnowledgeBase.expandedFolderURL("./here"))
        XCTAssertNil(MilaConfig.KnowledgeBase.expandedFolderURL(""))
        XCTAssertNil(MilaConfig.KnowledgeBase.expandedFolderURL("   "))
    }

    func test_expandedFolderURL_standardizesDotDot() {
        let url = MilaConfig.KnowledgeBase.expandedFolderURL("/tmp/a/../b")
        XCTAssertEqual(url?.path, "/tmp/b")
    }
}

// MARK: - Plan / apply

@MainActor
final class MilaConfigKnowledgeBaseImporterTests: XCTestCase {

    private struct Harness {
        let importer: MilaConfigImporter
        let obsidian: ObsidianVaultSettings
        let markdownExport: MarkdownExportSettings
        let suite: UserDefaults
        let suiteName: String
        let keychainKey: String
    }

    private var tempRoot: URL!
    private var harnesses: [Harness] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MilaConfigKnowledgeBaseTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for h in harnesses {
            KeychainHelper.delete(key: h.keychainKey)
            h.suite.removePersistentDomain(forName: h.suiteName)
        }
        harnesses = []
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        super.tearDown()
    }

    private func makeHarness(withKnowledgeBaseDependencies: Bool = true,
                             _ label: String = #function) -> Harness {
        let suiteName = "MilaConfigKnowledgeBaseTests.\(label).\(UUID())"
        let suite = UserDefaults(suiteName: suiteName)!
        let keychainKey = "MilaConfigKnowledgeBaseTests.\(UUID()).apiKey"
        KeychainHelper.delete(key: keychainKey)

        let obsidian = ObsidianVaultSettings(defaults: suite)
        let markdownExport = MarkdownExportSettings(defaults: suite)
        let remote = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: keychainKey)
        let language = RecordingLanguageSettings(defaults: suite)
        let liveAI = LiveAISettings(defaults: suite)
        let diarization = DiarizationSettings(defaults: suite)
        let meetingDetection = MeetingDetectionSettings(defaults: suite)
        let importer: MilaConfigImporter
        if withKnowledgeBaseDependencies {
            importer = MilaConfigImporter(remote: remote, language: language, liveAI: liveAI,
                                          diarization: diarization, meetingDetection: meetingDetection,
                                          obsidian: obsidian, markdownExport: markdownExport)
        } else {
            importer = MilaConfigImporter(remote: remote, language: language, liveAI: liveAI,
                                          diarization: diarization, meetingDetection: meetingDetection)
        }
        let h = Harness(importer: importer, obsidian: obsidian, markdownExport: markdownExport,
                        suite: suite, suiteName: suiteName, keychainKey: keychainKey)
        harnesses.append(h)
        return h
    }

    private func samePlace(_ a: URL?, _ b: URL) -> Bool {
        guard let a else { return false }
        return a.resolvingSymlinksInPath().standardizedFileURL.path
            == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func fullConfig(folder: URL) -> MilaConfig {
        MilaConfig(version: 1, knowledgeBase: .init(enabled: true,
                                                    folder: folder.path,
                                                    subfolder: "Mila transcripts",
                                                    noteContent: "transcript",
                                                    gitSync: true))
    }

    // MARK: apply

    func test_apply_setsVaultSubfolderNoteContentGitSyncAndEnabled() throws {
        let h = makeHarness()
        let folder = tempRoot.appendingPathComponent("kb", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertFalse(h.obsidian.enabled)

        h.importer.apply(fullConfig(folder: folder))

        XCTAssertNil(h.importer.errorMessage)
        XCTAssertTrue(samePlace(h.obsidian.vaultURL, folder))
        XCTAssertEqual(h.obsidian.subfolder, "Mila transcripts")
        XCTAssertEqual(h.markdownExport.noteContent, .transcript)
        XCTAssertTrue(h.obsidian.gitSyncEnabled)
        XCTAssertTrue(h.obsidian.enabled)
        XCTAssertEqual(h.suite.string(forKey: MarkdownExportSettings.noteContentKey), "transcript")
    }

    func test_apply_createsMissingFolder_butNotItsParents() throws {
        let h = makeHarness()
        let folder = tempRoot.appendingPathComponent("created-for-me", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))

        h.importer.apply(MilaConfig(version: 1, knowledgeBase: .init(enabled: true, folder: folder.path)))

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertTrue(samePlace(h.obsidian.vaultURL, folder))
        XCTAssertTrue(h.obsidian.enabled)

        let orphan = tempRoot.appendingPathComponent("no-such-parent/child", isDirectory: true)
        let other = makeHarness("missingParent")
        other.importer.apply(MilaConfig(version: 1, knowledgeBase: .init(enabled: true, folder: orphan.path)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertNotNil(other.importer.errorMessage)
        XCTAssertNil(other.obsidian.vaultURL)
        XCTAssertFalse(other.obsidian.enabled, "enabled is applied last, so a failed folder leaves it off")
    }

    func test_apply_folderThatIsAFile_failsWithMessage() throws {
        let h = makeHarness()
        let file = tempRoot.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: file)

        h.importer.apply(MilaConfig(version: 1, knowledgeBase: .init(enabled: true, folder: file.path)))

        XCTAssertNotNil(h.importer.errorMessage)
        XCTAssertNil(h.obsidian.vaultURL)
        XCTAssertFalse(h.obsidian.enabled)
    }

    func test_apply_relativeFolder_isRejectedWithMessage() {
        let h = makeHarness()
        h.importer.apply(MilaConfig(version: 1,
                                    knowledgeBase: .init(enabled: true,
                                                         folder: "relative/kb",
                                                         noteContent: "transcript")))
        XCTAssertNotNil(h.importer.errorMessage)
        XCTAssertNil(h.obsidian.vaultURL)
        XCTAssertFalse(h.obsidian.enabled)
        XCTAssertEqual(h.markdownExport.noteContent, .summaryElseTranscript,
                       "a rejected folder skips the rest of the section")
    }

    func test_apply_absentFieldsLeaveCurrentUntouched() {
        let h = makeHarness()
        h.obsidian.subfolder = "Keep me"
        h.obsidian.gitSyncEnabled = true
        h.markdownExport.noteContent = .summaryAndTranscript

        h.importer.apply(MilaConfig(version: 1, knowledgeBase: .init(enabled: true)))

        XCTAssertEqual(h.obsidian.subfolder, "Keep me")
        XCTAssertTrue(h.obsidian.gitSyncEnabled)
        XCTAssertEqual(h.markdownExport.noteContent, .summaryAndTranscript)
        XCTAssertTrue(h.obsidian.enabled)
    }

    func test_apply_unknownNoteContent_isIgnored_restStillApplies() {
        let h = makeHarness()
        h.markdownExport.noteContent = .summaryAndTranscript

        h.importer.apply(MilaConfig(version: 1,
                                    knowledgeBase: .init(enabled: true,
                                                         subfolder: "Notes",
                                                         noteContent: "haiku")))

        XCTAssertEqual(h.markdownExport.noteContent, .summaryAndTranscript)
        XCTAssertEqual(h.obsidian.subfolder, "Notes")
        XCTAssertTrue(h.obsidian.enabled)
        XCTAssertNil(h.importer.errorMessage)
    }

    func test_apply_enabledFalse_turnsItOff() {
        let h = makeHarness()
        h.obsidian.enabled = true
        h.importer.apply(MilaConfig(version: 1, knowledgeBase: .init(enabled: false)))
        XCTAssertFalse(h.obsidian.enabled)
    }

    func test_apply_withoutSection_changesNothing() {
        let h = makeHarness()
        h.importer.apply(MilaConfig(version: 1, recordingLanguage: "en"))
        XCTAssertFalse(h.obsidian.enabled)
        XCTAssertNil(h.obsidian.vaultURL)
        XCTAssertEqual(h.obsidian.subfolder, ObsidianVaultSettings.defaultSubfolder)
    }

    // MARK: plannedChanges

    func test_plannedChanges_listsEveryDifference_thenNothingOnceApplied() throws {
        let h = makeHarness()
        let folder = tempRoot.appendingPathComponent("kb", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = fullConfig(folder: folder)

        let labels = h.importer.plannedChanges(for: config).map(\.label)
        XCTAssertEqual(labels, ["Knowledge base folder",
                                "Save transcripts there automatically",
                                "Knowledge base notes contain",
                                "Commit & push the folder with git"])

        let folderChange = h.importer.plannedChanges(for: config).first { $0.label == "Knowledge base folder" }
        XCTAssertTrue(folderChange?.value.hasSuffix(" / Mila transcripts") ?? false)
        let contentChange = h.importer.plannedChanges(for: config).first { $0.label == "Knowledge base notes contain" }
        XCTAssertEqual(contentChange?.value, MarkdownExportSettings.NoteContent.transcript.displayName)

        h.importer.apply(config)
        XCTAssertTrue(h.importer.plannedChanges(for: config).isEmpty,
                      "a config that matches the current settings lists no changes")
    }

    func test_plannedChanges_onlyTheDifferingField() {
        let h = makeHarness()
        h.obsidian.enabled = true
        h.markdownExport.noteContent = .transcript
        let config = MilaConfig(version: 1,
                                knowledgeBase: .init(enabled: true,
                                                     subfolder: ObsidianVaultSettings.defaultSubfolder,
                                                     noteContent: "transcript",
                                                     gitSync: true))
        let changes = h.importer.plannedChanges(for: config)
        XCTAssertEqual(changes.map(\.label), ["Commit & push the folder with git"])
        XCTAssertEqual(changes.first?.value, "On")
    }

    func test_plannedChanges_relativeFolderIsShownAsIgnored() {
        let h = makeHarness()
        let changes = h.importer.plannedChanges(
            for: MilaConfig(version: 1, knowledgeBase: .init(folder: "relative/kb")))
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.label, "Knowledge base folder")
        XCTAssertTrue(changes.first?.value.hasPrefix("Ignored") ?? false)
    }

    func test_plannedChanges_unknownNoteContentIsNotListed() {
        let h = makeHarness()
        let changes = h.importer.plannedChanges(
            for: MilaConfig(version: 1, knowledgeBase: .init(noteContent: "haiku")))
        XCTAssertTrue(changes.isEmpty)
    }

    func test_plannedChanges_noSection_isEmpty() {
        let h = makeHarness()
        XCTAssertTrue(h.importer.plannedChanges(for: MilaConfig(version: 1)).isEmpty)
    }

    // MARK: importer built without the new dependencies

    func test_importerWithoutDependencies_ignoresTheSection() {
        let h = makeHarness(withKnowledgeBaseDependencies: false)
        let config = fullConfig(folder: tempRoot.appendingPathComponent("never-created", isDirectory: true))

        XCTAssertTrue(h.importer.plannedChanges(for: config).isEmpty)
        h.importer.apply(config)

        XCTAssertNil(h.importer.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempRoot.appendingPathComponent("never-created").path),
                       "no vault settings means no folder is created")
    }

    // MARK: end to end through handleOpen

    func test_handleOpen_stagesThenConfirmApplies() throws {
        let h = makeHarness()
        let folder = tempRoot.appendingPathComponent("kb", isDirectory: true)
        let json = """
        { "version": 1,
          "knowledgeBase": { "enabled": true, "folder": "\(folder.path)", "noteContent": "summaryAndTranscript" } }
        """
        let file = tempRoot.appendingPathComponent("kb.milaconfig")
        try json.write(to: file, atomically: true, encoding: .utf8)

        h.importer.handleOpen(file)
        XCTAssertNil(h.importer.errorMessage)
        XCTAssertNotNil(h.importer.pending)
        XCTAssertFalse(h.importer.pending?.changes.isEmpty ?? true)
        XCTAssertFalse(h.obsidian.enabled, "nothing is applied before the user confirms")

        h.importer.confirm()
        XCTAssertTrue(samePlace(h.obsidian.vaultURL, folder))
        XCTAssertTrue(h.obsidian.enabled)
        XCTAssertEqual(h.markdownExport.noteContent, .summaryAndTranscript)
    }
}
