import AppKit

// MARK: - Icons
/// Icon lookups can take ~3 ms each, so they never run on the main thread.
enum IconCache {
    private static let cache: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 1000; return c }()
    private static let queue = DispatchQueue(label: "blink.icons", qos: .userInitiated)

    static func cached(_ path: String) -> NSImage? { cache.object(forKey: path as NSString) }

    static func load(_ path: String, _ done: @escaping (NSImage) -> Void) {
        queue.async {
            let img = cached(path) ?? NSWorkspace.shared.icon(forFile: path)
            cache.setObject(img, forKey: path as NSString)
            DispatchQueue.main.async { done(img) }
        }
    }

    /// Fill the cache with app icons once, so launching apps never waits on an icon.
    static func prewarm<S: Sequence>(_ paths: S) where S.Element == String {
        let list = Array(paths)
        DispatchQueue.global(qos: .utility).async {
            for p in list where cached(p) == nil { cache.setObject(NSWorkspace.shared.icon(forFile: p), forKey: p as NSString) }
        }
    }
}

// MARK: - Views
final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// True while the settings card is open: clicks on it must never dismiss the panel.
    var keepOpen = false
    /// Called whenever the panel leaves the screen, so event monitors can be torn down.
    var onHide: (() -> Void)?
    override func resignKey() { super.resignKey(); if !keepOpen { orderOut(nil) } }
    override func orderOut(_ sender: Any?) { super.orderOut(sender); onHide?() }

    private lazy var editor: BlockCaretEditor = {
        let e = BlockCaretEditor()
        e.isFieldEditor = true
        e.insertionPointColor = .clear          // hidden: our CaretView is the caret
        e.selectedTextAttributes = [.backgroundColor: Theme.accent.withAlphaComponent(0.28), .foregroundColor: Theme.ink]
        return e
    }()
    /// The block caret lives in a custom field editor.
    var editorView: BlockCaretEditor { editor }

    func restyleEditor() {
        editor.selectedTextAttributes = [.backgroundColor: Theme.accent.withAlphaComponent(0.28), .foregroundColor: Theme.ink]
    }
    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        if object is NSTextField { return editor }
        return super.fieldEditor(createFlag, for: object)
    }
}

