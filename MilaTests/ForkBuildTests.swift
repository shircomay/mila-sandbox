import XCTest
@testable import Mila

final class ForkBuildTests: XCTestCase {
    private var suiteNames: [String] = []

    private func makeSuite(_ name: String) -> UserDefaults {
        let full = "ForkBuildTests.\(name)"
        let defaults = UserDefaults(suiteName: full)!
        defaults.removePersistentDomain(forName: full)
        suiteNames.append(full)
        return defaults
    }

    override func tearDown() {
        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        suiteNames = []
        super.tearDown()
    }

    func test_applyPersonalDefaults_setsPersonalBuildValues() {
        let defaults = makeSuite("set")
        ForkBuild.applyPersonalDefaults(on: defaults)
        XCTAssertTrue(defaults.bool(forKey: "markdownExport.sidecarEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "markdownExport.paragraphTimestamps"))
        XCTAssertEqual(defaults.string(forKey: "markdownExport.noteContent"), "summaryAndTranscript")
        XCTAssertTrue(defaults.bool(forKey: "echoCancellation.enabled"))
        XCTAssertNotNil(defaults.object(forKey: "echoCancellation.saveDebugAudio"))
        XCTAssertFalse(defaults.bool(forKey: "echoCancellation.saveDebugAudio"))
        XCTAssertNil(defaults.object(forKey: "echoCancellation.lastSessionSummary"))
    }

    func test_applyPersonalDefaults_doesNotOverrideUserValues() {
        let defaults = makeSuite("user")
        defaults.set(false, forKey: "markdownExport.sidecarEnabled")
        defaults.set("transcriptOnly", forKey: "markdownExport.noteContent")
        ForkBuild.applyPersonalDefaults(on: defaults)
        XCTAssertFalse(defaults.bool(forKey: "markdownExport.sidecarEnabled"))
        XCTAssertEqual(defaults.string(forKey: "markdownExport.noteContent"), "transcriptOnly")
        XCTAssertTrue(defaults.bool(forKey: "echoCancellation.enabled"))
    }

    func test_applyPersonalDefaults_doesNotLeakToOtherSuites() {
        let applied = makeSuite("applied")
        let other = makeSuite("other")
        ForkBuild.applyPersonalDefaults(on: applied)
        XCTAssertNil(other.object(forKey: "markdownExport.sidecarEnabled"))
        XCTAssertNil(other.object(forKey: "echoCancellation.enabled"))
    }

    func test_applyPersonalDefaults_isIdempotent_andKeepsLaterUserChoices() {
        let defaults = makeSuite("idempotent")
        ForkBuild.applyPersonalDefaults(on: defaults)
        defaults.set(false, forKey: "echoCancellation.enabled")   // the owner turns it off
        ForkBuild.applyPersonalDefaults(on: defaults)              // next launch
        XCTAssertFalse(defaults.bool(forKey: "echoCancellation.enabled"))
        XCTAssertTrue(defaults.bool(forKey: "markdownExport.sidecarEnabled"))
    }
}
