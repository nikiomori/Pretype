import AppKit
import ApplicationServices
@testable import Pretype

/// An accessibility tree of the test's own, read through `AXText.calls`:
/// attribute values per element, errors where a read fails, and ranged reads
/// answered by closures. Every element is new to the process, so `AXText`'s
/// per-element caches never carry one test's answer into another.
final class FakeAXTree: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AXUIElement: [String: CFTypeRef]] = [:]
    private var errors: [AXUIElement: [String: AXError]] = [:]
    private var ranged: [AXUIElement: [String: (CFTypeRef) -> Any?]] = [:]
    private var bundleIDs: [AXUIElement: String] = [:]
    private var asked: [AXUIElement: [String: Int]] = [:]
    private var secure = false
    private var source: (type: String, modeID: String?)?
    private static let lastID = LockedValue(Int32(0))

    /// A handle no real AX call reaches, unique in the process.
    static func newElement() -> AXUIElement {
        AXUIElementCreateApplication(Self.lastID.withLock { id in
            id += 1
            return 80_000 + id
        })
    }

    var secureInput: Bool {
        get { lock.withLock { secure } }
        set { lock.withLock { secure = newValue } }
    }

    var inputSource: (type: String, modeID: String?)? {
        get { lock.withLock { source } }
        set { lock.withLock { source = newValue } }
    }

    /// An attribute's value: rects, points, sizes and ranges become `AXValue`s.
    func set(_ element: AXUIElement, _ attribute: String, _ value: Any?) {
        lock.withLock { values[element, default: [:]][attribute] = value.map(Self.ref) }
    }

    func fail(_ element: AXUIElement, _ attribute: String, _ error: AXError) {
        lock.withLock { errors[element, default: [:]][attribute] = error }
    }

    /// A parameterized attribute, answered for the range asked about.
    func answer(_ element: AXUIElement, _ attribute: String, _ read: @escaping (CFRange) -> Any?) {
        lock.withLock {
            ranged[element, default: [:]][attribute] = { parameter in
                var range = CFRange()
                guard CFGetTypeID(parameter) == AXValueGetTypeID(),
                      AXValueGetValue(parameter as! AXValue, .cfRange, &range) else { return nil }
                return read(range)
            }
        }
    }

    /// A parameterized attribute taking an opaque parameter (a text marker).
    func answerMarker(_ element: AXUIElement, _ attribute: String, _ read: @escaping (CFTypeRef) -> Any?) {
        lock.withLock { ranged[element, default: [:]][attribute] = read }
    }

    /// How often `attribute` of `element` was read.
    func reads(_ element: AXUIElement, _ attribute: String) -> Int {
        lock.withLock { asked[element]?[attribute] ?? 0 }
    }

    func belongs(_ element: AXUIElement, to bundleID: String) {
        lock.withLock { bundleIDs[element] = bundleID }
    }

    var calls: AXText.Calls {
        AXText.Calls(
            copy: { [self] element, attribute in
                lock.withLock {
                    asked[element, default: [:]][attribute, default: 0] += 1
                    if let error = errors[element]?[attribute] { return (error, nil) }
                    guard let value = values[element]?[attribute] else { return (.attributeUnsupported, nil) }
                    return (.success, value)
                }
            },
            copyParameterized: { [self] element, attribute, parameter in
                let read = lock.withLock { ranged[element]?[attribute] }
                return read?(parameter).map(Self.ref)
            },
            bundleID: { [self] element in lock.withLock { bundleIDs[element] } },
            secureInput: { [self] in secureInput },
            inputSource: { [self] in inputSource })
    }

    /// Run `body` reading this tree.
    func reading<T>(_ body: () throws -> T) rethrows -> T {
        try AXText.$calls.withValue(calls, operation: body)
    }

    static func ref(_ value: Any) -> CFTypeRef {
        switch value {
        case var rect as CGRect: return AXValueCreate(.cgRect, &rect)!
        case var point as CGPoint: return AXValueCreate(.cgPoint, &point)!
        case var size as CGSize: return AXValueCreate(.cgSize, &size)!
        case var range as CFRange: return AXValueCreate(.cfRange, &range)!
        default: return value as AnyObject
        }
    }

    // MARK: - A text field

    /// A text field holding `text` with a collapsed caret at `caret` (UTF-16;
    /// the end when nil) in `frame` (AX coordinates: top-left origin). A
    /// native field answers string and bounds reads: glyphs 8 pt wide from
    /// the field's left edge, the caret a hairline before glyph `caret`. A
    /// web field (`native: false`) answers no bounds — its geometry is the
    /// garbage the fallback exists for.
    @discardableResult
    func field(_ text: String, caret: Int? = nil, frame: CGRect = FakeAXTree.frame,
               role: String = "AXTextArea", native: Bool = true) -> AXUIElement {
        let element = Self.newElement()
        let ns = text as NSString
        set(element, kAXRoleAttribute, role)
        set(element, kAXValueAttribute, text)
        set(element, kAXNumberOfCharactersAttribute, ns.length)
        set(element, kAXSelectedTextRangeAttribute, CFRange(location: caret ?? ns.length, length: 0))
        set(element, kAXPositionAttribute, frame.origin)
        set(element, kAXSizeAttribute, frame.size)
        answer(element, kAXStringForRangeParameterizedAttribute) { range in
            let from = max(0, min(range.location, ns.length))
            return ns.substring(with: NSRange(location: from, length: max(0, min(range.length, ns.length - from))))
        }
        if native {
            answer(element, kAXBoundsForRangeParameterizedAttribute) { range in
                range.location < 0 ? nil : Self.glyphs(in: frame, from: range.location, count: range.length)
            }
        }
        return element
    }

    static let frame = CGRect(x: 100, y: 100, width: 400, height: 60)

    /// Where a native field draws `count` glyphs from `location`: 8 pt each
    /// on the field's first line, forty to a line's width and then over the
    /// same spot again (one line is all a caret needs); a hairline caret for
    /// none.
    static func glyphs(in frame: CGRect, from location: Int, count: Int) -> CGRect {
        CGRect(x: frame.minX + 8 * CGFloat(location % 40), y: frame.minY + 4,
               width: count == 0 ? 1 : 8 * CGFloat(count), height: 16)
    }
}
