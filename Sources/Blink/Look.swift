import AppKit

// ═══════════════════════════════════════════════════════════════════════════
//  Blink — the look. "Instrument": matte paper, black ink, one orange.
//  See DESIGN.md. Nothing here moves, glows, blurs or has a gradient.
// ═══════════════════════════════════════════════════════════════════════════

// MARK: - Palette & type
enum Theme {
    static func c(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    /// Follows the system. `update()` is called each time the panel opens.
    static var isDark = false
    static func update() { isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    private static func pick(_ light: UInt32, _ dark: UInt32) -> NSColor { c(isDark ? dark : light) }

    // light = warm paper & black ink · dark = the same object at night: charcoal body, paper-coloured ink.
    // Selected rows invert (bar = ink, text = paper), so swapping paper/ink inverts them for free.
    static var paper: NSColor      { pick(0xECE9E2, 0x1C1C1B) }     // the body
    static var ink: NSColor        { pick(0x1A1A19, 0xECE9E2) }     // text, selected row
    static var muted: NSColor      { pick(0x5F5C56, 0xA8A49B) }     // secondary text
    static var hair: NSColor       { pick(0xCBC7BD, 0x3A3936) }     // 1 px rules
    static var recess: NSColor     { pick(0xDED9CE, 0x121211) }     // the LCD well
    static var keyFill: NSColor    { pick(0xDCD8CE, 0x2B2B29) }
    static var keyEdge: NSColor    { pick(0xBDB8AD, 0x484641) }
    static var lcdOff: NSColor     { pick(0xCDC9BE, 0x252523) }     // unlit dots
    static var onInkMuted: NSColor { pick(0xBDBAB2, 0x5A574F) }     // secondary text on the selected bar
    static var onInkKey: NSColor   { pick(0x34332F, 0xD6D2C8) }
    static var onInkEdge: NSColor  { pick(0x4A4944, 0xB5B0A5) }
    /// The only colour. It always means: *this is where your input is acting*
    /// (the caret, the letters you matched, what Enter will do).
    static let accent = c(0xFF5A1F)
    static var accentSoft: NSColor { pick(0xFF8A5C, 0xC93A07) }     // accent as text on the selected bar
    static var accentText: NSColor { pick(0xC93A07, 0xFF6A33) }     // accent as text on the body (plain accent is 2.6:1 on paper)

    static var text: NSColor { ink }

    /// Helvetica Neue for what people read and type (Akzidenz lineage, the Braun voice) …
    static func sans(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let face: String
        switch weight {
        case .ultraLight: face = "HelveticaNeue-UltraLight"
        case .thin: face = "HelveticaNeue-Thin"
        case .light: face = "HelveticaNeue-Light"
        case .medium: face = "HelveticaNeue-Medium"
        case .semibold, .bold, .heavy, .black: face = "HelveticaNeue-Bold"
        default: face = "HelveticaNeue"
        }
        return NSFont(name: face, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
    /// … and SF Mono for what a machine wrote: paths, tags, keys, code.
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont { .monospacedSystemFont(ofSize: size, weight: weight) }
}

// MARK: - Icon alphabet
/// Original line icons on a 20-unit grid. Machined, not friendly: butt caps, mitred joins, no curves except circles.
/// Solid = something you can launch (project), outline = something passive. Apps keep their real icons.
enum Glyph {
    private struct Part { let path: NSBezierPath; let fill: Bool }

    private static func poly(_ pts: [(CGFloat, CGFloat)], close: Bool = false) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
        for q in pts.dropFirst() { p.line(to: NSPoint(x: q.0, y: q.1)) }
        if close { p.close() }
        return p
    }
    private static func line(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> NSBezierPath { poly([(a, b), (c, d)]) }
    private static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
    private static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSBezierPath { NSBezierPath(rect: NSRect(x: x, y: y, width: w, height: h)) }

    private static func page(_ marks: [Part]) -> [Part] {
        [Part(path: poly([(4.5, 2), (15.5, 2), (15.5, 13.5), (11, 18), (4.5, 18)], close: true), fill: false)] + marks
    }
    private static func s(_ p: NSBezierPath) -> Part { Part(path: p, fill: false) }
    private static func f(_ p: NSBezierPath) -> Part { Part(path: p, fill: true) }

    private static let folder = poly([(2.5, 4), (17.5, 4), (17.5, 12), (15, 14.5), (9.8, 14.5), (8.2, 16.5), (2.5, 16.5)], close: true)

    private static let shapes: [String: [Part]] = {
        var m: [String: [Part]] = [:]
        m["dir"] = [s(folder)]
        m["pro"] = [f(folder)]
        m["fil"] = page([])
        m["doc"] = page([s(line(7, 10, 13, 10)), s(line(7, 7.2, 13, 7.2)), s(line(7, 4.4, 10.5, 4.4))])
        m["pdf"] = page([s(line(7, 10, 13, 10)), f(rect(7, 4.4, 6, 2.4))])
        m["xls"] = page([s(line(7, 9.5, 13, 9.5)), s(line(7, 6.5, 13, 6.5)), s(line(10, 4.5, 10, 12))])
        m["ppt"] = page([s(rect(6.8, 6.2, 6.4, 4.6)), s(line(8.5, 4, 11.5, 4))])
        m["src"] = page([s(poly([(8.4, 11), (6.2, 8.5), (8.4, 6)])), s(poly([(11.6, 11), (13.8, 8.5), (11.6, 6)]))])
        m["zip"] = page([s(line(8, 16.5, 8, 14.5)), s(line(8, 12.5, 8, 10.5)), s(rect(6.6, 4.6, 2.8, 4.2))])
        m["img"] = page([s(poly([(6.4, 5), (9.2, 8.8), (11, 6.8), (13.4, 9.8)])), f(circle(8, 11.8, 1.2))])
        m["vid"] = page([s(poly([(8.5, 5.6), (12.8, 8.6), (8.5, 11.6)], close: true))])
        m["aud"] = page([s(line(6.6, 7.4, 6.6, 9.6)), s(line(8.3, 6, 8.3, 11)), s(line(10, 4.8, 10, 12.2)), s(line(11.7, 6.2, 11.7, 10.8)), s(line(13.4, 7.6, 13.4, 9.4))])
        m["cal"] = [s(line(4.5, 7.4, 15.5, 7.4)), s(line(4.5, 12.6, 15.5, 12.6))]
        m["cnv"] = [s(line(4, 12.5, 16, 12.5)), s(poly([(13, 15.5), (16, 12.5), (13, 9.5)])), s(line(16, 7.5, 4, 7.5)), s(poly([(7, 10.5), (4, 7.5), (7, 4.5)]))]
        // settings
        m["kbd"] = [s(rect(3, 5, 14, 10)), s(line(6.5, 8, 13.5, 8)), f(circle(6.5, 12, 0.9)), f(circle(10, 12, 0.9)), f(circle(13.5, 12, 0.9))]
        m["code"] = [s(poly([(7, 13), (3.5, 10), (7, 7)])), s(poly([(13, 13), (16.5, 10), (13, 7)])), s(line(11.2, 15, 8.8, 5))]
        m["term"] = [s(rect(2.5, 4, 15, 12)), s(poly([(6, 12), (8.6, 10), (6, 8)])), s(line(10.5, 8, 14, 8))]
        let pw = NSBezierPath()
        pw.appendArc(withCenter: NSPoint(x: 10, y: 9.5), radius: 5.6, startAngle: 118, endAngle: 62, clockwise: false)
        m["power"] = [s(pw), s(line(10, 10.5, 10, 16.5))]
        m["lens"] = [s(circle(8.6, 11.4, 5.2)), s(line(12.4, 7.6, 16.6, 3.4))]
        return m
    }()

    static func draw(_ name: String, in box: NSRect, color: NSColor, lineWidth: CGFloat) {
        let parts = shapes[name] ?? shapes["fil"]!
        let sc = box.width / 20
        let t = NSAffineTransform()
        t.translateX(by: box.minX, yBy: box.minY)
        t.scaleX(by: sc, yBy: sc)
        color.set()
        for part in parts {
            let p = t.transform(part.path)
            if part.fill { p.fill() } else {
                p.lineWidth = lineWidth; p.lineCapStyle = .butt; p.lineJoinStyle = .miter; p.miterLimit = 4; p.stroke()
            }
        }
    }

    /// A small template-free image, for the menu bar and places that need an NSImage.
    static func image(_ name: String, size: CGFloat, color: NSColor, lineWidth: CGFloat) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size * 2), pixelsHigh: Int(size * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(name, in: NSRect(x: 0, y: 0, width: size, height: size), color: color, lineWidth: lineWidth)
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: size, height: size))
        img.addRepresentation(rep)
        return img
    }

    static func name(forTag tag: String) -> String {
        switch tag {
        case "DIR": return "dir"
        case "PRO": return "pro"
        case "IMG": return "img"
        case "VID": return "vid"
        case "AUD": return "aud"
        case "PDF": return "pdf"
        case "DOC": return "doc"
        case "XLS": return "xls"
        case "PPT": return "ppt"
        case "ZIP": return "zip"
        case "SRC": return "src"
        case "CAL": return "cal"
        case "CNV": return "cnv"
        default: return "fil"
        }
    }
}

/// A physical keycap carrying one glyph. Apps skip the cap and show their real icon.
final class KeyIcon: NSView {
    var glyph = "fil" { didSet { if glyph != oldValue { needsDisplay = true } } }
    var appImage: NSImage? { didSet { if appImage !== oldValue { needsDisplay = true } } }
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        if let img = appImage { img.draw(in: bounds); return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        (selected ? Theme.onInkKey : Theme.keyFill).setFill(); p.fill()
        (selected ? Theme.onInkEdge : Theme.keyEdge).setStroke(); p.lineWidth = 1; p.stroke()
        Glyph.draw(glyph, in: bounds.insetBy(dx: 4.5, dy: 4.5), color: selected ? Theme.paper : Theme.ink, lineWidth: 1.4)
    }
}

// MARK: - Dot-matrix display (the answer)
/// A 5 × 7 dot-matrix numeral set for the calculator's answer — the one place Blink is allowed to show off.
enum DotMatrix {
    static let glyphs: [Character: [String]] = [
        "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
        "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
        "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
        "3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
        "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
        "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
        "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
        "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
        "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
        "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
        ",": ["000", "000", "000", "000", "000", "010", "100"],
        ".": ["000", "000", "000", "000", "000", "000", "010"],
        "-": ["00000", "00000", "00000", "01110", "00000", "00000", "00000"],
        "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
        "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
        "C": ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
        "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
        "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
        "F": ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
        "G": ["01110", "10001", "10000", "10111", "10001", "10001", "01111"],
        "H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
        "I": ["01110", "00100", "00100", "00100", "00100", "00100", "01110"],
        "J": ["00111", "00010", "00010", "00010", "00010", "10010", "01100"],
        "K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
        "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
        "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
        "N": ["10001", "11001", "11001", "10101", "10011", "10011", "10001"],
        "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
        "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
        "Q": ["01110", "10001", "10001", "10001", "10101", "10010", "01101"],
        "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
        "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
        "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
        "U": ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
        "V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
        "W": ["10001", "10001", "10001", "10101", "10101", "11011", "10001"],
        "X": ["10001", "10001", "01010", "00100", "01010", "10001", "10001"],
        "Y": ["10001", "10001", "01010", "00100", "00100", "00100", "00100"],
        "Z": ["11111", "00001", "00010", "00100", "01000", "10000", "11111"],
    ]
    /// advance in dot cells
    static func advance(_ ch: Character) -> CGFloat { ch == "," || ch == "." ? 2.4 : (glyphs[ch] != nil ? 6.2 : 3) }
    static func supports(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { glyphs[$0] != nil } && s.contains { $0.isNumber } }

