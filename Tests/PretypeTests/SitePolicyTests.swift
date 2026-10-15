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

    func testDictationSendTogglesTheSiteInABrowserAndTheAppElsewhere() {
        let saved = Settings.dictationSendApps
        defer { Settings.dictationSendApps = saved }
        Settings.dictationSendApps = []
        let slack = TypingContext(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        let chat = TypingContext(appName: "Chrome", bundleID: "com.google.Chrome", site: "chatgpt.com")
        let docs = TypingContext(appName: "Chrome", bundleID: "com.google.Chrome", site: "docs.google.com")

        AppPolicy.toggleDictationSend(slack)
        AppPolicy.toggleDictationSend(chat)
        XCTAssertEqual(Settings.dictationSendApps, ["com.tinyspeck.slackmacgap", "site:chatgpt.com"])
        XCTAssertTrue(AppPolicy.sendsAfterDictation(slack))
        XCTAssertTrue(AppPolicy.sendsAfterDictation(chat))
        XCTAssertFalse(AppPolicy.sendsAfterDictation(docs), "one website on, not the whole browser")

        AppPolicy.toggleDictationSend(slack)
        XCTAssertFalse(AppPolicy.sendsAfterDictation(slack))
        XCTAssertFalse(AppPolicy.sendsAfterDictation(TypingContext()), "no app, nothing to match")
    }

    func testChatsAreMessengersNotAIChatsOrMail() {
        XCTAssertTrue(AppPolicy.isChat(TypingContext(bundleID: "ru.keepcoder.Telegram")))
        XCTAssertTrue(AppPolicy.isChat(TypingContext(bundleID: "com.apple.MobileSMS")))
        XCTAssertTrue(AppPolicy.isChat(TypingContext(bundleID: "com.google.Chrome", site: "web.whatsapp.com")))
        XCTAssertFalse(AppPolicy.isChat(TypingContext(bundleID: "com.google.Chrome", site: "chatgpt.com")))
        XCTAssertFalse(AppPolicy.isChat(TypingContext(bundleID: "com.apple.mail")))
        XCTAssertFalse(AppPolicy.isChat(TypingContext(bundleID: "com.tinyspeck.slackmacgap", site: "github.com")),
                       "a web page inside an app is judged by its site")
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

    func testAppPolicyBlacklist() {
        // Save current blacklist
        let originalBlacklist = Settings.userBlacklist
        defer { Settings.userBlacklist = originalBlacklist }

        // Test terminal is blacklisted by default
        XCTAssertTrue(AppPolicy.isBlacklisted("com.apple.Terminal"))
        XCTAssertTrue(AppPolicy.isBlacklisted("com.googlecode.iterm2"))

        // Test normal app is NOT blacklisted by default
        XCTAssertFalse(AppPolicy.isBlacklisted("com.apple.mail"))

        // Add to blacklist
        Settings.userBlacklist = ["mail", "slack"]
        XCTAssertTrue(AppPolicy.isBlacklisted("com.apple.mail"))
        XCTAssertTrue(AppPolicy.isBlacklisted("com.tinyspeck.slackmacgap"))
        
        // Allows screen context should be false for blacklisted apps
        XCTAssertFalse(AppPolicy.allowsScreenContext(TypingContext(bundleID: "com.apple.mail")))
    }

    // The user blacklist holds lowercased *substring markers*, not exact bundle
    // IDs, so "enable here again" has to remove whichever entry matched — an
    // exact-ID remove would leave the menu item visibly stuck on "Enable in …".
    func testToggleUserBlacklist() {
        let original = Settings.userBlacklist   // shared with the developer's real app
        defer { Settings.userBlacklist = original }

        // Off → on stores the exact ID, lowercased.
        Settings.userBlacklist = []
        AppPolicy.toggleUserBlacklist("com.apple.Mail")
        XCTAssertEqual(Settings.userBlacklist, ["com.apple.mail"])
        XCTAssertTrue(AppPolicy.isBlacklisted("com.apple.Mail"))

        // On → off removes it again.
        AppPolicy.toggleUserBlacklist("com.apple.Mail")
        XCTAssertEqual(Settings.userBlacklist, [])
        XCTAssertFalse(AppPolicy.isBlacklisted("com.apple.Mail"))

        // A hand-typed fragment must be removed by the toggle, not shadowed by
        // an exact ID appended beside it (which would leave the app silenced).
        Settings.userBlacklist = ["mail", "slack"]
        XCTAssertEqual(AppPolicy.userBlacklistEntries(for: "com.apple.Mail"), ["mail"])
        AppPolicy.toggleUserBlacklist("com.apple.Mail")
        XCTAssertEqual(Settings.userBlacklist, ["slack"])
        XCTAssertFalse(AppPolicy.isBlacklisted("com.apple.Mail"))

        // Built-in blocks are not user entries: nothing to toggle, still blocked.
        Settings.userBlacklist = []
        XCTAssertTrue(AppPolicy.userBlacklistEntries(for: "com.apple.Terminal").isEmpty)
        XCTAssertTrue(AppPolicy.isBlacklisted("com.apple.Terminal"))
    }
}
