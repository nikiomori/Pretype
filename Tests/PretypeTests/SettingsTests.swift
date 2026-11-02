import XCTest
@testable import Pretype

final class SettingsTests: XCTestCase {
    /// `@Pref` stores an enum as its raw string — what `@AppStorage` reads
    /// back — and answers an unset key with the declared default. Strengths
    /// stored before personalization became on/off all read as on.
    func testPrefStoresRawValuesAndDefaults() {
        let defaults = Settings.store
        let saved = (defaults.object(forKey: "hotkeyStyle"), defaults.object(forKey: "personalizationLevel"))
        defer {
            defaults.set(saved.0, forKey: "hotkeyStyle")
            defaults.set(saved.1, forKey: "personalizationLevel")
        }
        defaults.removeObject(forKey: "hotkeyStyle")
        defaults.removeObject(forKey: "personalizationLevel")
        XCTAssertEqual(Settings.hotkeyStyle, .tab)
        XCTAssertEqual(Settings.personalizationLevel, .on)
        Settings.hotkeyStyle = .cmdSpace
        XCTAssertEqual(defaults.string(forKey: "hotkeyStyle"), "cmdSpace")
        for (stored, level) in [("subtle", PersonalizationLevel.on), ("strong", .on), ("off", .off)] {
            defaults.set(stored, forKey: "personalizationLevel")
            XCTAssertEqual(Settings.personalizationLevel, level, stored)
        }
    }

