import XCTest
@testable import Pretype

final class SettingsTests: XCTestCase {
    /// `@Pref` stores an enum as its raw string — what `@AppStorage` reads
    /// back — and answers an unset key with the declared default. Strengths
    /// stored before personalization became on/off all read as on.
    func testPrefStoresRawValuesAndDefaults() {
        let defaults = UserDefaults.standard
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

    // The login item's truth lives in launchd, so the only thing to pin is the
    // mapping: only .enabled is "on" — .requiresApproval is registered but held
    // by macOS, and a switch that shows it as on would be lying.
    func testLoginItemStatusMapping() {
        XCTAssertTrue(LoginItem.isOn(.enabled))
        XCTAssertFalse(LoginItem.isOn(.requiresApproval))
        XCTAssertFalse(LoginItem.isOn(.notRegistered))
        XCTAssertFalse(LoginItem.isOn(.notFound))
        // Held-by-macOS is the one state that needs its own explanation.
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
