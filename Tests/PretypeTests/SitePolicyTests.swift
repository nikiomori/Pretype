import XCTest
@testable import Pretype

final class SitePolicyTests: XCTestCase {
    func testSiteEntriesMatchTheirSubdomainsOnly() {
        XCTAssertTrue(AppPolicy.site("mail.google.com", matches: "site:google.com"))
        XCTAssertTrue(AppPolicy.site("google.com", matches: "site:google.com"))
        XCTAssertFalse(AppPolicy.site("docs.google.com", matches: "site:mail.google.com"))
        XCTAssertFalse(AppPolicy.site("notgoogle.com", matches: "site:google.com"))
        XCTAssertFalse(AppPolicy.site("mail.google.com", matches: "com.google.chrome"),
                       "an app entry is never a site entry")
    }

    @MainActor func testTypedAddressesNormalizeToAHost() {
        XCTAssertEqual(SettingsStore.host(fromTyped: "https://www.Mail.Google.com/inbox?x=1"), "mail.google.com")
        XCTAssertEqual(SettingsStore.host(fromTyped: "  slack.com "), "slack.com")
        XCTAssertNil(SettingsStore.host(fromTyped: "localhost"))
        XCTAssertNil(SettingsStore.host(fromTyped: ""))
    }

    func testSiteInstructionsWinOverTheBrowsersAndTheMostSpecificSiteWins() {
        let saved = Settings.perAppInstructions
        defer { Settings.perAppInstructions = saved }
        Settings.perAppInstructions = [
            "com.google.chrome": "browser voice",
            "site:google.com": "google voice",
            "site:mail.google.com": "gmail voice",
        ]
        XCTAssertEqual(Settings.perAppInstructions(for: "com.google.Chrome", site: "mail.google.com"), "gmail voice")
        XCTAssertEqual(Settings.perAppInstructions(for: "com.google.Chrome", site: "docs.google.com"), "google voice")
        XCTAssertEqual(Settings.perAppInstructions(for: "com.google.Chrome", site: "github.com"), "browser voice")
        XCTAssertEqual(Settings.perAppInstructions(for: "com.google.Chrome", site: nil), "browser voice")
    }
}