    /// Adds dots for one line of text; `top` is the upper edge. Returns nothing: fill `path` once at the end.
    static func add(_ text: String, to path: NSBezierPath, unlit: NSBezierPath? = nil, x x0: CGFloat, top: CGFloat, cell: CGFloat, radius r: CGFloat) {
        var x = x0
        for ch in text {
            guard let g = glyphs[ch] else { x += advance(ch) * cell; continue }
            for (j, row) in g.enumerated() {
                for (i, b) in row.enumerated() {
                    let o = NSRect(x: x + CGFloat(i) * cell + cell / 2 - r, y: top - CGFloat(j + 1) * cell + cell / 2 - r, width: 2 * r, height: 2 * r)
                    if b == "1" { path.appendOval(in: o) } else { unlit?.appendOval(in: o) }
                }
            }
            x += advance(ch) * cell
        }
    }
}

final class LCDView: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var label = "" { didSet { needsDisplay = true } }
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0, dy: 5)
        let well = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        Theme.recess.setFill(); well.fill()
        Theme.hair.setStroke(); well.lineWidth = 1; well.stroke()
        (Theme.isDark ? NSColor.white.withAlphaComponent(0.04) : NSColor.black.withAlphaComponent(0.06)).setFill()
        NSRect(x: box.minX + 3, y: box.maxY - 3, width: box.width - 6, height: 2).fill()      // the lip of the well

        // dots
        let units = text.reduce(CGFloat(0)) { $0 + DotMatrix.advance($1) }
        let avail = box.width - 40
        let cell = max(2.6, min(6.4, avail / max(units, 1)))
        let r = cell * 0.37
        let on = NSBezierPath(), off = NSBezierPath()
        DotMatrix.add(text, to: on, unlit: off, x: box.minX + 20, top: box.midY + 3.5 * cell + 6, cell: cell, radius: r)
        Theme.lcdOff.setFill(); off.fill()
        Theme.ink.setFill(); on.fill()

        // legends
        let l = NSAttributedString(string: label, attributes: [.font: Theme.mono(10, .regular), .foregroundColor: Theme.muted])
        l.draw(at: NSPoint(x: box.maxX - 16 - l.size().width, y: box.minY + 8))
        if selected { Theme.accent.setFill(); NSRect(x: box.minX + 12, y: box.minY, width: box.width - 24, height: 2).fill() }
    }
}

