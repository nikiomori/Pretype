import SwiftUI
import XCTest
@testable import Pretype

final class StatusMenuTests: XCTestCase {
    // Going quiet in an app is self-inflicted and one-way (it stops the very
    // counter that could lift it), so the threshold, the decay and the Resume
    // path all have to behave exactly as the menu claims they do.
    @MainActor
    func testUnproductiveAppRecord() {
        let app = "test.pretype.unproductive"     // shared defaults with the real app
        defer { Stats.clearRecord(for: app) }
        Stats.clearRecord(for: app)

        // No record, and a thin one, say nothing: a handful of ignored
        // suggestions is not a verdict.
        XCTAssertNil(Stats.record(for: app))
        XCTAssertFalse(Stats.isUnproductive(app))
        for _ in 0 ..< (Stats.appVerdictMinShown - 1) { Stats.recordShown(app: app) }
        XCTAssertFalse(Stats.isUnproductive(app))

        // One more crosses the sample bar with nothing taken.
        Stats.recordShown(app: app)
        XCTAssertEqual(Stats.record(for: app)?.shown, Stats.appVerdictMinShown)
        XCTAssertTrue(Stats.isUnproductive(app))

        // Accepts pull it back over the rate floor — and a word-by-word accept
        // counts once, like the daily counters.
        for _ in 0 ..< 5 {
            Stats.recordAccepted(chunk: "hello", app: app)
            Stats.recordAccepted(chunk: " there", countSuggestion: false, app: app)
        }
        XCTAssertEqual(Stats.record(for: app)?.accepted, 5)
        XCTAssertFalse(Stats.isUnproductive(app))

        // Both counts halve at the decay point, so the rate survives but the
        // sample stays bounded.
        while (Stats.record(for: app)?.shown ?? 0) < Stats.appDecayAt - 1 { Stats.recordShown(app: app) }
        let before = Stats.record(for: app)!
        Stats.recordShown(app: app)
        let after = Stats.record(for: app)!
        XCTAssertEqual(after.shown, Stats.appDecayAt / 2)
        XCTAssertEqual(after.accepted, before.accepted / 2)

        // Resume wipes it: the app starts earning its verdict again from zero.
        Stats.clearRecord(for: app)
        XCTAssertNil(Stats.record(for: app))
        XCTAssertFalse(Stats.isUnproductive(app))
    }

    // The denominator behind BOTH the acceptance figure and the go-quiet verdict.
    // Booking every ghost at draw time counted offers the typing itself outran —
    // a week of real journal read 1.7% taken in every app, which is under the
    // quiet floor, i.e. the app was on course to silence itself everywhere.
    @MainActor
    func testOfferCountsOnlyRealChances() {
        func chance(_ outcome: SuggestionJournal.Outcome, _ ms: Int, took: Bool = false) -> Bool {
            Stats.isChance(outcome: outcome, shownForMs: ms, tookAny: took)
        }
        // Replaced by the next generation, or typed out by the user unaided:
        // never a rejection, however long it stood.
        XCTAssertFalse(chance(.superseded, 5_000))
        XCTAssertFalse(chance(.typedThrough, 5_000))
        // Gone before it could be read vs. stood long enough to ignore.
        XCTAssertFalse(chance(.diverged, Stats.offerNoticeMs - 1))
        XCTAssertTrue(chance(.diverged, Stats.offerNoticeMs))
        XCTAssertFalse(chance(.abandoned, 0))
        XCTAssertTrue(chance(.abandoned, 1_200))
        // ⎋ is a deliberate no, however fast it lands.
        XCTAssertTrue(chance(.dismissed, 10))
        // Anything taken always counts, whole or word-by-word — otherwise a
        // partial accept could book `accepted` with no `shown` behind it, and
        // the menu would show more than 100% taken.
        XCTAssertTrue(chance(.accepted, 10))
        XCTAssertTrue(chance(.diverged, 10, took: true))
        XCTAssertTrue(chance(.superseded, 10, took: true))

        // And the booking itself follows the rule, per app.
        let app = "test.pretype.chances"
        defer { Stats.clearRecord(for: app) }
        Stats.clearRecord(for: app)
        Stats.recordOffer(outcome: .superseded, shownForMs: 220, tookAny: false, app: app)
        Stats.recordOffer(outcome: .diverged, shownForMs: 100, tookAny: false, app: app)
        XCTAssertNil(Stats.record(for: app))
        Stats.recordOffer(outcome: .diverged, shownForMs: 900, tookAny: false, app: app)
        XCTAssertEqual(Stats.record(for: app)?.shown, 1)
    }

