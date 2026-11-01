import AppKit
import Carbon
import ServiceManagement

// MARK: - Choices
enum EditorChoice: String, CaseIterable {
    case zed, vscode, cursor, sublime, xcode, finder

    var title: String {
        switch self {
        case .zed: return "Zed"
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        case .sublime: return "Sublime Text"
        case .xcode: return "Xcode"
        case .finder: return "Finder"
        }
    }
    /// Short label used on chips and in footer hints.
    var shortTitle: String { self == .sublime ? "Sublime" : title }
    /// nil = "just open in Finder".
    var bundleID: String? {
        switch self {
        case .zed: return "dev.zed.Zed"
        case .vscode: return "com.microsoft.VSCode"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .sublime: return "com.sublimetext.4"
        case .xcode: return "com.apple.dt.Xcode"
        case .finder: return nil
        }
    }
}

enum TerminalChoice: String, CaseIterable {
    case ghostty, terminal, iterm

    var title: String {
        switch self {
        case .ghostty: return "Ghostty"
        case .terminal: return "Terminal"
        case .iterm: return "iTerm"
        }
    }
    var bundleID: String {
        switch self {
        case .ghostty: return "com.mitchellh.ghostty"
        case .terminal: return "com.apple.Terminal"
        case .iterm: return "com.googlecode.iterm2"
        }
    }
}

// MARK: - Model
final class Settings {
    static let shared = Settings(defaults: .standard)
    /// Posted (on main) after any setting changes.
    static let didChange = Notification.Name("blink.settings.didChange")
    /// Posted when the hotkey recorder starts/stops; main.swift releases the global hotkey while recording.
    static let recordingChanged = Notification.Name("blink.settings.recordingChanged")
    /// Posted when `hotkeyStatus` changes (does NOT trigger a re-registration).
    static let hotkeyStatusChanged = Notification.Name("blink.settings.hotkeyStatusChanged")

    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }

    private func post(_ name: Notification.Name = Settings.didChange) {
        if Thread.isMainThread { NotificationCenter.default.post(name: name, object: nil) }
        else { DispatchQueue.main.async { NotificationCenter.default.post(name: name, object: nil) } }
    }

    // MARK: hotkey
    var hotkeyKeyCode: UInt32 {
        get { defaults.object(forKey: "blink.hotkeyKeyCode") != nil ? UInt32(defaults.integer(forKey: "blink.hotkeyKeyCode")) : UInt32(kVK_Space) }
        set { defaults.set(Int(newValue), forKey: "blink.hotkeyKeyCode"); post() }
    }
    var hotkeyModifiers: UInt32 {
        get { defaults.object(forKey: "blink.hotkeyModifiers") != nil ? UInt32(defaults.integer(forKey: "blink.hotkeyModifiers")) : UInt32(cmdKey) }
        set { defaults.set(Int(newValue), forKey: "blink.hotkeyModifiers"); post() }
    }
    /// Sets both halves with a single notification.
    func setHotkey(code: UInt32, modifiers: UInt32) {
        defaults.set(Int(code), forKey: "blink.hotkeyKeyCode")
        defaults.set(Int(modifiers), forKey: "blink.hotkeyModifiers")
        post()
    }
    /// Pieces of the shortcut in display order, e.g. ["⌘", "Space"].
    var hotkeyParts: [String] { Settings.parts(code: hotkeyKeyCode, modifiers: hotkeyModifiers) }
    var hotkeyDescription: String { hotkeyParts.joined(separator: " ") }

    /// Result of the last RegisterEventHotKey (0 = ok). Set by main.swift.
    var hotkeyStatus: Int32 = 0 {
        didSet { if hotkeyStatus != oldValue { post(Settings.hotkeyStatusChanged) } }
    }
    /// True while the card is listening for a new shortcut.
    var isRecordingHotkey = false {
        didSet { if isRecordingHotkey != oldValue { post(Settings.recordingChanged) } }
    }

    static func parts(code: UInt32, modifiers m: UInt32) -> [String] {
        var p: [String] = []
        if m & UInt32(controlKey) != 0 { p.append("⌃") }
        if m & UInt32(optionKey) != 0 { p.append("⌥") }
        if m & UInt32(shiftKey) != 0 { p.append("⇧") }
        if m & UInt32(cmdKey) != 0 { p.append("⌘") }
        p.append(keyName(code))
        return p
    }

    static func carbonModifiers(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 36: "↵", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16",
        64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
    static func keyName(_ code: UInt32) -> String { keyNames[code] ?? "Key \(code)" }

    // MARK: apps
    var editor: EditorChoice {
        get { EditorChoice(rawValue: defaults.string(forKey: "blink.editor") ?? "") ?? .zed }
        set { defaults.set(newValue.rawValue, forKey: "blink.editor"); post() }
    }
    var terminal: TerminalChoice {
        get { TerminalChoice(rawValue: defaults.string(forKey: "blink.terminal") ?? "") ?? .ghostty }
        set { defaults.set(newValue.rawValue, forKey: "blink.terminal"); post() }
    }
    var editorName: String { editor.shortTitle }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() } }
                else { try SMAppService.mainApp.unregister() }
            } catch { NSSound.beep() }
            post()
        }
    }

    func openInEditor(_ url: URL) {
        let ws = NSWorkspace.shared
        if let id = editor.bundleID, let app = ws.urlForApplication(withBundleIdentifier: id) {
            ws.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            ws.open(url)
        }
    }

    func openInTerminal(_ dir: URL) {
        let ws = NSWorkspace.shared
        var isDir: ObjCBool = false
        let target = (FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && !isDir.boolValue)
            ? dir.deletingLastPathComponent() : dir
        let app = ws.urlForApplication(withBundleIdentifier: terminal.bundleID)
            ?? ws.urlForApplication(withBundleIdentifier: TerminalChoice.terminal.bundleID)
        if let app = app {
            ws.open([target], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            ws.open(target)
        }
    }
}

