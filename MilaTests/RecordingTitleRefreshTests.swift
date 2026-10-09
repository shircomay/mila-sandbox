import XCTest
import TranscriptionCore
@testable import Mila

/// Spec 05, part B: a completed recording's new title reaches the `.md`
/// sidecar and fires `onCompletedRecordingRetitled` (which MilaApp wires to the
/// Obsidian exporter).
///
/// `RecordingStore` reads the sidecar setting from `UserDefaults.standard` (the
/// spec-01 hooks take no injected defaults), so `setUp` switches
/// `markdownExport.sidecarEnabled` on there and `tearDown` puts back exactly
/// what was explicitly stored before (nothing, when the key was only a
/// registered default). Every recording and directory is synthetic.
@MainActor
final class RecordingTitleRefreshTests: XCTestCase {

    private static let key = MarkdownExportSettings.sidecarEnabledKey

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var hadExplicitValue = false
    private var explicitValue: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = TestSupport.makeTempRoot(label: "RecordingTitleRefreshTests")

        let standard = UserDefaults.standard
        if let domain = Bundle.main.bundleIdentifier,
           let stored = standard.persistentDomain(forName: domain)?[Self.key] {
            hadExplicitValue = true
            explicitValue = stored
        } else {
            hadExplicitValue = false
            explicitValue = nil
        }
        standard.set(true, forKey: Self.key)

        store = RecordingStore(rootDirectory: tempRoot)
    }

    override func tearDown() {
        let standard = UserDefaults.standard
        if hadExplicitValue, let explicitValue {
            standard.set(explicitValue, forKey: Self.key)
        } else {
            standard.removeObject(forKey: Self.key)
        }
        store = nil
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        super.tearDown()
    }

    // MARK: - Fixtures

    private func completed(title: String = "Weekly sync",
                           status: TranscriptionStatus = .completed) -> Recording {
        Recording(
            title: title,
            duration: 12,
            source: .microphone,
            audioFileName: "retitle-fixture.wav",
            status: status,
            language: "en",
            segments: [
                TranscriptSegment(start: 0, end: 5, text: "First sentence."),
                TranscriptSegment(start: 5, end: 9, text: "Second sentence."),
            ],
            fullText: "First sentence. Second sentence."
        )
    }

    private func sidecarText(for recording: Recording) -> String? {
        let url = MarkdownTranscriptExporter.sidecarURL(for: recording, in: store.recordingsDirectory)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Collect the callback's arguments.
    private func recordCallbacks() -> CallLog {
        let log = CallLog()
        store.onCompletedRecordingRetitled = { log.titles.append($0.title) }
        return log
    }

    private final class CallLog {
        var titles: [String] = []
    }

    // MARK: - update(_:)

    func test_update_withChangedTitle_firesCallbackOnce_andRewritesSidecar() {
        var recording = completed()
        store.add(recording)
        XCTAssertNil(sidecarText(for: recording), "add() alone writes no .md sidecar")
        let log = recordCallbacks()

        recording.title = "Budget review"
        store.update(recording)

        XCTAssertEqual(log.titles, ["Budget review"])
        let text = sidecarText(for: recording)
        XCTAssertNotNil(text, "the sidecar is written with the new title")
        XCTAssertTrue(text?.contains("# Budget review") ?? false)
        XCTAssertTrue(text?.contains("title: \"Budget review\"") ?? false)
    }

    func test_update_overwritesAnExistingSidecarWithTheNewTitle() {
        var recording = completed(title: "Old name")
        store.add(recording)
        MarkdownTranscriptExporter.writeSidecar(for: recording, in: store.recordingsDirectory)
        XCTAssertTrue(sidecarText(for: recording)?.contains("# Old name") ?? false)

        recording.title = "New name"
        store.update(recording)

        let text = sidecarText(for: recording)
        XCTAssertTrue(text?.contains("# New name") ?? false)
        XCTAssertFalse(text?.contains("Old name") ?? true)
    }

    func test_update_withUnchangedTitle_firesNoCallback_andWritesNoSidecar() {
        var recording = completed()
        store.add(recording)
        let log = recordCallbacks()

        recording.summary = "A summary arrived."   // any other change
        store.update(recording)

        XCTAssertTrue(log.titles.isEmpty)
        XCTAssertNil(sidecarText(for: recording))
    }

    func test_update_withChangedTitle_onNonCompletedRecording_firesNoCallback() {
        for status in [TranscriptionStatus.pending, .failed] {
            var recording = completed(status: status)
            store.add(recording)
            let log = recordCallbacks()

            recording.title = "Renamed while \(status)"
            store.update(recording)

            XCTAssertTrue(log.titles.isEmpty, "\(status) must not fire the callback")
            XCTAssertNil(sidecarText(for: recording), "\(status) must not get a sidecar")
        }
    }

    func test_update_forUnknownRecording_firesNoCallback() {
        let log = recordCallbacks()
        var stranger = completed()
        stranger.title = "Never stored"
        XCTAssertFalse(store.update(stranger))
        XCTAssertTrue(log.titles.isEmpty)
    }

    func test_updateRetiringSpeakerNames_overload_alsoFiresOnRetitle() {
        var recording = completed()
        store.add(recording)
        let log = recordCallbacks()

        recording.title = "Via the overload"
        store.update(recording, retiringSpeakerNames: [:])

        XCTAssertEqual(log.titles, ["Via the overload"])
    }

    // MARK: - rename(_:to:)

    func test_rename_firesCallback_andRewritesSidecar() {
        let recording = completed()
        store.add(recording)
        let log = recordCallbacks()

        store.rename(recording, to: "  Renamed by hand  ")

        XCTAssertEqual(log.titles, ["Renamed by hand"], "the callback sees the trimmed title")
        XCTAssertTrue(sidecarText(for: recording)?.contains("# Renamed by hand") ?? false)
    }

    func test_rename_toTheSameOrBlankTitle_firesNoCallback() {
        let recording = completed()
        store.add(recording)
        let log = recordCallbacks()

        store.rename(recording, to: recording.title)
        store.rename(recording, to: "   ")

        XCTAssertTrue(log.titles.isEmpty)
    }

    func test_rename_onNonCompletedRecording_firesNoCallback() {
        let recording = completed(status: .pending)
        store.add(recording)
        let log = recordCallbacks()

        store.rename(recording, to: "Renamed while pending")

        XCTAssertTrue(log.titles.isEmpty)
    }
}