    // The menu now sells a time figure, so the keystrokes behind it have to be
    // net of the accept press — counting that press as a saving would inflate
    // every number the user is shown.
    @MainActor
    func testNetKeystrokesSaved() {
        let todayBefore = Stats.netSavedToday, totalBefore = Stats.netSavedTotal

        // A one-shot accept costs one key: 5 chars in, 4 net.
        Stats.recordAccepted(chunk: "hello")
        XCTAssertEqual(Stats.netSavedToday, todayBefore + 4)
        XCTAssertEqual(Stats.netSavedTotal, totalBefore + 4)

        // Continuing the same suggestion word-by-word is another press, so the
        // second chunk pays for itself too.
        Stats.recordAccepted(chunk: " there", countSuggestion: false)
        XCTAssertEqual(Stats.netSavedToday, todayBefore + 10)

        // And the header reads time, over a week that ends with today.
        let savings = Stats.savings
        XCTAssertFalse(savings.isEmpty)
        XCTAssertEqual(savings.week.count, 7)
        XCTAssertEqual(savings.week.last, Stats.netSavedToday)
        XCTAssertTrue(["min", "h"].contains(savings.todayFigure.unit), savings.todayFigure.unit)
    }

    // The day key is data, not display: Gregorian years and ASCII digits in any
    // region (a Thai one wrote "2569-…", an Arabic one native digits). Noon UTC
    // is Oct 16 or 17 in every time zone.
    func testDayKeyIsGregorianASCII() {
        let key = Stats.dayKey(Date(timeIntervalSince1970: 1_792_152_000))
        XCTAssertTrue(["2026-10-16", "2026-10-17"].contains(key), key)
    }

    // NSMenu lays a custom-view item out at the view's own frame, so a hosting
    // view left at its zero starting frame renders as a blank sliver — which is
    // exactly how the drawn header and footer first shipped. Pin both the
    // fitting size and the menu height that depends on it.
    @MainActor
    func testMenuHostingViewsReportTheirSize() {
        let savings = Stats.Savings(
            todayKeystrokes: 1900, totalKeystrokes: 164_000,
            week: [1200, 2400, 800, 1500, 3100, 2600, 1900],
            todayFigure: ("10", "min"), todayText: "10 min", totalText: "13 h 40 min"
        )
        let header = NSHostingView(rootView: MenuHeaderView(
            statusColor: .green, statusText: "MiniCPM5-1B-Base: ready",
            statusOK: true, savings: savings, invitation: "Press Tab on a suggestion to start saving typing time."
        ))
        let hints = NSHostingView(rootView: MenuHintsView(hints: [
            .init(keys: ["Tab"], action: "accept a word — ⇧Tab for all"),
            .init(keys: ["⌥Tab"], action: "fix the word or selection"),
        ]))

        let menu = NSMenu()
        for host in [header as NSView, hints as NSView] {
            (host as? NSHostingView<MenuHeaderView>)?.sizingOptions = .intrinsicContentSize
            (host as? NSHostingView<MenuHintsView>)?.sizingOptions = .intrinsicContentSize
            host.layoutSubtreeIfNeeded()
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            XCTAssertEqual(host.frame.width, MenuHeaderView.width, accuracy: 0.5)
            XCTAssertGreaterThan(host.frame.height, 20, "\(type(of: host)) collapsed")
            let item = NSMenuItem()
            item.view = host
            menu.addItem(item)
        }
        XCTAssertGreaterThanOrEqual(menu.size.height, header.frame.height + hints.frame.height)
    }

    /// `legible` keeps every metric tint readable as caption text — the menu's
    /// gain figure, the Settings cards, badges and map stats: 4.5:1 or better on
    /// the grouped form's card fill in both appearances (HIG › Accessibility).
    func testLegibleTintsClearTextContrast() {
        func luminance(_ c: NSColor) -> Double {
            func lin(_ v: CGFloat) -> Double {
                let v = Double(v)
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
        }
        // The card fills sampled from the Settings window: #f1f1f1 and #2d2d2d.
        let fills: [(NSAppearance.Name, Double)] = [(.aqua, 241.0 / 255), (.darkAqua, 45.0 / 255)]
        for (name, gray) in fills {
            let fill = luminance(NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
            for tint in [Color.green, .teal, .orange, .pink, .blue, .purple] {
                var ink = NSColor.black
                NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                    ink = NSColor(tint.legible).usingColorSpace(.sRGB) ?? ink
                }
                let text = luminance(ink)
                let ratio = (max(text, fill) + 0.05) / (min(text, fill) + 0.05)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(tint) in \(name.rawValue): \(ratio)")
            }
        }
    }
}