// MARK: - Card
/// Keyboard-first settings card ("Instrument" look). Frames are computed in relayout(); draw(_:) only paints them.
final class SettingsCard: NSView {
    static let size = NSSize(width: 680, height: 322)
    /// Overridable for tests: is an app with this bundle id installed?
    static var installedCheck: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }

    private static let rowCount = 5, rowH: CGFloat = 54, rowTop: CGFloat = 8, rowX: CGFloat = 8
    private static let footerH: CGFloat = 44
    /// The hardware key surface: a touch lighter than the paper-dark keyFill.
    private static var capFill: NSColor { Theme.isDark ? Theme.c(0x34332F) : Theme.c(0xF4F2EC) }

    private let onClose: () -> Void
    private(set) var focusRow = 0
    /// True while waiting for a new shortcut; the host should not treat a lone ⌘ tap as "close" then.
    private(set) var isRecording = false
    private var note: String?                 // transient sub-line for row 0
    private var scanning = false
    private var monitor: Any?
    private var tokens: [NSObjectProtocol] = []

    // cached state (refresh)
    private var editorInstalled: [EditorChoice: Bool] = [:]
    private var terminalInstalled: [TerminalChoice: Bool] = [:]
    private var indexText = ""
    private var loginApproval = false
    private var loginOn = false

    // geometry (relayout)
    private struct Cap { var rect: NSRect; var text: String }
    /// One segment of a segmented control (rows 1-2), or the Rebuild button (row 4).
    private struct Chip { var rect: NSRect; var row: Int; var idx: Int; var title: String
                          var selected: Bool; var dim: Bool; var font: NSFont }
    private var caps: [Cap] = []
    private var recRect: NSRect?
    private var chips: [Chip] = []
    private var controls: [Int: NSRect] = [:]       // row -> outer rect of its segmented control
    private var switchRect = NSRect.zero
    private var rowRects: [NSRect] = []
    private var fontSize: CGFloat = 11, chipPad: CGFloat = 10

    // resources
    private let titleFont = Theme.sans(14.5, .regular)
    private let subFont = Theme.sans(11, .regular)
    private let capFont = Theme.mono(12, .semibold)
    private let glyphs = ["kbd", "code", "term", "power", "lens"]
    private let titles = ["Shortcut", "Editor", "Terminal", "Launch at login", "Index"]
    private let baseSubs = ["Opens Blink from anywhere", "↵ on a PRO result opens it here",
                            "⌘T on any result", "Start Blink when you log in", ""]
    private var icons: [KeyIcon] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }
    override func resignFirstResponder() -> Bool { stopRecording(); return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        addSubview(hints)
        icons = glyphs.map { g in let k = KeyIcon(); k.glyph = g; addSubview(k); return k }
        let nc = NotificationCenter.default
        for n in [Settings.didChange, Settings.hotkeyStatusChanged] {
            tokens.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        if let m = monitor { NSEvent.removeMonitor(m) }
        if isRecording { Settings.shared.isRecordingHotkey = false }
    }

    // MARK: state
    func refresh() {
        editorInstalled = Dictionary(uniqueKeysWithValues: EditorChoice.allCases.map {
            ($0, $0.bundleID.map { Self.installedCheck($0) } ?? true) })
        terminalInstalled = Dictionary(uniqueKeysWithValues: TerminalChoice.allCases.map { ($0, Self.installedCheck($0.bundleID)) })
        let st = SMAppService.mainApp.status
        loginOn = st == .enabled
        loginApproval = st == .requiresApproval
        let nf = NumberFormatter(); nf.numberStyle = .decimal; nf.locale = Locale(identifier: "en_US")
        let n = Index.shared.count
        let vols = max(0, Index.fileRoots().count - 1)
        indexText = "\(nf.string(from: NSNumber(value: n)) ?? "\(n)") items"
            + (vols > 0 ? "  ·  \(vols) volume\(vols == 1 ? "" : "s")" : "")
        relayout()
    }

    private let hints: FooterView = { let f = FooterView(); f.stringValue = "↑↓ select   ←→ change   ↵ edit   esc close"; return f }()

    override func layout() {
        super.layout(); relayout()
        hints.frame = NSRect(x: 22, y: bounds.height - Self.footerH + (Self.footerH - 20) / 2, width: bounds.width - 44, height: 20)
    }

    private func rowRect(_ i: Int) -> NSRect {
        NSRect(x: Self.rowX, y: Self.rowTop + CGFloat(i) * Self.rowH, width: bounds.width - 2 * Self.rowX, height: Self.rowH)
    }

    private func textW(_ s: String, _ f: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: f]).width)
    }

    private func relayout() {
        rowRects = (0..<Self.rowCount).map(rowRect)
        let right = rowRects[0].maxX - 16
        let chipH: CGFloat = 24
        caps = []; recRect = nil; chips = []; controls = [:]

        // row icons: 28 × 28 keycaps
        for (i, k) in icons.enumerated() {
            k.frame = NSRect(x: rowRects[i].minX + 10, y: (rowRects[i].midY - 14).rounded(), width: 28, height: 28)
            k.selected = i == focusRow
        }

        // row 0: keycaps / recording key
        let y0 = (rowRects[0].midY - chipH / 2).rounded()
        if isRecording {
            let w = textW("press keys…", capFont) + 28
            recRect = NSRect(x: right - w, y: y0, width: w, height: chipH)
        } else {
            var x = right
            for p in Settings.shared.hotkeyParts.reversed() {
                let w = max(26, textW(p, capFont) + 16)
                x -= w
                caps.insert(Cap(rect: NSRect(x: x, y: y0, width: w, height: chipH), text: p), at: 0)
                x -= 5
            }
        }

        // rows 1-2: segmented controls. Pick one metric that fits both rows.
        let edTitles = EditorChoice.allCases.map { $0.shortTitle }
        let teTitles = TerminalChoice.allCases.map { $0.title }
        let limit1 = Self.rowX + 54 + max(textW(titles[1], titleFont), textW(baseSubs[1], subFont)) + 16
        let limit2 = Self.rowX + 54 + max(textW(titles[2], titleFont), textW(baseSubs[2], subFont)) + 16
        func blockW(_ t: [String], _ fs: CGFloat, _ pad: CGFloat) -> CGFloat {
            t.reduce(0) { $0 + textW($1, Theme.mono(fs, .medium)) + 2 * pad } + CGFloat(t.count - 1)
        }
        var metric: (CGFloat, CGFloat) = (11, 10)
        for m in [(CGFloat(11), CGFloat(10)), (10, 10), (10, 8)] {
            metric = m
            if right - blockW(edTitles, m.0, m.1) >= limit1 && right - blockW(teTitles, m.0, m.1) >= limit2 { break }
        }
        fontSize = metric.0; chipPad = metric.1
        let f = Theme.mono(fontSize, .medium)

        func addSegments(row: Int, titles: [String], selected: Int, dim: [Bool]) {
            let y = (rowRects[row].midY - chipH / 2).rounded()
            let widths = titles.map { textW($0, f) + 2 * chipPad }
            let total = widths.reduce(0, +) + CGFloat(titles.count - 1)
            var x = (right - total).rounded()
            controls[row] = NSRect(x: x, y: y, width: total, height: chipH)
            for i in titles.indices {
                chips.append(Chip(rect: NSRect(x: x, y: y, width: widths[i], height: chipH), row: row, idx: i,
                                  title: titles[i], selected: i == selected, dim: dim[i], font: f))
                x += widths[i] + 1
            }
        }
        let s = Settings.shared
        addSegments(row: 1, titles: edTitles, selected: EditorChoice.allCases.firstIndex(of: s.editor) ?? 0,
                    dim: EditorChoice.allCases.map { !(editorInstalled[$0] ?? true) })
        addSegments(row: 2, titles: teTitles, selected: TerminalChoice.allCases.firstIndex(of: s.terminal) ?? 0,
                    dim: TerminalChoice.allCases.map { !(terminalInstalled[$0] ?? true) })

        // row 3: slide switch
        switchRect = NSRect(x: right - 40, y: (rowRects[3].midY - 11).rounded(), width: 40, height: 22)

        // row 4: button
        let bt = scanning ? "Scanning…" : "Rebuild"
        let bw = (textW(bt, f) + 2 * chipPad + 4).rounded()
        chips.append(Chip(rect: NSRect(x: right - bw, y: (rowRects[4].midY - chipH / 2).rounded(), width: bw, height: chipH),
                          row: 4, idx: 0, title: bt, selected: false, dim: scanning, font: f))
        needsDisplay = true
    }

    // MARK: drawing
    /// Sub line and whether it needs attention (drawn in the accent).
    private func subLine(_ row: Int) -> (String, Bool) {
        let s = Settings.shared
        switch row {
        case 0:
            if let n = note { return (n, true) }
            if s.hotkeyStatus != 0 { return ("Taken by macOS or another app — pick another", true) }
            if isRecording { return ("Hold ⌘, ⌥ or ⌃ and press a key  ·  esc cancels", true) }
        case 1:
            if editorInstalled[s.editor] == false { return ("Not installed — opens in Finder", true) }
        case 2:
            if terminalInstalled[s.terminal] == false { return ("Not installed — opens Terminal", true) }
        case 3:
            if loginApproval { return ("Approve Blink in System Settings → Login Items", true) }
        case 4:
            return (indexText, false)
        default: break
        }
        return (baseSubs[row], false)
    }

    private func drawText(_ s: String, _ f: NSFont, _ c: NSColor, in r: NSRect) {
        let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byTruncatingTail
        (s as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                             attributes: [.font: f, .foregroundColor: c, .paragraphStyle: ps])
    }

    private func drawCentered(_ s: String, _ f: NSFont, _ c: NSColor, in r: NSRect) {
        let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: c]
        let sz = (s as NSString).size(withAttributes: a)
        (s as NSString).draw(at: NSPoint(x: (r.midX - sz.width / 2).rounded(), y: (r.midY - sz.height / 2).rounded()), withAttributes: a)
    }

    /// A hardware key: light cap, 1 px edge. `on` = sitting on the ink bar.
    private func keycap(_ r: NSRect, on: Bool, edge: NSColor? = nil, fill: NSColor? = nil) {
        let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        (fill ?? (on ? Theme.onInkKey : Self.capFill)).setFill(); p.fill()
        (edge ?? (on ? Theme.onInkEdge : Theme.keyEdge)).setStroke(); p.lineWidth = 1; p.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard rowRects.count == Self.rowCount else { return }
        let s = Settings.shared

        // focused row = solid ink bar (same as the result rows)
        Theme.ink.setFill()
        NSBezierPath(roundedRect: rowRects[focusRow].insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5).fill()

        // title column is clipped against the control on its right
        var leftEdge: [Int: CGFloat] = [:]
        for c in chips { leftEdge[c.row] = min(leftEdge[c.row] ?? .infinity, c.rect.minX) }
        if let r = recRect { leftEdge[0] = r.minX } else if let c = caps.first { leftEdge[0] = c.rect.minX }
        leftEdge[3] = switchRect.minX

        for i in 0..<Self.rowCount {
            let r = rowRects[i], foc = i == focusRow
            let tx = r.minX + 54
            let maxX = (leftEdge[i] ?? r.maxX - 16) - 14
            let w = max(40, maxX - tx)
            drawText(titles[i], titleFont, foc ? Theme.paper : Theme.ink, in: NSRect(x: tx, y: r.minY + 11, width: w, height: 18))
            let (sub, attn) = subLine(i)
            let col = attn ? (foc ? Theme.accentSoft : Theme.accent) : (foc ? Theme.onInkMuted : Theme.muted)
            drawText(sub, subFont, col, in: NSRect(x: tx, y: r.minY + 30, width: w, height: 14))
        }

        let on0 = focusRow == 0
        // row 0: keycaps / recording key
        let err = s.hotkeyStatus != 0
        if let r = recRect {
            let acc = on0 ? Theme.accentSoft : Theme.accent
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            (on0 ? Theme.onInkKey : Self.capFill).setFill(); p.fill()
            p.lineWidth = 1; p.setLineDash([3, 2], count: 2, phase: 0)
            acc.setStroke(); p.stroke()
            drawCentered("press keys…", capFont, acc, in: r)
        } else {
            for c in caps {
                let acc = on0 ? Theme.accentSoft : Theme.accent
                keycap(c.rect, on: on0, edge: err ? acc : nil)
                drawCentered(c.text, capFont, err ? acc : (on0 ? Theme.paper : Theme.ink), in: c.rect)
            }
        }

        // rows 1-2: segmented controls
        for row in [1, 2] {
            guard let box = controls[row] else { continue }
            let foc = focusRow == row
            let edge = foc ? Theme.onInkEdge : Theme.hair
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            let segs = chips.filter { $0.row == row }
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            for (i, c) in segs.enumerated() {
                if c.selected {
                    (foc ? Theme.paper : Theme.ink).setFill()
                    NSRect(x: c.rect.minX - (i == 0 ? 0 : 1), y: box.minY, width: c.rect.width + (i == 0 ? 0 : 1) + (i == segs.count - 1 ? 0 : 1), height: box.height).fill()
                }
            }
            edge.setFill()
            for (i, c) in segs.enumerated() where i > 0 && !c.selected && !segs[i - 1].selected {
                NSRect(x: c.rect.minX - 1, y: box.minY, width: 1, height: box.height).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            edge.setStroke(); path.lineWidth = 1; path.stroke()
            for c in segs {
                let tc: NSColor
                if c.selected { tc = foc ? (c.dim ? Theme.muted : Theme.ink) : (c.dim ? Theme.onInkMuted : Theme.paper) }
                else if foc { tc = Theme.onInkMuted }
                else { tc = c.dim ? Theme.muted : Theme.ink }
                drawCentered(c.title, c.font, tc, in: c.rect)
            }
        }

        // row 3: slide switch
        let sr = switchRect, foc3 = focusRow == 3
        let track = NSBezierPath(roundedRect: sr.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        let tFill: NSColor, tEdge: NSColor, thumbC: NSColor
        if foc3 {
            tFill = loginOn ? Theme.paper : Theme.onInkKey; tEdge = loginOn ? Theme.paper : Theme.onInkEdge
            thumbC = loginOn ? Theme.ink : Theme.onInkMuted
        } else {
            tFill = loginOn ? Theme.ink : Theme.hair; tEdge = loginOn ? Theme.ink : Theme.keyEdge
            thumbC = loginOn ? Theme.paper : Theme.muted
        }
        tFill.setFill(); track.fill(); tEdge.setStroke(); track.lineWidth = 1; track.stroke()
        let kx = loginOn ? sr.maxX - 19 : sr.minX + 3
        thumbC.setFill()
        NSBezierPath(roundedRect: NSRect(x: kx, y: sr.minY + 3, width: 16, height: 16), xRadius: 3, yRadius: 3).fill()
        if loginOn {
            Theme.accent.setFill()
            NSRect(x: sr.minX + 10, y: sr.midY - 4, width: 2, height: 8).fill()
        }

        // row 4: Rebuild — an outlined keycap
        if let b = chips.first(where: { $0.row == 4 }) {
            let on4 = focusRow == 4
            keycap(b.rect, on: on4)
            drawCentered(b.title, b.font, b.dim ? (on4 ? Theme.onInkMuted : Theme.muted) : (on4 ? Theme.paper : Theme.ink), in: b.rect)
        }

        // footer rule
        Theme.hair.setFill()
        NSRect(x: 16, y: bounds.height - Self.footerH, width: bounds.width - 32, height: 1).fill()
    }

    // MARK: actions
    private func setFocus(_ r: Int) {
        let n = max(0, min(Self.rowCount - 1, r))
        if n != focusRow { focusRow = n; note = nil; if isRecording && n != 0 { stopRecording() } }
        relayout()
    }

    private func step(_ d: Int) {
        let s = Settings.shared
        switch focusRow {
        case 1:
            let all = EditorChoice.allCases, i = all.firstIndex(of: s.editor) ?? 0
            let n = max(0, min(all.count - 1, i + d)); if n != i { s.editor = all[n] }
        case 2:
            let all = TerminalChoice.allCases, i = all.firstIndex(of: s.terminal) ?? 0
            let n = max(0, min(all.count - 1, i + d)); if n != i { s.terminal = all[n] }
        case 3:
            let want = d > 0
            if want != loginOn { s.launchAtLogin = want }
        default: break
        }
        refresh()
    }

    private func activate() {
        switch focusRow {
        case 0: isRecording ? stopRecording() : startRecording()
        case 3: Settings.shared.launchAtLogin.toggle(); refresh()
        case 4: pressRebuild()
        default: break
        }
    }

    private func pressRebuild() {
        guard !scanning else { return }
        Index.shared.rebuild()
        scanning = true
        relayout()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.scanning = false
            self?.refresh()
        }
    }

    override func keyDown(with e: NSEvent) {
        note = nil
        switch Int(e.keyCode) {
        case kVK_UpArrow: setFocus(focusRow - 1)
        case kVK_DownArrow: setFocus(focusRow + 1)
        case kVK_LeftArrow: step(-1)
        case kVK_RightArrow: step(1)
        case kVK_Space, kVK_Return, kVK_ANSI_KeypadEnter: activate()
        case kVK_Escape: onClose()
        default: break
        }
        relayout()
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let s = Settings.shared
        if isRecording, !(recRect?.contains(p) ?? false) { stopRecording() }
        for c in chips where c.rect.contains(p) {
            setFocus(c.row)
            switch c.row {
            case 1: s.editor = EditorChoice.allCases[c.idx]
            case 2: s.terminal = TerminalChoice.allCases[c.idx]
            default: pressRebuild()
            }
            refresh(); return
        }
        if switchRect.contains(p) { setFocus(3); s.launchAtLogin.toggle(); refresh(); return }
        if let r = recRect, r.contains(p) { stopRecording(); return }
        if let first = caps.first, let last = caps.last, first.rect.union(last.rect).contains(p) {
            setFocus(0); startRecording(); return
        }
        for (i, r) in rowRects.enumerated() where r.contains(p) { setFocus(i); return }
    }

    // MARK: hotkey recording
    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        note = nil
        Settings.shared.isRecordingHotkey = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, self.isRecording else { return e }
            self.capture(e)
            return nil
        }
        relayout()
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        Settings.shared.isRecordingHotkey = false
        relayout()
    }

    private func capture(_ e: NSEvent) {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if e.keyCode == UInt16(kVK_Escape) && Settings.carbonModifiers(flags) == 0 { note = nil; stopRecording(); return }
        let mods = Settings.carbonModifiers(flags)
        if mods & UInt32(cmdKey | optionKey | controlKey) == 0 {
            note = "Needs ⌘, ⌥ or ⌃"
            relayout(); return
        }
        note = nil
        Settings.shared.setHotkey(code: UInt32(e.keyCode), modifiers: mods)   // main.swift ignores it until recording ends
        stopRecording()                                                        // -> main.swift registers the new combo
        refresh()
    }

    private var resignToken: NSObjectProtocol?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let t = resignToken { NotificationCenter.default.removeObserver(t); resignToken = nil }
        if let w = window {
            resignToken = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in
                self?.stopRecording()
            }
        } else { stopRecording() }
    }
    override func viewDidHide() { super.viewDidHide(); stopRecording() }
}
