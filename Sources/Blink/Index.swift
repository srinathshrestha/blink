import Foundation
import CoreServices

struct Entry {
    let path: String
    let lower: [UInt8]   // lowercased display name, UTF-8
    let kind: UInt8      // 0 = file, 1 = folder, 2 = app
    let mask: UInt32     // letters/digits the name contains (bits 0...26) + kind bit (27 + kind)

    var isApp: Bool { kind == 2 }
    var isDir: Bool { kind == 1 }

    init(path: String, lower: [UInt8], kind: UInt8) {
        self.path = path; self.lower = lower; self.kind = kind
        self.mask = Entry.mask(of: lower) | Entry.kindBit(kind)
    }

    /// Bit stored in `mask` for a kind; a filtered search just adds it to the query mask.
    @inline(__always) static func kindBit(_ k: UInt8) -> UInt32 { 1 << (27 + UInt32(k)) }

    static func mask(of bytes: [UInt8]) -> UInt32 {
        var m: UInt32 = 0
        for b in bytes {
            if b >= 97 && b <= 122 { m |= 1 << UInt32(b - 97) } else if b >= 48 && b <= 57 { m |= 1 << 26 }
        }
        return m
    }
}

struct Hit {
    let path: String
    let name: String
    let isApp: Bool
    let isDir: Bool
    let isProject: Bool
    var calc: String? = nil   // set for calculator/converter rows (what Enter copies)
    var shown: String? = nil
    var label: String? = nil
    var tag: String = "CAL"
}

enum Project {
    static let markers = [".git", "package.json", "Cargo.toml", "go.mod", "pyproject.toml",
                          "requirements.txt", "Package.swift", "pom.xml", "build.gradle",
                          "build.gradle.kts", "CMakeLists.txt", "Makefile", "composer.json",
                          "Gemfile", "deno.json", "mix.exs", "pubspec.yaml", ".zed"]
    static func isProject(_ path: String) -> Bool {
        let fm = FileManager.default
        return markers.contains { fm.fileExists(atPath: path + "/" + $0) }
    }
}

final class Index {
    static let shared = Index()

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var scanning = false
    private var pending = false
    private var generation = 0                 // bumped whenever a full rebuild lands
    private var appPathSet = Set<String>()     // every .app path the app scan saw (listed or deduped)
    private var stream: FSEventStreamRef?

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    // MARK: usage (frecency-lite)
    private var usage: [String: Int] = (UserDefaults.standard.dictionary(forKey: "usage") as? [String: Int]) ?? [:]
    func recordUse(_ path: String) {
        lock.lock(); usage[path, default: 0] += 1; let u = usage; lock.unlock()
        UserDefaults.standard.set(u, forKey: "usage")
    }

    // MARK: scanning
    private static let skipDirs: Set<String> = [
        "node_modules", ".git", "Library", "DerivedData", "Pods", ".build", "build",
        "$RECYCLE.BIN", "System Volume Information", "venv", ".venv", "__pycache__", ".Trash", "target", "dist", ".cache", ".npm", ".cargo"
    ]

    /// Apple Music's library folder is TCC-protected; scanning it triggers a permission prompt.
    private static let musicLibrary = NSHomeDirectory() + "/Music/Music"

    private static var appDirs: [String] {
        ["/Applications", "/System/Applications", "/System/Cryptexes/App/System/Applications",
         NSHomeDirectory() + "/Applications"]
    }

    /// $HOME plus external volumes (not the boot volume).
    static func fileRoots() -> [URL] {
        var roots = [URL(fileURLWithPath: NSHomeDirectory())]
        let vols = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        for v in vols where v.path.hasPrefix("/Volumes/") {
            // skip the boot volume's symlink and the read-only system/data mounts
            let real = v.resolvingSymlinksInPath().path
            if real == "/" || real.hasPrefix("/System/Volumes") { continue }
            roots.append(v)
        }
        return roots
    }