    // The settings map moves the Model tab onto the pooled EN+RU sample. Left
    // on behind the list, it ranked the list on that sample under a picker
    // that read another language — and it persisted across launches.
    @MainActor
    func testSettingsMapAxisOnlyWhileTheMapShows() {
        let defaults = Settings.store
        let keys = ["accuracyAxis", "settingsMapMode", "modelsAsMap"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        Settings.accuracyAxis = "ru"
        Settings.settingsMapMode = true
        Settings.modelsAsMap = false
        let store = SettingsStore(controller: nil)
        XCTAssertEqual(store.effectiveAxis, "ru")
        XCTAssertEqual(store.axisSelection, "ru")
        store.modelsAsMap = true
        XCTAssertEqual(store.effectiveAxis, "core")
        XCTAssertEqual(store.axisSelection, "core", "the picker names the sample the figures are on")
        // Picking the language already stored still ends the settings map.
        store.axisSelection = "ru"
        XCTAssertFalse(Settings.settingsMapMode)
        XCTAssertEqual(store.effectiveAxis, "ru")
        // The pooled entry is never stored as the language.
        store.settingsMapMode = true
        store.axisSelection = "core"
        XCTAssertEqual(Settings.accuracyAxis, "ru")
        XCTAssertEqual(store.effectiveAxis, "core")
    }

    // A model that fixes text but writes nothing: Replies reads as blocked,
    // until a hosted model takes the reply instead.
    @MainActor
    func testRepliesFollowWhetherTheModelWrites() {
        let saved = Settings.apiText
        defer { Settings.apiText = saved }
        let store = SettingsStore(controller: nil)
        store.modelID = ModelCatalog.defaultID
        XCTAssertTrue(store.writesNewText)
        store.modelID = "nikimoriOne/EuroLLM-1.7B-Pretype-5bit"
        XCTAssertFalse(store.writesNewText)
        store.apiText.enabled = true
        XCTAssertTrue(store.writesNewText)
    }

    // Sentences, or Suggestions on, load the model at once: weights not on this
    // Mac wait for a confirmation, with the switch showing what runs. Declining
    // leaves it there; stopping, or weights already here, never ask.
    @MainActor
    func testStartingSuggestionsAsksBeforeADownload() throws {
        let saved = (Settings.mlxModelID, Settings.completionStyle, Settings.suggestionMode, Settings.suggestionsEnabled)
        defer { (Settings.mlxModelID, Settings.completionStyle, Settings.suggestionMode, Settings.suggestionsEnabled) = saved }
        try withScratchHub {
            (Settings.mlxModelID, Settings.completionStyle, Settings.suggestionMode, Settings.suggestionsEnabled)
                = ("mlx-community/gemma-4-e4b-8bit", .base, .words, true)
            let store = SettingsStore(controller: nil)

            store.suggestionMode = .sentences
            XCTAssertEqual(store.pendingDownload?.name, "Gemma 4 E4B 8-bit")
            XCTAssertEqual(store.suggestionMode, .words)
            XCTAssertEqual(Settings.suggestionMode, .words)
            store.pendingDownload?.commit()
            XCTAssertEqual(Settings.suggestionMode, .sentences)
            store.pendingDownload = nil
            store.sync()
            XCTAssertEqual(store.suggestionMode, .sentences)

            store.suggestions = false
            XCTAssertNil(store.pendingDownload, "stopping loads nothing")
            XCTAssertFalse(Settings.suggestionsEnabled)
            store.suggestions = true
            XCTAssertNotNil(store.pendingDownload)
            XCTAssertFalse(store.suggestions)
            XCTAssertFalse(Settings.suggestionsEnabled)
            store.pendingDownload = nil  // declined

            Settings.mlxModelID = ModelCatalog.appleIntelligenceID
            store.sync()
            store.suggestions = true
            XCTAssertNil(store.pendingDownload, "nothing to fetch")
            XCTAssertTrue(Settings.suggestionsEnabled)
        }
    }

    // With API text on, nothing the Model pane does loads a local model: no
    // download to confirm, and the pick waits for the API to go off.
    @MainActor
    func testAModelSwitchUnderTheAPIAsksNothing() throws {
        let saved = (Settings.mlxModelID, Settings.completionStyle, Settings.suggestionMode, Settings.suggestionsEnabled, Settings.apiText)
        defer { (Settings.mlxModelID, Settings.completionStyle, Settings.suggestionMode, Settings.suggestionsEnabled, Settings.apiText) = saved }
        try withScratchHub {
            (Settings.mlxModelID, Settings.completionStyle, Settings.suggestionMode, Settings.suggestionsEnabled)
                = (ModelCatalog.appleIntelligenceID, .base, .sentences, true)
            Settings.apiText = APIConfig(provider: .custom, kind: .text, enabled: true)
            let store = SettingsStore(controller: nil)
            store.selectModel("mlx-community/gemma-4-e4b-8bit")
            XCTAssertNil(store.pendingDownload)
            XCTAssertEqual(store.modelID, "mlx-community/gemma-4-e4b-8bit")
        }
    }

    // Turning API text off hands suggestions back to the local model: the same
    // confirmation if its weights aren't here, and API text stays on if declined.
    @MainActor
    func testLeavingTheAPIAsksBeforeADownload() throws {
        let saved = (Settings.mlxModelID, Settings.completionStyle, Settings.suggestionMode, Settings.suggestionsEnabled, Settings.apiText)
        defer { (Settings.mlxModelID, Settings.completionStyle, Settings.suggestionMode, Settings.suggestionsEnabled, Settings.apiText) = saved }
        try withScratchHub {
            (Settings.mlxModelID, Settings.completionStyle, Settings.suggestionMode, Settings.suggestionsEnabled)
                = ("mlx-community/gemma-4-e4b-8bit", .base, .words, true)
            Settings.apiText = APIConfig(provider: .custom, kind: .text, enabled: true)
            let store = SettingsStore(controller: nil)

            // With API text on, Sentences loads nothing yet.
            store.suggestionMode = .sentences
            XCTAssertNil(store.pendingDownload)
            XCTAssertEqual(Settings.suggestionMode, .sentences)

            store.apiText.enabled = false
            XCTAssertNotNil(store.pendingDownload)
            XCTAssertTrue(store.apiText.enabled)
            XCTAssertTrue(Settings.apiText.enabled)
            store.pendingDownload?.commit()
            XCTAssertFalse(Settings.apiText.enabled)
            store.pendingDownload = nil
            store.sync()
            XCTAssertFalse(store.apiText.enabled)
        }
    }

    // "Better models for <language>" in the status menu writes the stored flag
    // and relies on the window's `sync()` to pick it up: a store that kept its
    // own copy reopened the Model tab on the map instead of the ranked list.
    @MainActor
    func testSyncRereadsTheModelsView() {
        let saved = Settings.modelsAsMap
        defer { Settings.modelsAsMap = saved }
        Settings.modelsAsMap = true
        let store = SettingsStore(controller: nil)
        XCTAssertTrue(store.modelsAsMap)
        Settings.modelsAsMap = false
        store.sync()
        XCTAssertFalse(store.modelsAsMap)
    }

    // A wrong answer here nags every user toward a downgrade, so pin the compare.
    @MainActor
    func testUpdateVersionCompare() {
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "0.9.9"))
        // The reason this isn't a string compare.
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.1"))
        XCTAssertFalse(UpdateChecker.isNewer("0.9.1", than: "0.10.0"))
        // Equal, older, and shorter/longer forms of the same version.
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0"))
        // A pre-release never outranks the final tag of the same version.
        XCTAssertFalse(UpdateChecker.isNewer("0.2.0-beta", than: "0.2.0"))
        // …including one with a dotted suffix, which once read as 0.2.0.1.
        XCTAssertFalse(UpdateChecker.isNewer("0.2.0-beta.1", than: "0.2.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.3.0-beta.1", than: "0.2.0"))
        // Garbage must not read as newer.
        XCTAssertFalse(UpdateChecker.isNewer("", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("nightly", than: "0.1.0"))
    }

    // The login item's truth lives in launchd; held-by-macOS is the one state
    // that needs its own explanation.
    func testLoginItemHeldStateIsExplained() {
        XCTAssertNotNil(LoginItem.note(.requiresApproval))
    }

    // Finder hides ".app" or not; only that suffix is ours to drop.
    func testAppNamesKeepTheirOwnDots() {
        XCTAssertEqual(InstalledApps.droppingAppSuffix("Safari.app"), "Safari")
        XCTAssertEqual(InstalledApps.droppingAppSuffix("Safari"), "Safari")
        XCTAssertEqual(InstalledApps.droppingAppSuffix("Battle.net"), "Battle.net")
        XCTAssertEqual(InstalledApps.droppingAppSuffix("draw.io.app"), "draw.io")
    }
}
