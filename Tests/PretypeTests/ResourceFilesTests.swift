import XCTest
@testable import Pretype

final class ResourceFilesTests: XCTestCase {
    // A translation is formatted with the code's own arguments: a specifier
    // dropped, added or retyped in the catalog garbles or crashes that line in
    // one language only, where nobody looks by hand. Also: no key the code
    // knows (as of the last Scripts/sync-strings.py) ships untranslated.
    func testStringCatalogTranslations() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Localization/Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try XCTUnwrap(catalog?["strings"] as? [String: [String: Any]])
        let spec = try NSRegularExpression(pattern: "%(?:(\\d+)\\$)?(lld|ld|lf|@|d|f|%)")
        func arguments(_ text: String) -> [Int: String] {
            let ns = text as NSString
            var out: [Int: String] = [:]
            var next = 0
            for match in spec.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let kind = ns.substring(with: match.range(at: 2))
                guard kind != "%" else { continue }
                next += 1
                let position = match.range(at: 1).location == NSNotFound
                    ? next : Int(ns.substring(with: match.range(at: 1))) ?? next
                out[position] = kind
            }
            return out
        }
        XCTAssertGreaterThan(strings.count, 500)
        // Every language the catalog has, on every key: a half-translated
        // language shows English mid-sentence.
        let languages = Set(strings.values.flatMap { ($0["localizations"] as? [String: Any] ?? [:]).keys })
            .subtracting(["en"])  // the source; it carries only English plural forms
        XCTAssertTrue(languages.contains("ru"))
        for (key, entry) in strings where entry["extractionState"] as? String != "stale" {
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            for (language, localization) in localizations {
                var values = [(localization["stringUnit"] as? [String: Any])?["value"] as? String]
                let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]]
                values += (plural ?? [:]).values.map { ($0["stringUnit"] as? [String: Any])?["value"] as? String }
                for value in values.compactMap({ $0 }) {
                    XCTAssertEqual(arguments(value), arguments(key), "\(language): \(key) ⇒ \(value)")
                }
            }
            if entry["shouldTranslate"] as? Bool != false {
                for language in languages {
                    XCTAssertNotNil(localizations[language], "untranslated in \(language): \(key)")
                }
            }
        }
    }

    // AppStyles/ takes pull requests from people who never touch the Swift
    // code, so this is their review: CI fails a file the app would mis-key,
    // silently skip, or that would bloat every prompt it rides in.
    func testCommunityAppStyles() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AppStyles")
        let manager = FileManager.default
        XCTAssertEqual(Set(try manager.contentsOfDirectory(atPath: root.path)), ["README.md", "apps", "sites"])
        let name = try NSRegularExpression(pattern: "^[a-z0-9-]+(\\.[a-z0-9-]+)+\\.txt$")
        var files = 0
        for folder in ["apps", "sites"] {
            for file in try manager.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path) {
                files += 1
                let path = "AppStyles/\(folder)/\(file)"
                XCTAssertNotNil(name.firstMatch(in: file, range: NSRange(file.startIndex..., in: file)),
                                "\(path): name it <bundle id>.txt / <host>.txt, lowercase")
                XCTAssertFalse(folder == "sites" && file.hasPrefix("www."), "\(path): drop the www.")
                let contents = try String(contentsOf: root.appendingPathComponent("\(folder)/\(file)"), encoding: .utf8)
                let text = try XCTUnwrap(PerAppPresets.styleText(contents), "\(path): no style text")
                XCTAssertLessThanOrEqual(text.count, 400, "\(path): keep it under 400 characters")
            }
        }
        let styles = PerAppPresets.load(from: root)
        XCTAssertEqual(styles.count, files)
        XCTAssertNotNil(styles["site:github.com"])
        // Apps without a file borrow one of their kind — that file must exist.
        for kind in PerAppPresets.kinds {
            XCTAssertNotNil(styles[kind.key], "AppStyles/apps/\(kind.key).txt stands in for its kind")
        }
        // Exact IDs, case-insensitively; then the kind; unknown starts blank.
        let mail = styles["com.apple.mail"]
        XCTAssertEqual(PerAppPresets.template(for: "com.apple.MAIL", in: styles), mail)
        XCTAssertEqual(PerAppPresets.template(for: "ru.keepcoder.Telegram", in: styles), styles["ru.keepcoder.telegram"])
        XCTAssertEqual(PerAppPresets.template(for: "com.airmailapp.airmail-email", in: styles), mail)
        XCTAssertEqual(PerAppPresets.template(for: "com.lukilabs.craft-notes", in: styles), styles["com.apple.notes"])
        XCTAssertNil(PerAppPresets.template(for: "com.example.mystery", in: styles))
        XCTAssertNil(PerAppPresets.template(for: "site:example.com", in: styles))

        XCTAssertEqual(PerAppPresets.styleText("# Slack\n# by @someone\n\nShort and direct.\n"), "Short and direct.")
        XCTAssertNil(PerAppPresets.styleText("# just a comment\n"))

        // The share link carries the file intact — "&", "+" and "#" included.
        let text = "Short & direct, C++ ok. #1 rule: no emoji."
        let url = try XCTUnwrap(PerAppPresets.shareURL(key: "com.tinyspeck.slackmacgap", name: "Slack", text: text))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "filename" }?.value, "AppStyles/apps/com.tinyspeck.slackmacgap.txt")
        XCTAssertEqual(query.first { $0.name == "value" }?.value, "# Slack\n\(text)\n")
        let site = try XCTUnwrap(PerAppPresets.shareURL(key: "site:mail.google.com", name: "mail.google.com", text: "x"))
        XCTAssertTrue(site.absoluteString.contains("filename=AppStyles/sites/mail.google.com.txt"))
    }
}
