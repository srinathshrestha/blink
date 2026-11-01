import AppKit
import Carbon
import ServiceManagement


final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var launcher: LauncherController!
    var statusItem: NSStatusItem!
    var hotKeyRef: EventHotKeyRef?
    var loginItem: NSMenuItem!
    private var handlerInstalled = false

    func applicationDidFinishLaunching(_ n: Notification) {
        launcher = LauncherController()
        launcher.warm()
        Index.shared.rebuild()
        Index.shared.watch()
        installHotKeyHandler()
        applyHotKey()
        // Re-register when the shortcut changes; release it while the settings card records a new one.
        for name in [Settings.didChange, Settings.recordingChanged] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.applyHotKey()
            }
        }
        // Rescan and re-watch when a drive is plugged in or ejected
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                Index.shared.rebuild(); Index.shared.watch()
            }
        }
        buildStatusItem()
    }

    /// The Carbon handler is installed once; only the hotkey registration is swapped.
    func installHotKeyHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            (NSApp.delegate as? AppDelegate)?.launcher.toggle()   // already on the main thread
            return noErr
        }, 1, &spec, nil, nil)
    }

    func applyHotKey() {
        if let old = hotKeyRef { UnregisterEventHotKey(old); hotKeyRef = nil }
        let s = Settings.shared
        if s.isRecordingHotkey { return }
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(s.hotkeyKeyCode, s.hotkeyModifiers, EventHotKeyID(signature: 0x424C4E4B, id: 1),
                                     GetApplicationEventTarget(), 0, &ref)
        hotKeyRef = st == noErr ? ref : nil
        s.hotkeyStatus = st
    }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let mark = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in        // the block caret
            NSColor.black.setFill(); NSRect(x: 5.5, y: 2.5, width: 7, height: 13).fill(); return true
        }
        mark.isTemplate = true
        statusItem.button?.image = mark
        let m = NSMenu()
        m.delegate = self
        m.addItem(withTitle: "Show", action: #selector(show), keyEquivalent: "").target = self
        m.addItem(withTitle: "Rebuild Index", action: #selector(rebuild), keyEquivalent: "").target = self
        loginItem = m.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = Settings.shared.launchAtLogin ? .on : .off
        m.addItem(.separator())
        m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = m
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem.state = Settings.shared.launchAtLogin ? .on : .off
    }

    @objc func show() { launcher.show() }
    @objc func rebuild() { Index.shared.rebuild() }
    @objc func toggleLogin() {
        Settings.shared.launchAtLogin.toggle()
        loginItem.state = Settings.shared.launchAtLogin ? .on : .off
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