// MARK: - Panel body, rows, footer
/// The rule under the search bar is a measuring scale: a tick every 8 pt, a longer one every 40 pt.
final class RulerView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.hair.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        Theme.muted.withAlphaComponent(0.7).setFill()
        var x: CGFloat = 0, i = 0
        while x < bounds.width {
            NSRect(x: x, y: 1, width: 1, height: i % 5 == 0 ? 6 : 3).fill()
            x += 8; i += 1
        }
    }
}

final class PaperView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.paper.cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = Theme.hair.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Re-reads the palette (layer colours are cached, everything else draws live).
    func restyle() {
        layer?.backgroundColor = Theme.paper.cgColor
        layer?.borderColor = Theme.hair.cgColor
        appearance = NSAppearance(named: Theme.isDark ? .darkAqua : .aqua)
    }
}

/// The selected row is a bar of solid ink.
final class RowView: NSTableRowView {
    var lcd = false
    override func drawSelection(in dirtyRect: NSRect) {
        if lcd { return }
        Theme.ink.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
    override var isEmphasized: Bool { get { false } set {} }
}

/// The field editor. (The caret itself is `CaretView`: macOS draws its own insertion indicator, so we hide it and draw ours.)
final class BlockCaretEditor: NSTextView {}

/// A solid orange block, like a terminal or calculator cursor. This is the "blink" in Blink.
/// It blinks on the GPU (a layer animation), and is solid while you type.
final class CaretView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.accent.cgColor
        layer?.cornerRadius = 1
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func restartBlink() {
        layer?.removeAnimation(forKey: "blink")
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [1, 1, 0, 0]
        a.keyTimes = [0, 0.56, 0.56, 1]
        a.calculationMode = .discrete
        a.duration = 1.1
        a.repeatCount = .infinity
        a.beginTime = CACurrentMediaTime() + 0.5            // stay solid for half a second after every keystroke
        a.fillMode = .backwards
        layer?.add(a, forKey: "blink")
    }
}