// MARK: - Controller
final class LauncherController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let width: CGFloat = 680
    static let fieldH: CGFloat = 58
    static let rowH: CGFloat = 46
    static let footerH: CGFloat = 44

    let panel: LauncherPanel
    let prompt = NSView()      // zero-width anchor; the caret is the mark now
    let field = NSTextField()
    let divider = RulerView()
    let footer = FooterView()
    let table = NSTableView()
    let scroll = NSScrollView()
    let titleLabel = NSTextField(labelWithString: "Settings")
    /// Drawn by us rather than as a field placeholder: it starts after the block caret and shares the typed text's baseline.
    let hint = NSTextField(labelWithString: "")
    let caret = CaretView()
    private var caretX: NSLayoutConstraint?
    var hits: [Hit] = []
    var hitsQuery = ""
    var generation = 0
    private let genLock = NSLock()
    private var latestGen = 0
    let searchQueue = DispatchQueue(label: "blink.search", qos: .userInteractive)

    // calculator history (newest first, persisted)
    struct HistEntry: Codable { var shown: String; var label: String?; var calc: String; var tag: String }
    static let historyKey = "blink.history"
    var history: [HistEntry] = []
    var historyShown = false

    // trash / undo
    var trashStack: [(orig: URL, trashed: URL)] = []
    private var hidden = Set<String>()          // trashed paths the index may still list
    private let hideLock = NSLock()
    var undoDeadline = Date.distantPast
    var flashText: String?
    private var flashToken = 0

    // settings card + monitors
    var settingsOpen = false
    var card: SettingsCard?
    private var savedText = ""
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var cmdDownAt: TimeInterval?
    private var cmdTainted = false

    override init() {
        panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.fieldH),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onHide = { [weak self] in self?.didHide() }
        history = Self.loadHistory()
        NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.card?.refresh(); self?.updateFooter()
        }

        let fx = PaperView()
        panel.contentView = fx


        field.font = Theme.sans(24, .light)
        field.textColor = Theme.ink
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        hint.isEditable = false; hint.isSelectable = false
        setHint()
        NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: panel.editorView, queue: .main) { [weak self] _ in
            self?.placeCaret()
        }



        titleLabel.font = Theme.sans(24, .light)
        titleLabel.textColor = Theme.ink
        titleLabel.isHidden = true

        let col = NSTableColumn(identifier: .init("c")); col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .plain                // the default style hides ~10 pt of padding above the rows, which clipped the last one
        table.rowHeight = Self.rowH
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)

        scroll.documentView = table
        scroll.drawsBackground = false
        // Draw the whole list into one layer: no typical speedup, but fewer slow keystrokes (worst 22 ms vs 39 ms over 9 runs).
        table.wantsLayer = true; table.canDrawSubviewsIntoLayer = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.hasVerticalScroller = false

        for v in [prompt, field, hint, titleLabel, divider, scroll, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false; fx.addSubview(v)
        }
        fx.addSubview(caret)
        caret.translatesAutoresizingMaskIntoConstraints = false
        let cx = caret.leadingAnchor.constraint(equalTo: field.leadingAnchor)
        caretX = cx
        NSLayoutConstraint.activate([cx, caret.centerYAnchor.constraint(equalTo: field.centerYAnchor),
                                     caret.widthAnchor.constraint(equalToConstant: 10), caret.heightAnchor.constraint(equalToConstant: 26)])
        NSLayoutConstraint.activate([
            prompt.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 0),
            prompt.widthAnchor.constraint(equalToConstant: 0),
            prompt.heightAnchor.constraint(equalToConstant: 22),
            prompt.centerYAnchor.constraint(equalTo: fx.topAnchor, constant: (Self.fieldH - 2) / 2),
            field.centerYAnchor.constraint(equalTo: prompt.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: prompt.trailingAnchor, constant: 26),
            field.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -26),
            hint.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 15),
            hint.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: prompt.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            divider.topAnchor.constraint(equalTo: fx.topAnchor, constant: Self.fieldH - 8),
            divider.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 16),
            divider.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -16),
            divider.heightAnchor.constraint(equalToConstant: 7),
            scroll.topAnchor.constraint(equalTo: fx.topAnchor, constant: Self.fieldH + 4),
            scroll.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: fx.bottomAnchor, constant: -Self.footerH),
            footer.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 22),
            footer.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -22),
            footer.bottomAnchor.constraint(equalTo: fx.bottomAnchor, constant: -12),
            footer.heightAnchor.constraint(equalToConstant: 20),      // taller than the 16 pt keys, so their outlines are never clipped
        ])
    }

    // MARK: show / hide
    func toggle() { panel.isVisible ? panel.orderOut(nil) : show() }

    func setHint() {
        let s = NSMutableAttributedString(string: "search apps, files, projects…", attributes: [.font: Theme.sans(18, .regular), .foregroundColor: Theme.muted])
        s.append(NSAttributedString(string: "   d: f: a: ~/", attributes: [.font: Theme.mono(11.5, .regular), .foregroundColor: Theme.muted]))
        hint.attributedStringValue = s
    }

    /// Put the block caret where the text cursor is.
    func placeCaret() {
        guard !settingsOpen, let ed = field.currentEditor() as? NSTextView else { caret.isHidden = true; return }
        let sel = ed.selectedRange()
        if sel.length > 0 { caret.isHidden = true; return }          // a selection shows its own highlight
        let winRect = panel.convertFromScreen(ed.firstRect(forCharacterRange: sel, actualRange: nil))
        // Only x is measured. y is pinned to the field by a constraint, so a panel resize can't strand the caret.
        caretX?.constant = field.convert(winRect, from: nil).minX.rounded()
        caret.isHidden = false
        caret.restartBlink()
    }

    func syncHint() { hint.isHidden = settingsOpen || !field.stringValue.isEmpty }

    /// Re-read the (light or dark) palette: cached layer colours, field text colours, the hint.
    func restyle() {
        (panel.contentView as? PaperView)?.restyle()
        divider.needsDisplay = true
        field.textColor = Theme.ink
        titleLabel.textColor = Theme.ink
        panel.restyleEditor()
        setHint()
        card?.needsDisplay = true
    }

    func show() {
        flashText = nil
        historyShown = false
        cmdDownAt = nil
        Theme.update(); restyle()
        field.stringValue = ""
        apply(Index.shared.search(""), "")
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let f = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(x: f.midX - Self.width / 2, y: f.maxY - f.height * 0.22))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        placeCaret()
        installMonitor()
    }

    /// One local monitor, alive only while the panel is on screen. Every branch bails out after a cheap check.
    private func installMonitor() {
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            guard let self = self, e.window === self.panel else { return e }
            if e.type == .flagsChanged { self.handleModifiers(e.modifierFlags, at: e.timestamp); return e }
            return self.handleKeyDown(chars: e.charactersIgnoringModifiers ?? "", keyCode: e.keyCode, flags: e.modifierFlags) ? nil : e
        }
    }

    private func didHide() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if settingsOpen { closeSettings(restore: false) }
        cmdDownAt = nil
    }

    // MARK: search
    func controlTextDidChange(_ obj: Notification) { syncHint(); runSearch(field.stringValue) }

    /// Below this many files a search takes well under a millisecond, so it runs right here
    /// and the keystroke and its results land in the same frame.
    static let inlineLimit = 200_000

    @inline(__always) static func isPathQuery(_ q: String) -> Bool {
        let f = q.utf8.first; return f == 47 || f == 126      // "/" or "~"
    }
    /// d: f: a: filter prefix (the index understands it; calculator rows are skipped).
    static func hasFilterPrefix(_ q: String) -> Bool {
        let u = q.utf8; guard u.count >= 2 else { return false }
        let c = u[u.startIndex], colon = u[u.index(after: u.startIndex)]
        return colon == 58 && (c | 32 == 100 || c | 32 == 102 || c | 32 == 97)
    }
    /// What gets lit up in result names: the query without its filter prefix, or the last path fragment.
    static func highlightQuery(_ q: String) -> String {
        guard let f = q.utf8.first else { return q }
        if f == 47 || f == 126 {
            if let i = q.lastIndex(of: "/") { return String(q[q.index(after: i)...]) }
            return ""
        }
        return hasFilterPrefix(q) ? Index.stripFilter(q) : q
    }

    func results(_ q: String) -> [Hit] {
        if Self.isPathQuery(q) { return dropHidden(Index.shared.listDirectory(q)) }
        hideLock.lock(); let extra = min(hidden.count, 8); hideLock.unlock()
        var r = Index.shared.search(q, limit: 8 + extra)
        if extra > 0 { r = Array(dropHidden(r).prefix(8)) }
        if Self.hasFilterPrefix(q) { return r }
        let rows = Calc.rows(q)
        if !rows.isEmpty {
            let calcHits = rows.map { Hit(path: "", name: $0.copy, isApp: false, isDir: false, isProject: false,
                                          calc: $0.copy, shown: $0.shown, label: $0.label, tag: $0.tag) }
            r = Array((calcHits + r).prefix(8))
        }
        return r
    }

    private func dropHidden(_ r: [Hit]) -> [Hit] {
        hideLock.lock(); defer { hideLock.unlock() }
        return hidden.isEmpty ? r : r.filter { !hidden.contains($0.path) }
    }

    /// (The little prompt glyph is gone: the block caret is Blink's mark.)
    func setPrompt(_ name: String) {}

    func apply(_ r: [Hit], _ q: String) {
        let old = hits
        hits = r
        syncHint()
        hitsQuery = Self.highlightQuery(q)
        // Same rows, same heights: refresh the live cells in place. reloadData rebuilds every row view
        // (key-view loop, layout), which was most of the main-thread time per keystroke.
        var cells: [ResultCell] = []
        if !r.isEmpty, old.count == r.count, zip(old, r).allSatisfy({ ResultCell.isLCD($0) == ResultCell.isLCD($1) }) {
            for row in 0..<r.count {
                guard let c = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ResultCell else { break }
                cells.append(c)
            }
        }
        if !r.isEmpty, cells.count == r.count {
            table.selectRowIndexes([0], byExtendingSelection: false)
            for (row, c) in cells.enumerated() { c.configure(r[row], query: hitsQuery, selected: row == 0) }
        } else {
            table.reloadData()
            if !r.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        }
        updateFooter()
        resize()
    }

    func runSearch(_ q: String) {
        generation += 1
        historyShown = false
        let gen = generation
        if Index.shared.count < Self.inlineLimit && !Self.isPathQuery(q) { apply(results(q), q); return }
        genLock.lock(); latestGen = gen; genLock.unlock()
        searchQueue.async {
            self.genLock.lock(); let stale = gen != self.latestGen; self.genLock.unlock()
            if stale { return }     // typed again before this one started
            let r = self.results(q)
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.apply(r, q)
            }
        }
    }

    /// Lays out and draws everything once at launch, invisibly, so the first real open is as quick as any other.
    @objc func warm() {
        let fake = (0..<8).map { _ in Hit(path: "/", name: "warm", isApp: false, isDir: true, isProject: false) }
        apply(fake, "warm")
        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()
        panel.orderOut(nil)
        panel.alphaValue = 1
        apply([], "")
    }

    private func setSize(width w: CGFloat, height h: CGFloat) {
        var fr = panel.frame
        if fr.height == h && fr.width == w { return }
        fr.origin.y += fr.height - h
        fr.origin.x -= (w - fr.width) / 2
        fr.size = NSSize(width: w, height: h)
        panel.setFrame(fr, display: false)
    }

    static let lcdRowH: CGFloat = 88
    func rowHeight(_ h: Hit) -> CGFloat { ResultCell.isLCD(h) ? Self.lcdRowH : Self.rowH }
    func rowsHeight() -> CGFloat { hits.reduce(0) { $0 + rowHeight($1) } }

    func resize() {
        if settingsOpen { return }
        let has = !hits.isEmpty
        let bare = !has && (flashText != nil || field.stringValue.isEmpty)   // flash message or "⌘ settings" hint
        divider.isHidden = !(has || bare)
        footer.isHidden = !(has || bare)
        let h = Self.fieldH + (has ? rowsHeight() + 4 + Self.footerH : (bare ? Self.footerH : 0))
        setSize(width: Self.width, height: h)
    }

    private func setFooter(_ t: String) { if footer.stringValue != t { footer.stringValue = t } }

    static func trashable(_ path: String) -> Bool {
        !path.isEmpty && !["/System/", "/usr/", "/bin/", "/sbin/", "/private/"].contains { path.hasPrefix($0) }
    }

    var selectedHit: Hit? {
        let row = table.selectedRow
        return row >= 0 && row < hits.count ? hits[row] : nil
    }

    func updateFooter() {
        if let f = flashText { setFooter(f); return }
        guard let h = selectedHit else { setFooter(hits.isEmpty && field.stringValue.isEmpty ? "⌘ settings" : ""); return }
        if h.calc != nil { setFooter(historyShown ? "↵ copy again     ⌘C copy     esc close" : "↵ copy result     ⌘C copy     esc close"); return }
        var parts = [h.isProject ? "↵ open in \(Settings.shared.editorName)" : (h.isApp ? "↵ launch" : (h.isDir ? "↵ Finder" : "↵ open"))]
        if !h.isDir || h.isProject { parts.append("⌘↵ Finder") }
        parts.append("⌘C path"); parts.append("⌘T terminal")
        if Self.trashable(h.path) { parts.append("⌘⌫ trash") }
        setFooter(parts.joined(separator: "   "))
    }

    /// Footer message that survives selection changes and re-searches for a few seconds.
    func flash(_ t: String, seconds: Double = 4) {
        flashText = t
        flashToken += 1
        let tok = flashToken
        setFooter(t); resize()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self = self, tok == self.flashToken else { return }
            self.flashText = nil; self.updateFooter(); self.resize()
        }
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        let sel = table.selectedRow
        table.enumerateAvailableRowViews { rv, row in (rv.view(atColumn: 0) as? ResultCell)?.isSel = (row == sel) }
        updateFooter()
    }

    // MARK: keys
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)):
            if field.stringValue.isEmpty, !historyShown, !history.isEmpty, table.selectedRow <= 0 { showHistory(); return true }
            move(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            activate(reveal: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
            return true
        case #selector(NSResponder.cancelOperation(_:)): panel.orderOut(nil); return true
        default: return false
        }
    }

    func move(_ d: Int) {
        guard !hits.isEmpty else { return }
        let next = max(0, min(hits.count - 1, max(table.selectedRow, 0) + d))
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    /// Modifier-only taps: Command down then up within 0.5 s with no key in between toggles the settings card.
    func handleModifiers(_ flags: NSEvent.ModifierFlags, at t: TimeInterval) {
        let f = flags.intersection([.command, .shift, .option, .control])
        if f == [.command] {
            if cmdDownAt == nil { cmdDownAt = t; cmdTainted = false }
        } else if f.contains(.command) {
            cmdTainted = true
        } else if let d = cmdDownAt {
            cmdDownAt = nil
            if !cmdTainted && t - d < 0.5 && !(settingsOpen && Settings.shared.isRecordingHotkey) { toggleSettings() }
        }
    }

    /// Returns true when the key was consumed.
    func handleKeyDown(chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        if cmdDownAt != nil { cmdTainted = true }
        let f = flags.intersection([.command, .shift, .option, .control])
        let cmdOnly = f == [.command]
        if cmdOnly && chars == "," { toggleSettings(); return true }
        if settingsOpen { return false }       // arrows, space, return, esc belong to the card
        guard cmdOnly else { return false }
        switch chars.lowercased() {
        // No main menu in an accessory app, so the standard edit shortcuts are sent to the field editor by hand.
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
        case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        case "c":
            if let tv = panel.firstResponder as? NSTextView, tv.selectedRange().length > 0 {
                return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            }
            return copySelected()
        case "t": return terminalSelected()
        case "z":
            guard !trashStack.isEmpty, field.stringValue.isEmpty || Date() < undoDeadline else { return false }
            return undoTrash()
        default:
            if keyCode == 51 { return trashSelected() }
            return false
        }
    }

    // MARK: row actions
    @discardableResult func copySelected() -> Bool {
        guard let h = selectedHit else { return false }
        if h.calc != nil { activate(reveal: false); return true }
        guard !h.path.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(h.path, forType: .string)
        flash("Copied path", seconds: 1.5)
        return true
    }

    @discardableResult func terminalSelected() -> Bool {
        guard let h = selectedHit, h.calc == nil, !h.path.isEmpty else { return false }
        let url = URL(fileURLWithPath: h.path)
        let dir = (h.isDir || h.isProject) ? url : url.deletingLastPathComponent()
        panel.orderOut(nil)
        DispatchQueue.main.async { Settings.shared.openInTerminal(dir) }
        return true
    }

    @discardableResult func trashSelected() -> Bool {
        guard let h = selectedHit, h.calc == nil, !h.path.isEmpty else { return false }
        guard Self.trashable(h.path) else { flash("Can't move system items to Trash", seconds: 3); return true }
        let url = URL(fileURLWithPath: h.path)
        // NSWorkspace.recycle (unlike FileManager.trashItem) records the original location, so Finder's Put Back works.
        hideLock.lock(); hidden.insert(h.path); hideLock.unlock()
        NSWorkspace.shared.recycle([url]) { [weak self] moved, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let t = moved[url] {
                    self.trashStack.append((url, t))
                    self.undoDeadline = Date().addingTimeInterval(4)
                    self.flashText = nil; self.flash("Moved to Trash · ⌘Z to undo")
                } else {
                    let m = error?.localizedDescription ?? "unknown error"
                    self.hideLock.lock(); self.hidden.remove(h.path); self.hideLock.unlock()
                    self.flash("Can't trash: " + (m.count > 70 ? String(m.prefix(70)) + "…" : m), seconds: 4)
                    if !self.historyShown { self.runSearch(self.field.stringValue) }
                }
            }
        }
        // drop the row right now, then refill from a fresh search
        let row = table.selectedRow
        hits.removeAll { $0.path == h.path }
        table.reloadData()
        if !hits.isEmpty { table.selectRowIndexes([min(row, hits.count - 1)], byExtendingSelection: false) }
        updateFooter(); resize()
        if !historyShown { runSearch(field.stringValue) }
        return true
    }

    @discardableResult func undoTrash() -> Bool {
        guard let last = trashStack.last else { return false }
        do {
            try FileManager.default.moveItem(at: last.trashed, to: last.orig)
        } catch {
            let m = (error as NSError).localizedDescription
            flash("Can't restore: " + (m.count > 70 ? String(m.prefix(70)) + "…" : m), seconds: 4)
            return true
        }
        trashStack.removeLast()
        hideLock.lock(); hidden.remove(last.orig.path); hideLock.unlock()
        flash("Restored", seconds: 2)
        if !historyShown { runSearch(field.stringValue) }
        return true
    }

    // MARK: calculator history
    static func loadHistory() -> [HistEntry] {
        guard let d = UserDefaults.standard.data(forKey: historyKey),
              let h = try? JSONDecoder().decode([HistEntry].self, from: d) else { return [] }
        return h
    }

    func pushHistory(_ h: Hit) {
        guard let c = h.calc else { return }
        let e = HistEntry(shown: h.shown ?? c, label: h.label, calc: c, tag: h.tag)
        history.removeAll { $0.calc == e.calc && $0.label == e.label }
        history.insert(e, at: 0)
        if history.count > 20 { history.removeLast(history.count - 20) }
        if let d = try? JSONEncoder().encode(history) { UserDefaults.standard.set(d, forKey: Self.historyKey) }
    }

    func showHistory() {
        generation += 1                      // cancel any pending async search
        let rows = history.prefix(8).map {
            Hit(path: "", name: $0.calc, isApp: false, isDir: false, isProject: false,
                calc: $0.calc, shown: $0.shown, label: $0.label, tag: $0.tag)
        }
        apply(Array(rows), "")
        historyShown = true
        updateFooter()
    }

    // MARK: settings card
    func toggleSettings() { settingsOpen ? closeSettings() : openSettings() }

    func openSettings() {
        guard !settingsOpen else { return }
        settingsOpen = true
        panel.keepOpen = true
        savedText = field.stringValue
        let c = card ?? SettingsCard(onClose: { [weak self] in self?.closeSettings() })
        card = c
        c.refresh()
        hint.isHidden = true
        caret.isHidden = true
        c.needsDisplay = true
        let sz = SettingsCard.size
        setPrompt("gearshape")
        guard let cv = panel.contentView else { return }
        setSize(width: max(Self.width, sz.width), height: Self.fieldH + sz.height)
        c.translatesAutoresizingMaskIntoConstraints = true
        c.autoresizingMask = []
        c.frame = NSRect(x: (cv.bounds.width - sz.width) / 2, y: 0, width: sz.width, height: sz.height)
        cv.addSubview(c)
        panel.makeFirstResponder(c)         // takes focus away from the field editor first
        field.isHidden = true
        titleLabel.isHidden = false
        scroll.isHidden = true
        footer.isHidden = true
        divider.isHidden = false
        installClickMonitor()
    }

    /// Clicking outside the panel (it can't see those as resign events while pinned open) closes everything.
    private func installClickMonitor() {
        if clickMonitor != nil { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.settingsOpen, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.panel.orderOut(nil)
        }
    }

    func closeSettings(restore: Bool = true) {
        guard settingsOpen else { return }
        settingsOpen = false
        panel.keepOpen = false
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        card?.removeFromSuperview()
        setPrompt("bolt")
        titleLabel.isHidden = true
        field.isHidden = false
        scroll.isHidden = false
        guard restore else { return }
        field.stringValue = savedText
        resize()
        panel.makeFirstResponder(field)
        (panel.fieldEditor(true, for: field) as? NSTextView)?.setSelectedRange(NSRange(location: (savedText as NSString).length, length: 0))
        runSearch(savedText)
    }

    @objc func openSelected() { activate(reveal: false) }

    func activate(reveal: Bool) {
        let row = table.selectedRow
        guard row >= 0, row < hits.count else { return }
        let h = hits[row]
        panel.orderOut(nil)
        if let r = h.calc {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(r, forType: .string)
            pushHistory(h)
            return
        }
        CATransaction.flush()
        let url = URL(fileURLWithPath: h.path)
        if h.isProject && !reveal { DispatchQueue.main.async { Settings.shared.openInEditor(url) } }
        DispatchQueue.global(qos: .userInitiated).async {
            Index.shared.recordUse(h.path)
            if reveal {
                if h.isDir { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } else if !h.isProject {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: table
    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tv: NSTableView, heightOfRow row: Int) -> CGFloat { rowHeight(hits[row]) }

    func tableView(_ tv: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let rv = (tv.makeView(withIdentifier: id, owner: nil) as? RowView) ?? { let r = RowView(); r.identifier = id; return r }()
        rv.lcd = ResultCell.isLCD(hits[row])
        return rv
    }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tv.makeView(withIdentifier: id, owner: nil) as? ResultCell) ?? {
            let c = ResultCell(frame: .zero); c.identifier = id; return c
        }()
        cell.configure(hits[row], query: hitsQuery, selected: row == tv.selectedRow)
        return cell
    }
}
