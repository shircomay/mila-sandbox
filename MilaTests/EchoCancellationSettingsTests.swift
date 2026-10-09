import XCTest
@testable import Mila

/// FORK (echo cancellation, spec 03). The settings object, its UserDefaults
/// contract (the keys are shared with the personal build's registered defaults)
/// and the one-line "Last meeting" summary.
@MainActor
final class EchoCancellationSettingsTests: XCTestCase {

    /// A throwaway suite so no test touches `UserDefaults.standard`.
    private func freshDefaults() -> UserDefaults {
        let suite = "EchoCancellationSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: - Defaults and persistence

    /// The code default is the upstream behaviour: nothing changes for a build
    /// that does not register its own defaults.
    func test_everything_defaults_off_and_there_is_no_summary() {
        let defaults = freshDefaults()
        let settings = EchoCancellationSettings(defaults: defaults)
        XCTAssertFalse(settings.enabled)
        XCTAssertFalse(settings.saveDebugAudio)
        XCTAssertNil(settings.lastSessionSummary)
        XCTAssertFalse(EchoCancellationSettings.isEnabled(defaults))
        XCTAssertFalse(EchoCancellationSettings.savesDebugAudio(defaults))
    }

    func test_keys_are_the_shared_contract() {
        XCTAssertEqual(EchoCancellationSettings.Keys.enabled, "echoCancellation.enabled")
        XCTAssertEqual(EchoCancellationSettings.Keys.saveDebugAudio, "echoCancellation.saveDebugAudio")
        XCTAssertEqual(EchoCancellationSettings.Keys.lastSessionSummary, "echoCancellation.lastSessionSummary")
    }

    func test_toggles_write_through_and_survive_a_relaunch() {
        let defaults = freshDefaults()
        let settings = EchoCancellationSettings(defaults: defaults)
        settings.enabled = true
        settings.saveDebugAudio = true
        XCTAssertTrue(defaults.bool(forKey: "echoCancellation.enabled"))
        XCTAssertTrue(defaults.bool(forKey: "echoCancellation.saveDebugAudio"))
        XCTAssertTrue(EchoCancellationSettings.isEnabled(defaults))
        XCTAssertTrue(EchoCancellationSettings.savesDebugAudio(defaults))

        let relaunched = EchoCancellationSettings(defaults: defaults)
        XCTAssertTrue(relaunched.enabled)
        XCTAssertTrue(relaunched.saveDebugAudio)

        relaunched.enabled = false
        XCTAssertFalse(EchoCancellationSettings.isEnabled(defaults))
    }

    /// The personal build turns the feature on with `register(defaults:)`.
    /// That must be visible to the settings object and to `isEnabled`, and must
    /// never beat a value the user chose.
    func test_registered_defaults_apply_but_never_override_the_user() {
        let defaults = freshDefaults()
        defaults.register(defaults: ["echoCancellation.enabled": true])
        XCTAssertTrue(EchoCancellationSettings.isEnabled(defaults), "registered default is honoured")
        XCTAssertTrue(EchoCancellationSettings(defaults: defaults).enabled)

        let settings = EchoCancellationSettings(defaults: defaults)
        settings.enabled = false
        XCTAssertFalse(EchoCancellationSettings.isEnabled(defaults), "the user's explicit OFF wins")
        XCTAssertFalse(EchoCancellationSettings(defaults: defaults).enabled)
    }

    // MARK: - Last-meeting summary

    func test_stored_summary_is_read_at_init_and_on_refresh() {
        let defaults = freshDefaults()
        let settings = EchoCancellationSettings(defaults: defaults)
        XCTAssertNil(settings.lastSessionSummary)

        // The session writes the key directly when a meeting stops.
        EchoCancellationSettings.storeSessionSummary("echo reduced ≈18 dB", in: defaults)
        XCTAssertNil(settings.lastSessionSummary, "not live: the view refreshes on appear")
        settings.refreshLastSessionSummary()
        XCTAssertEqual(settings.lastSessionSummary, "echo reduced ≈18 dB")

        XCTAssertEqual(EchoCancellationSettings(defaults: defaults).lastSessionSummary,
                       "echo reduced ≈18 dB")
    }

    func test_storing_an_empty_or_nil_summary_clears_it() {
        let defaults = freshDefaults()
        EchoCancellationSettings.storeSessionSummary("something", in: defaults)
        XCTAssertNotNil(EchoCancellationSettings.storedSessionSummary(defaults))

        EchoCancellationSettings.storeSessionSummary("", in: defaults)
        XCTAssertNil(EchoCancellationSettings.storedSessionSummary(defaults))
        XCTAssertNil(defaults.object(forKey: "echoCancellation.lastSessionSummary"))

        EchoCancellationSettings.storeSessionSummary("again", in: defaults)
        EchoCancellationSettings.storeSessionSummary(nil, in: defaults)
        XCTAssertNil(EchoCancellationSettings.storedSessionSummary(defaults))
    }

    func test_summary_does_not_leak_into_the_toggle_keys() {
        let defaults = freshDefaults()
        EchoCancellationSettings.storeSessionSummary("echo reduced ≈18 dB", in: defaults)
        XCTAssertFalse(EchoCancellationSettings.isEnabled(defaults))
        XCTAssertFalse(EchoCancellationSettings.savesDebugAudio(defaults))
    }

    // MARK: - Summary line

    func test_summary_line_matches_the_documented_shape() {
        let line = EchoCancellationSummary.sessionLine(framesProcessed: 1_000,
                                                       framesWithReference: 630,
                                                       echoReductionDb: 18.4,
                                                       estimatedEchoDelayMs: 41.6,
                                                       timestampsTrusted: true)
        XCTAssertEqual(line, "echo reduced ≈18 dB · echo delay ≈42 ms · reference present 63% of the time")
    }

    func test_summary_line_degrades_gracefully_when_nothing_was_measured() {
        let line = EchoCancellationSummary.sessionLine(framesProcessed: 400,
                                                       framesWithReference: 0,
                                                       echoReductionDb: nil,
                                                       estimatedEchoDelayMs: nil,
                                                       timestampsTrusted: true)
        XCTAssertEqual(line, "echo reduction not measured · reference present 0% of the time")

        let empty = EchoCancellationSummary.sessionLine(framesProcessed: 0,
                                                        framesWithReference: 0,
                                                        echoReductionDb: nil,
                                                        estimatedEchoDelayMs: nil,
                                                        timestampsTrusted: true)
        XCTAssertEqual(empty, "echo reduction not measured · no microphone audio was processed")
    }

    func test_summary_line_flags_untrusted_timestamps() {
        let line = EchoCancellationSummary.sessionLine(framesProcessed: 100,
                                                       framesWithReference: 100,
                                                       echoReductionDb: 12,
                                                       estimatedEchoDelayMs: nil,
                                                       timestampsTrusted: false)
        XCTAssertTrue(line.hasSuffix("clocks disagreed, aligned by arrival order"), line)
    }

    /// `Int(_:)` of NaN or infinity traps, and an ERLE of +∞ is exactly what a
    /// perfectly silent output would give.
    func test_summary_line_survives_non_finite_statistics() {
        let line = EchoCancellationSummary.sessionLine(framesProcessed: 10,
                                                       framesWithReference: 10,
                                                       echoReductionDb: .infinity,
                                                       estimatedEchoDelayMs: .nan,
                                                       timestampsTrusted: true)
        XCTAssertEqual(line, "echo reduction not measured · reference present 100% of the time")
    }

    func test_bypass_line() {
        XCTAssertEqual(EchoCancellationSummary.bypassLine(reason: "the echo canceller could not start"),
                       "bypassed: the echo canceller could not start")
    }
}