/// Shortcut hints: outlined keys, plain labels.
final class FooterView: NSView {
    var stringValue: String = "" {
        didSet { if stringValue != oldValue { parse(); needsDisplay = true } }
    }
    override var isFlipped: Bool { true }
    private var items: [(key: String?, label: String)] = []
    private static let keyFont = Theme.mono(9.5, .semibold), labelFont = Theme.sans(10.5, .regular)

    static func isKey(_ t: String) -> Bool { t == "esc" || (t.count <= 3 && t.contains { "↵⌘⌥⌃⇧⌫↑↓←→".contains($0) }) }

    private func parse() {
        items = stringValue.components(separatedBy: "   ")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { seg in
                if let sp = seg.firstIndex(of: " ") {
                    let k = String(seg[..<sp])
                    if Self.isKey(k) { return (k, String(seg[seg.index(after: sp)...])) }
                } else if Self.isKey(seg) { return (seg, "") }
                return (nil, seg)
            }
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        let h = bounds.height
        for it in items {
            if let k = it.key {
                let ks = NSAttributedString(string: k, attributes: [.font: Self.keyFont, .foregroundColor: Theme.muted])
                let sz = ks.size()
                let cap = NSRect(x: x + 0.5, y: ((h - 16) / 2).rounded() + 0.5, width: (sz.width + 10).rounded(), height: 16)
                Theme.muted.withAlphaComponent(0.55).setStroke()
                let p = NSBezierPath(roundedRect: cap, xRadius: 3.5, yRadius: 3.5); p.lineWidth = 1; p.stroke()
                ks.draw(at: NSPoint(x: cap.minX + 5, y: cap.minY + ((16 - sz.height) / 2).rounded()))
                x = cap.maxX + 6
            }
            if !it.label.isEmpty {
                let ls = NSAttributedString(string: it.label, attributes: [.font: Self.labelFont, .foregroundColor: Theme.muted])
                let sz = ls.size()
                ls.draw(at: NSPoint(x: x, y: ((h - sz.height) / 2).rounded()))
                x += sz.width
            }
            x += 18
        }
    }
}

