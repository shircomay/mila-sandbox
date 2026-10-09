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

    func test_registerDefaults_setsPersonalBuildValues() {
        let defaults = makeSuite("set")
        ForkBuild.registerDefaults(on: defaults)
        XCTAssertTrue(defaults.bool(forKey: "markdownExport.sidecarEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "markdownExport.paragraphTimestamps"))
        XCTAssertEqual(defaults.string(forKey: "markdownExport.noteContent"), "summaryAndTranscript")
        XCTAssertTrue(defaults.bool(forKey: "echoCancellation.enabled"))
        XCTAssertNotNil(defaults.object(forKey: "echoCancellation.saveDebugAudio"))
        XCTAssertFalse(defaults.bool(forKey: "echoCancellation.saveDebugAudio"))
        XCTAssertNil(defaults.object(forKey: "echoCancellation.lastSessionSummary"))
    }

    func test_registerDefaults_doesNotOverrideUserValues() {
        let defaults = makeSuite("user")
        defaults.set(false, forKey: "markdownExport.sidecarEnabled")
        defaults.set("transcriptOnly", forKey: "markdownExport.noteContent")
        ForkBuild.registerDefaults(on: defaults)
        XCTAssertFalse(defaults.bool(forKey: "markdownExport.sidecarEnabled"))
        XCTAssertEqual(defaults.string(forKey: "markdownExport.noteContent"), "transcriptOnly")
        XCTAssertTrue(defaults.bool(forKey: "echoCancellation.enabled"))
    }

    func test_registerDefaults_doesNotLeakToOtherSuites() {
        let registered = makeSuite("registered")
        let other = makeSuite("other")
        ForkBuild.registerDefaults(on: registered)
        XCTAssertNil(other.object(forKey: "markdownExport.sidecarEnabled"))
        XCTAssertNil(other.object(forKey: "echoCancellation.enabled"))
    }
}