    /// Applications (up to 3 levels deep, e.g. /Applications/Utilities/X.app), one entry per app name.
    private static func scanApps() -> (entries: [Entry], paths: Set<String>) {
        var out: [Entry] = []
        var seenApps = Set<String>()
        var appPaths = Set<String>()
        for dir in appDirs {
            let url = URL(fileURLWithPath: dir)
            guard let en = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: nil,
                options: [.skipsPackageDescendants, .skipsHiddenFiles]) else { continue }
            for case let u as URL in en {
                if en.level > 3 { en.skipDescendants(); continue }
                if u.pathExtension == "app" {
                    let name = u.deletingPathExtension().lastPathComponent
                    appPaths.insert(u.path)
                    if seenApps.insert(name.lowercased()).inserted {
                        out.append(Entry(path: u.path, lower: Array(name.lowercased().utf8), kind: 2))
                    }
                }
            }
        }
        return (out, appPaths)
    }

    /// Files and folders below `root` (not including `root`). `known` paths are skipped (incremental use).
    /// Returns false if it stopped early because `cap` entries were added.
    @discardableResult
    private static func scanTree(_ root: URL, appPaths: Set<String>, known: Set<String>?,
                                 into out: inout [Entry], cap: Int = Int.max) -> Bool {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants, .skipsHiddenFiles]) else { return true }
        var added = 0
        for case let u as URL in en {
            let name = u.lastPathComponent
            let rv = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isDir = rv?.isDirectory ?? false
            if isDir && (skipDirs.contains(name) || u.path == musicLibrary) { en.skipDescendants(); continue }
            let path = u.path
            if name.hasSuffix(".app"), appPaths.contains(path) { continue }   // already listed as an app
            if let k = known, k.contains(path) { continue }
            var kind: UInt8 = isDir ? 1 : 0
            if !isDir, rv?.isSymbolicLink == true {   // a link to a folder counts as a folder
                var d: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &d), d.boolValue { kind = 1 }
            }
            out.append(Entry(path: path, lower: Array(name.lowercased().utf8), kind: kind))
            added += 1
            if added >= cap { return false }
        }
        return true
    }

    func rebuild() {
        lock.lock()
        if scanning { pending = true; lock.unlock(); return }
        scanning = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [self] in
            var out: [Entry] = []
            out.reserveCapacity(400_000)

            // 1. Applications
            let apps = Index.scanApps()
            out.append(contentsOf: apps.entries)

            // 2. Files and folders under $HOME and every external volume
            for root in Index.fileRoots() {
                Index.scanTree(root, appPaths: apps.paths, known: nil, into: &out)
            }

            IconCache.prewarm(apps.entries.lazy.map { $0.path })
            lock.lock()
            entries = out
            appPathSet = apps.paths
            generation += 1
            scanning = false
            let again = pending; pending = false
            lock.unlock()
            if again { rebuild() }
        }
    }

    // MARK: live updates via FSEvents (per-file events, debounced, applied incrementally)
    private let updateQueue = DispatchQueue(label: "blink.index.update", qos: .utility)
    private let streamQueue = DispatchQueue(label: "blink.index.fsevents", qos: .utility)
    private let evLock = NSLock()
    private var evPaths = Set<String>()        // changed tree paths waiting for the debounce
    private var evApps = false                 // something changed in an Applications folder
    private var evFull = false                 // dropped events / must-scan: do one full rebuild
    private var evScheduled = false
    private var evLastFull = Date.distantPast
    private var rootPrefixes: [String] = []    // "<root>/" for each watched file root
    private var appPrefixes: [String] = []     // "/Applications/", "~/Applications/"
    // Only touched on updateQueue: path -> kind for everything in `entries`.
    private var indexed: [String: UInt8]?
    private var indexedGen = -1

    private static let debounce: TimeInterval = 1.5
    private static let maxRemovedDirs = 50
    private static let maxAddedEntries = 300_000

    func watch() {
        if let old = stream { FSEventStreamStop(old); FSEventStreamInvalidate(old); FSEventStreamRelease(old); stream = nil }
        let roots = Index.fileRoots().map { $0.path }
        evLock.lock()
        rootPrefixes = roots.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        appPrefixes = ["/Applications/", NSHomeDirectory() + "/Applications/"]
        evLock.unlock()

        var ctx = FSEventStreamContext()
        let cb: FSEventStreamCallback = { _, _, n, paths, flags, _ in
            let list = unsafeBitCast(paths, to: NSArray.self)
            Index.shared.ingest(list, flags, n)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        stream = FSEventStreamCreate(nil, cb, &ctx, (roots + ["/Applications"]) as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags)
        if let s = stream {
            FSEventStreamSetDispatchQueue(s, streamQueue)
            FSEventStreamStart(s)
        }
    }

    /// FSEvents callback: keep only create/remove/rename events that could matter, then debounce.
    fileprivate func ingest(_ list: NSArray, _ flags: UnsafePointer<FSEventStreamEventFlags>, _ n: Int) {
        let drop = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                          | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped)
        let structural = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                                | kFSEventStreamEventFlagItemRenamed)
        evLock.lock()
        let roots = rootPrefixes, appDirs = appPrefixes
        evLock.unlock()

        var tree: [String] = []
        var apps = false, full = false
        for i in 0..<min(n, list.count) {
            let f = flags[i]
            if f & drop != 0 { full = true; continue }
            if f & structural == 0 { continue }
            guard let p = list[i] as? String else { continue }
            let c = Index.classify(p, roots: roots, appDirs: appDirs)
            if c.tree { tree.append(p) }
            if c.app { apps = true }
        }
        if tree.isEmpty && !apps && !full { return }

        evLock.lock()
        evPaths.formUnion(tree)
        if apps { evApps = true }
        if full { evFull = true }
        let schedule = !evScheduled
        evScheduled = true
        evLock.unlock()
        if schedule { updateQueue.asyncAfter(deadline: .now() + Index.debounce) { [self] in flush() } }
    }

    /// Does this event path concern the file index (`tree`) and/or the app list (`app`)?
    private static func classify(_ p: String, roots: [String], appDirs: [String]) -> (tree: Bool, app: Bool) {
        var app = false
        for d in appDirs where p.hasPrefix(d) {
            // ignore everything inside a bundle (updates touch thousands of files)
            if p.dropFirst(d.count).range(of: ".app/") == nil { app = true }
        }
        for r in roots where p.hasPrefix(r) {
            if p == musicLibrary || p.hasPrefix(musicLibrary + "/") { break }
            let comps = p.dropFirst(r.count).split(separator: "/")
            if comps.isEmpty { break }
            var ok = true
            for (i, c) in comps.enumerated() {
                if c.first == "." { ok = false; break }                              // dotfiles, as the scan
                if i < comps.count - 1, skipDirs.contains(String(c)) { ok = false; break }
            }
            return (ok, app)
        }
        return (false, app)
    }

    private func flush() {
        evLock.lock()
        var paths = evPaths; evPaths = []
        var apps = evApps; evApps = false
        var full = evFull; evFull = false
        evScheduled = false
        let sinceFull = Date().timeIntervalSince(evLastFull)
        if full && sinceFull < 30 {
            // a storm of dropped events: don't rescan the disk more than every 30 s
            evFull = true; evScheduled = true
            evLock.unlock()
            updateQueue.asyncAfter(deadline: .now() + (30 - sinceFull)) { [self] in flush() }
            full = false
            if paths.isEmpty && !apps { return }
            // fall through to apply what we have; the full rescan will follow
        } else {
            if full { evLastFull = Date() }
            evLock.unlock()
        }
        if full { rebuild(); return }
        if paths.isEmpty && !apps { return }
        applyChanges(&paths, &apps)
    }

    private func requeue(_ paths: Set<String>, _ apps: Bool) {
        evLock.lock()
        evPaths.formUnion(paths); if apps { evApps = true }
        let schedule = !evScheduled
        evScheduled = true
        evLock.unlock()
        if schedule { updateQueue.asyncAfter(deadline: .now() + Index.debounce) { [self] in flush() } }
    }

    private func applyChanges(_ paths: inout Set<String>, _ apps: inout Bool) {
        lock.lock()
        if scanning { pending = true; lock.unlock(); return }   // the running scan + one more will cover it
        let snap = entries, gen = generation
        var appSet = appPathSet
        lock.unlock()

        if indexed == nil || indexedGen != gen {
            var d = [String: UInt8](minimumCapacity: snap.count)
            for e in snap { d[e.path] = e.kind }
            indexed = d; indexedGen = gen
        }
        var idx = indexed!
        indexed = nil   // we own the only reference; restored on success

        // 1. app list: cheap (a few hundred items), so just re-scan the Applications folders
        var base = snap
        var newApps: [Entry] = []
        var appsChanged = false
        if apps {
            let r = Index.scanApps()
            newApps = r.entries
            let oldApps = snap.lazy.filter { $0.kind == 2 }
            let oldPaths = Set(oldApps.map { $0.path })
            let newPaths = Set(newApps.map { $0.path })
            if oldPaths != newPaths || r.paths != appSet {
                appsChanged = true
                for p in oldPaths { idx.removeValue(forKey: p) }
                for e in newApps { idx[e.path] = 2 }
                var nb = newApps
                nb.reserveCapacity(snap.count)
                for e in snap where e.kind != 2 {
                    if r.paths.contains(e.path) { idx.removeValue(forKey: e.path); continue }
                    nb.append(e)
                }
                base = nb
                appSet = r.paths
            }
        }

        // 2. files and folders
        let fm = FileManager.default
        var removedPaths = Set<String>()
        var removedDirs: [String] = []
        var added: [Entry] = []
        var pkgCache: [String: Bool] = [:]
        evLock.lock(); let roots = rootPrefixes; evLock.unlock()

        func isPackage(_ p: String) -> Bool {
            if let c = pkgCache[p] { return c }
            let v = (try? URL(fileURLWithPath: p).resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
            pkgCache[p] = v
            return v
        }
        func insidePackage(_ p: String, _ rootPrefix: String) -> Bool {
            var cur = p
            while let slash = cur.lastIndex(of: "/") {
                cur = String(cur[cur.startIndex..<slash])
                if cur.count < rootPrefix.count { break }
                let last = cur[cur.index(after: cur.lastIndex(of: "/") ?? cur.startIndex)...]
                if last.contains("."), isPackage(cur) { return true }
            }
            return false
        }

        var overflow = false
        for p in paths {
            var st = stat()
            if lstat(p, &st) != 0 {
                if let k = idx[p] {
                    removedPaths.insert(p)
                    if k == 1 { removedDirs.append(p + "/") }
                }
                continue
            }
            if idx[p] != nil { continue }                       // already indexed
            guard let rootPrefix = roots.first(where: { p.hasPrefix($0) }) else { continue }
            let name = (p as NSString).lastPathComponent
            let fmt = st.st_mode & S_IFMT
            let isDir = fmt == S_IFDIR
            var kind: UInt8 = isDir ? 1 : 0
            if fmt == S_IFLNK {
                var d: ObjCBool = false
                if fm.fileExists(atPath: p, isDirectory: &d), d.boolValue { kind = 1 }
            }
            if isDir && Index.skipDirs.contains(name) { continue }
            if st.st_flags & UInt32(UF_HIDDEN) != 0 { continue }
            if name.hasSuffix(".app"), appSet.contains(p) { continue }
            if insidePackage(p, rootPrefix) { continue }
            added.append(Entry(path: p, lower: Array(name.lowercased().utf8), kind: kind))
            idx[p] = kind
            if isDir && !isPackage(p) {
                // a folder appeared (moved in, cloned, unpacked): index what's inside it too
                var sub: [Entry] = []
                let ok = Index.scanTree(URL(fileURLWithPath: p), appPaths: appSet, known: nil, into: &sub,
                                        cap: Index.maxAddedEntries)
                for e in sub where idx[e.path] == nil { added.append(e); idx[e.path] = e.kind }
                if !ok { overflow = true }
            }
            if added.count > Index.maxAddedEntries { overflow = true }
            if overflow { break }
        }
        if overflow || removedDirs.count > Index.maxRemovedDirs { rebuild(); return }   // indexed stays nil

        if !appsChanged && removedPaths.isEmpty && added.isEmpty { indexed = idx; return }

        var result: [Entry]
        if removedPaths.isEmpty {
            result = base
            result.append(contentsOf: added)
        } else {
            result = []
            result.reserveCapacity(base.count + added.count)
            for e in base {
                if removedPaths.contains(e.path)
                    || (!removedDirs.isEmpty && removedDirs.contains(where: { e.path.hasPrefix($0) })) {
                    idx.removeValue(forKey: e.path); continue
                }
                result.append(e)
            }
            result.append(contentsOf: added)
        }

        lock.lock()
        if generation != gen || scanning {
            if scanning { pending = true }
            lock.unlock()
            if generation != gen { requeue(paths, apps) }   // idx is stale: dropped, rebuilt lazily
            return
        }
        entries = result
        appPathSet = appSet
        lock.unlock()
        indexed = idx
        if appsChanged { IconCache.prewarm(newApps.map { $0.path }) }
    }

    // MARK: search
    /// Parses a leading `d:` (folders), `f:` (files) or `a:` (apps) filter. Returns the kind bit to require
    /// in `Entry.mask` (0 = no filter) and the query without the prefix.
    static func parseFilter(_ q: String) -> (kbit: UInt32, rest: String) {
        let u = q.utf8
        guard u.count >= 2 else { return (0, q) }
        let i0 = u.startIndex
        guard u[u.index(after: i0)] == 58 else { return (0, q) }   // ':'
        let kind: UInt8
        switch u[i0] | 0x20 {
        case 100: kind = 1   // d
        case 102: kind = 0   // f
        case 97:  kind = 2   // a
        default: return (0, q)
        }
        var rest = Substring(q).dropFirst(2)
        while rest.first == " " { rest = rest.dropFirst() }
        return (Entry.kindBit(kind), String(rest))
    }

    /// The query with any `d:`/`f:`/`a:` prefix removed (for highlighting).
    static func stripFilter(_ q: String) -> String { parseFilter(q).rest }

    func search(_ query: String, limit: Int = 8) -> [Hit] {
        let (kbit, rest) = Index.parseFilter(query)
        lock.lock(); let snapshot = entries; let use = usage; lock.unlock()
        let q = Array(rest.lowercased().utf8)

        var top: [(Int, Int)] = []   // (score, index) sorted desc
        top.reserveCapacity(limit + 1)

        if q.isEmpty {
            // most-used first
            for (i, e) in snapshot.enumerated() {
                guard let c = use[e.path], e.mask & kbit == kbit else { continue }
                insert(&top, (c, i), limit)
            }
        } else {
            let n = q.count
            let first = q[0]
            let qmask = Entry.mask(of: q) | kbit   // a filter is just one more required bit
            snapshot.withUnsafeBufferPointer { buf in
                for i in 0..<buf.count {
                    if buf[i].mask & qmask != qmask { continue }
                    let e = buf[i]
                    let t = e.lower
                    if t.count < n { continue }
                    guard var s = Index.score(q, n, first, t) else { continue }
                    if e.kind == 2 { s += 60 }
                    if let c = use[e.path] { s += min(c, 20) * 8 }
                    if top.count == limit, s <= top[limit - 1].0 { continue }
                    insert(&top, (s, i), limit)
                }
            }
        }
        return top.map { _, i in
            let e = snapshot[i]
            var name = (e.path as NSString).lastPathComponent
            if e.isApp { name = (name as NSString).deletingPathExtension }
            let dir = e.kind == 1
            return Hit(path: e.path, name: name, isApp: e.isApp, isDir: dir,
                       isProject: dir && Project.isProject(e.path))
        }
    }

    private func insert(_ top: inout [(Int, Int)], _ item: (Int, Int), _ limit: Int) {
        var pos = top.count
        while pos > 0 && top[pos - 1].0 < item.0 { pos -= 1 }
        if pos >= limit { return }
        top.insert(item, at: pos)
        if top.count > limit { top.removeLast() }
    }

    @inline(__always)
    private static func isSep(_ c: UInt8) -> Bool { c == 32 || c == 45 || c == 95 || c == 46 }

    private static func score(_ q: [UInt8], _ n: Int, _ first: UInt8, _ t: [UInt8]) -> Int? {
        let m = t.count
        // contiguous substring match (strongest)
        if m >= n {
            var i = 0
            while i <= m - n {
                if t[i] == first {
                    var j = 1
                    while j < n && t[i + j] == q[j] { j += 1 }
                    if j == n {
                        var s = 200 - m
                        if i == 0 { s += 150 } else if isSep(t[i - 1]) { s += 80 }
                        return s
                    }
                }
                i += 1
            }
        }
        // subsequence fallback
        var qi = 0, s = 0, last = -2
        for i in 0..<m where t[i] == q[qi] {
            var b = 10
            if i == 0 || isSep(t[i - 1]) { b += 20 }
            if last == i - 1 { b += 15 }
            s += b; last = i; qi += 1
            if qi == n { break }
        }
        return qi == n ? s - m : nil
    }

    // MARK: path listing ("~/dev/", "/usr/lo")
    private struct DirItem { let name: String; let lower: [UInt8]; let isDir: Bool }
    private struct DirCache { let path: String; let sec: Int; let nsec: Int; let items: [DirItem] }
    private let dirLock = NSLock()
    private var dirCache: DirCache?
    private static let maxDirEntries = 5000

    /// Lists a directory for path-style input (starts with `/` or `~`). The part after the last `/`
    /// filters and ranks the entries (prefix, then substring, then subsequence; folders first, then A-Z).
    func listDirectory(_ input: String, limit: Int = 8) -> [Hit] {
        guard input.hasPrefix("/") || input == "~" || input.hasPrefix("~/") else { return [] }
        var dirPart: String, fragment: String
        if let slash = input.lastIndex(of: "/") {
            dirPart = String(input[input.startIndex...slash])
            fragment = String(input[input.index(after: slash)...])
        } else {   // bare "~"
            dirPart = "~/"; fragment = ""
        }
        if dirPart.hasPrefix("~") { dirPart = NSHomeDirectory() + dirPart.dropFirst() }
        let dirPath = URL(fileURLWithPath: dirPart).standardizedFileURL.path

        var st = stat()
        guard stat(dirPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return [] }
        let sec = Int(st.st_mtimespec.tv_sec), nsec = Int(st.st_mtimespec.tv_nsec)

        var items: [DirItem]
        dirLock.lock()
        if let c = dirCache, c.path == dirPath, c.sec == sec, c.nsec == nsec { items = c.items; dirLock.unlock() }
        else {
            dirLock.unlock()
            guard let read = Index.readDir(dirPath) else { return [] }
            items = read
            dirLock.lock(); dirCache = DirCache(path: dirPath, sec: sec, nsec: nsec, items: read); dirLock.unlock()
        }

        let f = Array(fragment.lowercased().utf8)
        let showHidden = f.first == 46   // "."
        var top: [(tier: Int, idx: Int)] = []
        top.reserveCapacity(limit + 1)
        func before(_ a: (tier: Int, idx: Int), _ b: (tier: Int, idx: Int)) -> Bool {
            if a.tier != b.tier { return a.tier < b.tier }
            let x = items[a.idx], y = items[b.idx]
            if x.isDir != y.isDir { return x.isDir }
            return x.lower.lexicographicallyPrecedes(y.lower)
        }
        for i in 0..<items.count {
            let t = items[i].lower
            if !showHidden, t.first == 46 { continue }
            var tier = 0
            if !f.isEmpty {
                if t.count < f.count { continue }
                if t.starts(with: f) { tier = 0 }
                else if Index.contains(t, f) { tier = 1 }
                else if Index.isSubsequence(f, t) { tier = 2 }
                else { continue }
            }
            let cand = (tier: tier, idx: i)
            if top.count == limit, !before(cand, top[limit - 1]) { continue }
            var pos = top.count
            while pos > 0 && before(cand, top[pos - 1]) { pos -= 1 }
            top.insert(cand, at: pos)
            if top.count > limit { top.removeLast() }
        }
        return top.map { _, i in
            let it = items[i]
            let path = dirPath == "/" ? "/" + it.name : dirPath + "/" + it.name
            let app = it.isDir && it.name.hasSuffix(".app")
            let name = app ? (it.name as NSString).deletingPathExtension : it.name
            return Hit(path: path, name: name, isApp: app, isDir: it.isDir,
                       isProject: it.isDir && !app && Project.isProject(path))
        }
    }

    private static func contains(_ t: [UInt8], _ f: [UInt8]) -> Bool {
        let n = f.count, m = t.count
        if n > m { return false }
        let first = f[0]
        var i = 0
        while i <= m - n {
            if t[i] == first {
                var j = 1
                while j < n && t[i + j] == f[j] { j += 1 }
                if j == n { return true }
            }
            i += 1
        }
        return false
    }

    private static func isSubsequence(_ f: [UInt8], _ t: [UInt8]) -> Bool {
        var qi = 0
        for b in t where b == f[qi] { qi += 1; if qi == f.count { return true } }
        return false
    }

    /// readdir with a cap; folders are told apart by d_type (links are resolved with one stat each).
    private static func readDir(_ path: String) -> [DirItem]? {
        guard let d = opendir(path) else { return nil }
        defer { closedir(d) }
        var out: [DirItem] = []
        while out.count < maxDirEntries, let ent = readdir(d) {
            let len = Int(ent.pointee.d_namlen)
            let name: String = withUnsafePointer(to: &ent.pointee.d_name) {
                $0.withMemoryRebound(to: UInt8.self, capacity: len) {
                    String(decoding: UnsafeBufferPointer(start: $0, count: len), as: UTF8.self)
                }
            }
            if name == "." || name == ".." { continue }
            var isDir = ent.pointee.d_type == UInt8(DT_DIR)
            if ent.pointee.d_type == UInt8(DT_LNK) || ent.pointee.d_type == UInt8(DT_UNKNOWN) {
                var st = stat()
                if stat(path + "/" + name, &st) == 0 { isDir = (st.st_mode & S_IFMT) == S_IFDIR }
            }
            out.append(DirItem(name: name, lower: Array(name.lowercased().utf8), isDir: isDir))
        }
        return out
    }
}
