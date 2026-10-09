import XCTest
@testable import Mila

/// Every test uses its own `UserDefaults` suite; `.standard` is never touched.
final class MarkdownExportSettingsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MarkdownExportSettingsTests.\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    func test_code_defaults_are_upstream_behaviour() {
        let settings = MarkdownExportSettings(defaults: defaults)
        XCTAssertFalse(settings.sidecarEnabled)
        XCTAssertTrue(settings.paragraphTimestamps)
        XCTAssertEqual(settings.noteContent, .summaryElseTranscript)

        let snapshot = MarkdownExportSettings.current(defaults)
        XCTAssertEqual(snapshot, MarkdownExportSettings.Snapshot(sidecarEnabled: false,
                                                                 paragraphTimestamps: true,
                                                                 noteContent: .summaryElseTranscript))
    }

    func test_keys_are_the_shared_contract() {
        XCTAssertEqual(MarkdownExportSettings.sidecarEnabledKey, "markdownExport.sidecarEnabled")
        XCTAssertEqual(MarkdownExportSettings.paragraphTimestampsKey, "markdownExport.paragraphTimestamps")
        XCTAssertEqual(MarkdownExportSettings.noteContentKey, "markdownExport.noteContent")
    }

    func test_raw_values_are_the_shared_contract() {
        XCTAssertEqual(MarkdownExportSettings.NoteContent.summaryElseTranscript.rawValue, "summaryElseTranscript")
        XCTAssertEqual(MarkdownExportSettings.NoteContent.transcript.rawValue, "transcript")
        XCTAssertEqual(MarkdownExportSettings.NoteContent.summaryAndTranscript.rawValue, "summaryAndTranscript")
        XCTAssertEqual(MarkdownExportSettings.NoteContent.allCases.count, 3)
    }

    func test_changes_persist_under_the_namespaced_keys() {
        let settings = MarkdownExportSettings(defaults: defaults)
        settings.sidecarEnabled = true
        settings.paragraphTimestamps = false
        settings.noteContent = .summaryAndTranscript

        XCTAssertEqual(defaults.object(forKey: "markdownExport.sidecarEnabled") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "markdownExport.paragraphTimestamps") as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: "markdownExport.noteContent"), "summaryAndTranscript")

        let reloaded = MarkdownExportSettings(defaults: defaults)
        XCTAssertTrue(reloaded.sidecarEnabled)
        XCTAssertFalse(reloaded.paragraphTimestamps)
        XCTAssertEqual(reloaded.noteContent, .summaryAndTranscript)

        XCTAssertEqual(MarkdownExportSettings.current(defaults),
                       MarkdownExportSettings.Snapshot(sidecarEnabled: true,
                                                       paragraphTimestamps: false,
                                                       noteContent: .summaryAndTranscript))
    }

    func test_an_unrecognised_note_content_falls_back_to_the_default() {
        defaults.set("somethingElse", forKey: MarkdownExportSettings.noteContentKey)
        XCTAssertEqual(MarkdownExportSettings.current(defaults).noteContent, .summaryElseTranscript)
        XCTAssertEqual(MarkdownExportSettings(defaults: defaults).noteContent, .summaryElseTranscript)
    }

    func test_personal_defaults_written_by_the_fork_are_honoured_and_a_user_choice_overrides_them() {
        // What the personal build does at launch (`ForkBuild.applyPersonalDefaults`):
        // plain writes into the app's own domain. Never `register(defaults:)` in a
        // test — the registration domain is process-wide and leaks into every suite.
        defaults.set(true, forKey: MarkdownExportSettings.sidecarEnabledKey)
        defaults.set("summaryAndTranscript", forKey: MarkdownExportSettings.noteContentKey)
        var snapshot = MarkdownExportSettings.current(defaults)
        XCTAssertTrue(snapshot.sidecarEnabled)
        XCTAssertTrue(snapshot.paragraphTimestamps, "an unset key keeps its code default")
        XCTAssertEqual(snapshot.noteContent, .summaryAndTranscript)

        defaults.set(false, forKey: MarkdownExportSettings.sidecarEnabledKey)
        snapshot = MarkdownExportSettings.current(defaults)
        XCTAssertFalse(snapshot.sidecarEnabled, "the owner's later choice wins")
    }

    func test_setting_the_same_value_does_not_rewrite_defaults() {
        let settings = MarkdownExportSettings(defaults: defaults)
        settings.sidecarEnabled = false   // unchanged from the code default
        XCTAssertNil(defaults.object(forKey: MarkdownExportSettings.sidecarEnabledKey))
    }

    func test_display_names_are_distinct_and_non_empty() {
        let names = MarkdownExportSettings.NoteContent.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertFalse(names.contains(""))
    }
}