// MARK: - Result row
/// The 3-letter kind tag, printed in the same dot-matrix as the answer display: Blink's own voice.
final class TagView: NSView {
    private var text = ""
    private var color = NSColor.clear
    private static let cell: CGFloat = 2, radius: CGFloat = 0.8

    func set(_ t: String, selected: Bool) {
        text = t
        color = selected ? Theme.accentSoft : Theme.muted
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let c = Self.cell
        let w = text.reduce(CGFloat(0)) { $0 + DotMatrix.advance($1) * c } - 1.2 * c
        let p = NSBezierPath()
        DotMatrix.add(text, to: p, x: (bounds.width - w).rounded(), top: (bounds.midY + 3.5 * c).rounded(), cell: c, radius: Self.radius)
        color.setFill(); p.fill()
    }
}

final class ResultCell: NSTableCellView {
    let icon = KeyIcon()
    let title = NSTextField(labelWithString: "")
    let sub = NSTextField(labelWithString: "")
    let kind = TagView()
    let lcd = LCDView()
    private(set) var hit: Hit?
    private var query = ""
    private var iconPath: String?
    var isLCD = false
    private var hasTag = false { didSet { if hasTag != oldValue { needsLayout = true } } }
    /// Only plain numeric answers (tag CAL) earn the dot-matrix display.
    static func isLCD(_ h: Hit) -> Bool { h.calc != nil && h.tag == "CAL" && DotMatrix.supports(h.shown ?? h.calc ?? "") }

    var isSel = false {
        didSet { if isSel != oldValue { refresh() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        sub.lineBreakMode = .byTruncatingMiddle
        title.lineBreakMode = .byTruncatingTail
        for v in [icon, title, sub, kind, lcd] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }

    // Plain frames: Auto Layout here cost several ms on every keystroke.
    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        lcd.frame = bounds
        icon.frame = NSRect(x: 18, y: ((h - 26) / 2).rounded(), width: 26, height: 26)
        kind.frame = NSRect(x: w - 64, y: ((h - 16) / 2).rounded(), width: 44, height: 16)
        let x: CGFloat = 56, tw = max(0, w - (hasTag ? 64 + 12 : 20) - x)
        let y = ((h - 33) / 2).rounded()
        sub.frame = NSRect(x: x, y: y, width: tw, height: 14)
        title.frame = NSRect(x: x, y: y + 14, width: tw, height: 19)
    }

    func configure(_ h: Hit, query: String, selected: Bool) {
        hit = h; self.query = query
        isLCD = Self.isLCD(h)
        isSel = selected; refresh(force: true)     // the icon redraws itself when its glyph, image or selection changes
    }

    private func refresh(force: Bool = false) {
        guard let h = hit else { return }
        let sel = isSel
        lcd.isHidden = !isLCD
        for v in [icon, title, sub, kind] as [NSView] { v.isHidden = isLCD }
        if isLCD {
            lcd.text = h.shown ?? h.calc ?? ""
            lcd.label = h.label ?? ""
            lcd.selected = sel
            return
        }
        icon.selected = sel
        if let r = h.calc {
            title.attributedStringValue = NSAttributedString(string: h.shown ?? r, attributes: [
                .font: Theme.mono(15, .medium), .foregroundColor: sel ? Theme.paper : Theme.ink])
            sub.attributedStringValue = NSAttributedString(string: h.label ?? ("= " + query.trimmingCharacters(in: .whitespaces)), attributes: [
                .font: Theme.mono(10.5, .regular), .foregroundColor: sel ? Theme.onInkMuted : Theme.muted])
            icon.appImage = nil
            icon.glyph = Glyph.name(forTag: h.tag)
            hasTag = false                  // the ⇄ icon already says "conversion"
            kind.set("", selected: sel)
            return
        }
        title.attributedStringValue = Self.styled(h.name, query: query, selected: sel)
        sub.attributedStringValue = Self.crumbs(h.path, selected: sel)
        let (t, g) = Self.kind(of: h)
        // A tag only appears when it adds something: a real app icon or a folder already says what it is.
        let showTag = t != "APP" && t != "DIR"
        hasTag = showTag
        kind.set(showTag ? t : "", selected: sel)
        if h.isApp {
            iconPath = h.path
            if let img = IconCache.cached(h.path) { icon.appImage = img }
            else {
                icon.appImage = nil
                let path = h.path
                IconCache.load(path) { [weak self] img in if self?.iconPath == path { self?.icon.appImage = img } }
            }
        } else {
            iconPath = nil
            icon.appImage = nil
            icon.glyph = g
        }
    }

    /// 3-letter tag and the glyph that goes with it
    static func kind(of h: Hit) -> (String, String) {
        func r(_ t: String) -> (String, String) { (t, Glyph.name(forTag: t)) }
        if h.isApp { return ("APP", "fil") }
        if h.isProject { return r("PRO") }
        if h.isDir { return r("DIR") }
        let ext = (h.path as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "tiff", "bmp", "raw": return r("IMG")
        case "mp4", "mov", "mkv", "avi", "webm", "m4v": return r("VID")
        case "mp3", "wav", "m4a", "flac", "aac", "aiff": return r("AUD")
        case "pdf": return r("PDF")
        case "doc", "docx", "pages", "txt", "md", "rtf", "odt": return r("DOC")
        case "xls", "xlsx", "csv", "numbers", "tsv": return r("XLS")
        case "ppt", "pptx", "key": return r("PPT")
        case "zip", "tar", "gz", "rar", "7z", "dmg", "pkg", "xz", "bz2", "iso": return r("ZIP")
        case "swift", "py", "js", "ts", "tsx", "jsx", "c", "h", "cpp", "hpp", "cc", "go", "rs", "java", "kt",
             "rb", "php", "sh", "zsh", "html", "css", "json", "yaml", "yml", "toml", "sql", "lua", "zig", "cs", "m", "mm": return r("SRC")
        case "": return r("FIL")
        default: return (String(ext.uppercased().prefix(3)).padding(toLength: 3, withPad: "X", startingAt: 0), "fil")
        }
    }

    private static let nameFont = Theme.sans(14.5, .regular), matchFont = Theme.sans(14.5, .medium)

    /// Name, with the letters you typed in orange.
    static func styled(_ name: String, query: String, selected: Bool) -> NSAttributedString {
        let base = selected ? Theme.paper : Theme.ink, hi = selected ? Theme.accentSoft : Theme.accentText
        let a = NSMutableAttributedString(string: name, attributes: [.font: nameFont, .foregroundColor: base])
        guard !query.isEmpty else { return a }
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: hi, .font: matchFont]
        let ns = name as NSString
        let r = ns.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
        if r.location != NSNotFound { a.addAttributes(attrs, range: r); return a }
        let chars = Array(name.utf16), q = Array(query.lowercased().utf16)
        var qi = 0
        for (i, c) in chars.enumerated() where qi < q.count {
            let l = (c >= 65 && c <= 90) ? c + 32 : c
            if l == q[qi] { a.addAttributes(attrs, range: NSRange(location: i, length: 1)); qi += 1 }
        }
        return a
    }

    /// Where it lives: ~ / Developer / Blink. The name is on the line above, so it isn't repeated here,
    /// and a long path loses its middle, never the folder it's actually in.
    static func crumbs(_ path: String, selected: Bool) -> NSAttributedString {
        let dim = selected ? Theme.onInkMuted : Theme.muted
        let parent = ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        let parts = parent.split(separator: "/", omittingEmptySubsequences: true)
        let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byTruncatingMiddle
        let f = Theme.mono(10.5, .regular)
        if parts.isEmpty { return NSAttributedString(string: "/", attributes: [.font: f, .foregroundColor: dim, .paragraphStyle: ps]) }
        let a = NSMutableAttributedString()
        for (i, s) in parts.enumerated() {
            if i > 0 { a.append(NSAttributedString(string: " / ", attributes: [.font: f, .foregroundColor: dim, .paragraphStyle: ps])) }
            a.append(NSAttributedString(string: String(s), attributes: [.font: f,   .foregroundColor: dim, .paragraphStyle: ps]))
        }
        return a
    }
}
