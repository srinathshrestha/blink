import Foundation

/// One calculator/converter result row shown at the top of Blink.
struct CalcRow {
    let copy: String      // what Enter copies (plain, no thousands commas)
    let shown: String     // big text in the row
    let label: String     // small line under it
    let tag: String       // 3-letter pill: CAL or CNV
}

enum Calc {
    // ───────────────────────────── entry ─────────────────────────────
    static func rows(_ input: String) -> [CalcRow] {
        let orig = input.trimmingCharacters(in: .whitespaces)
        let s = orig.lowercased()
        if s.isEmpty { return [] }

        if let r = charRows(orig, s) { return r }
        if let r = bracketRows(s) { return r }
        if let r = limitRows(s) { return r }
        if let r = ipRows(s) { return r }
        if let r = colorRows(s) { return r }
        if let r = epochRows(s) { return r }
        if let r = transferRows(s) { return r }

        // "<x> to <y>"
        if let (lhs, rhs) = splitConversion(s) {
            if let r = twosComplementRows(lhs, rhs) { return r }
            if let r = asTypeRows(lhs, rhs) { return r }
            if let base = baseName(rhs) {
                if let v = intValue(lhs) {
                    let out = formatBase(v, base)
                    return [CalcRow(copy: out, shown: out, label: "\(lhs) → \(rhs)", tag: "CNV")]
                }
                return []
            }
            if let from = quantity(lhs) { return convert(from, rhs) }
            if let r = exprTo(lhs, rhs) { return r }
            return []
        }

        // bare literal in another base: 0xff, 1010 bin
        if let lit = parseLiteral(s), lit.explicit {
            var out: [CalcRow] = []
            for b in [10, 16, 2, 8] where b != lit.base {
                let t = formatBase(lit.value, b)
                out.append(CalcRow(copy: t, shown: b == 10 ? group(t) : t, label: "\(s) in \(baseLabel(b))", tag: "CNV"))
            }
            return out
        }

        // units inside a calculation take the same path whichever side they are on
        if s.contains(where: { "*/+-^()×÷".contains($0) }), let r = sizeExprRows(s) {
            // a lone time/rate quantity ("2*30 min", "-5 h", "100 kb/s") keeps its dedicated rows
            if let q = quantity(s) {
                switch q { case .data: break; default: return bare(q) }
            }
            return r
        }

        // bare quantity: "5 gb", "1.5h", "100 mbps"
        if let q = quantity(s) { return bare(q) }

        // "bits 1000000", "popcnt 255"
        var expr = s
        for (w, f) in [("bits ", "bits"), ("popcnt ", "popcnt"), ("popcount ", "popcnt")] where s.hasPrefix(w) {
            expr = f + "(" + s.dropFirst(w.count) + ")"
        }

        if let r = sizeExprRows(expr) { return r }

        // plain math
        var p = Parser(Array(expr))
        guard let v = p.parseAll(), p.nontrivial, v.isFinite else { return [] }
        var out = [CalcRow(copy: format(v), shown: fmtG(v), label: "= " + s, tag: "CAL")]
        out += humanSize(v)
        if p.usedBase, v == v.rounded(), v >= 0, v < 9e18 {
            for b in [16, 2] {
                let t = formatBase(Int64(v), b)
                out.append(CalcRow(copy: t, shown: t, label: "\(fmtG(v)) in \(baseLabel(b))", tag: "CNV"))
            }
        }
        return out
    }

    // ───────────────────────────── formatting ─────────────────────────────
    static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 9e15 { return String(Int64(v)) }
        if v != 0, abs(v) < 1e-4 || abs(v) >= 9e15 { return String(format: "%.6g", v) }
        var t = String(format: "%.8f", v)
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    /// 3999999996 → 3,999,999,996 (plain decimals only; anything else is returned unchanged)
    static func group(_ t: String) -> String {
        var neg = false
        var body = Substring(t)
        if body.hasPrefix("-") { neg = true; body = body.dropFirst() }
        let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let ip = parts.first, !ip.isEmpty, ip.allSatisfy({ $0.isASCII && $0.isNumber }),
              parts.count == 1 || parts[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { return t }
        var rev = ""
        for (n, ch) in ip.reversed().enumerated() {
            if n > 0 && n % 3 == 0 { rev.append(",") }
            rev.append(ch)
        }
        return (neg ? "-" : "") + String(rev.reversed()) + (parts.count == 2 ? "." + parts[1] : "")
    }
    static func fmtG(_ v: Double) -> String { group(format(v)) }

    static func humanDuration(_ secs: Double) -> String {
        var t = Int64(secs.rounded())
        if t <= 0 { return "0 s" }
        let d = t / 86400; t %= 86400
        let h = t / 3600; t %= 3600
        let m = t / 60, s = t % 60
        var parts: [String] = []
        if d > 0 { parts.append("\(d)d") }
        if h > 0 { parts.append("\(h)h") }
        if m > 0 { parts.append("\(m)m") }
        if s > 0 { parts.append("\(s)s") }
        return parts.joined(separator: " ")
    }

    // ───────────────────────────── auto-scaled byte size ─────────────────────────────
    static func humanSize(_ v: Double) -> [CalcRow] {
        guard v >= 1e6, v < 1e18 else { return [] }
        func trim(_ x: Double) -> String {
            var t = String(format: "%.2f", x)
            while t.hasSuffix("0") { t.removeLast() }
            if t.hasSuffix(".") { t.removeLast() }
            return t
        }
        let si = ["KB", "MB", "GB", "TB", "PB"], bi = ["KiB", "MiB", "GiB", "TiB", "PiB"]
        func pick(_ base: Double, _ names: [String]) -> (Double, String) {
            var idx = 0
            while idx + 1 < names.count, v >= pow(base, Double(idx + 2)) { idx += 1 }
            var val = v / pow(base, Double(idx + 1))
            if idx + 1 < names.count, (val * 100).rounded() / 100 >= base { idx += 1; val = v / pow(base, Double(idx + 1)) }
            return (val, names[idx])
        }
        let (a, an) = pick(1000, si), (b, bn) = pick(1024, bi)
        let n = fmtG(v)
        return [
            CalcRow(copy: trim(a), shown: "\(group(trim(a))) \(an)", label: "\(n) bytes · 1000-based", tag: "CNV"),
            CalcRow(copy: trim(b), shown: "\(group(trim(b))) \(bn)", label: "\(n) bytes · 1024-based", tag: "CNV"),
        ]
    }

    // ───────────────────────────── expressions with units ─────────────────────────────
    enum SizeExpr { case bytes(si: Double, bin: Double), ratio(Double), time(Double), rate(Double) }

    /// "2.2gb * 0.6", "1 gb + 500 mb", "1.5h * 2", "100 mbps * 2", "5 gb / 100 mbps".
    /// Values are kept as bytes, seconds, and bytes/second. The expression is evaluated again with all
    /// data units doubled and again with all time units doubled (a rate unit scales as data/time). The
    /// two growth factors, each 2^-1, 2^0 or 2^1, give the dimension of the result:
    /// (0,0) plain ratio, (1,0) size, (0,1) duration, (1,-1) rate. Anything else is meaningless.
    static func sizeExpr(_ s: String) -> SizeExpr? {
        var kinds = 0
        func run(_ bin: Bool, _ kd: Double, _ kt: Double) -> Double? {
            var p = Parser(Array(s))
            p.allowUnits = true; p.binaryUnits = bin; p.dataScale = kd; p.timeScale = kt
            guard let v = p.parseAll(), v.isFinite, p.usedUnit else { return nil }
            kinds = p.kinds
            return v
        }
        guard let a = run(false, 1, 1) else { return nil }
        if a == 0 {                                       // no growth to measure: go by the units used
            switch kinds {
            case 1: return .bytes(si: 0, bin: 0)
            case 2: return .time(0)
            case 4: return .rate(0)
            default: return nil
            }
        }
        guard let d = run(false, 2, 1), let t = run(false, 1, 2) else { return nil }
        func exponent(_ x: Double) -> Int? {
            for e in [0, 1, -1] where abs(x - a * pow(2, Double(e))) <= 1e-9 * abs(a) { return e }
            return nil
        }
        guard let ed = exponent(d), let et = exponent(t) else { return nil }
        switch (ed, et) {
        case (0, 0): return .ratio(a)
        case (1, 0):
            guard let bin = run(true, 1, 1) else { return nil }
            return .bytes(si: a, bin: bin)
        case (0, 1): return .time(a)
        case (1, -1): return .rate(a)
        default: return nil
        }
    }

    static func scaledRows(_ v: Double, _ base: Double, _ names: [String], _ label: String) -> CalcRow {
        var idx = -1, val = v
        while idx + 1 < names.count, abs(val) >= base { val /= base; idx += 1 }
        let rounded = (val * 100).rounded() / 100
        return CalcRow(copy: format(rounded), shown: "\(fmtG(rounded)) \(idx < 0 ? "bytes" : names[idx])", label: label, tag: "CNV")
    }

    static func sizeExprRows(_ s: String) -> [CalcRow]? {
        guard let e = sizeExpr(s) else { return nil }
        var seen = Set<String>()
        switch e {
        case .ratio(let r): return [CalcRow(copy: format(r), shown: fmtG(r), label: "= " + s, tag: "CAL")]
        case .bytes(let si, let bin):
            let all = [scaledRows(si, 1000, ["KB", "MB", "GB", "TB", "PB"], "\(s) · 1000-based"),
                       scaledRows(bin, 1024, ["KiB", "MiB", "GiB", "TiB", "PiB"], "\(s) · 1024-based"),
                       CalcRow(copy: format(si), shown: "\(fmtG(si)) bytes", label: "\(s) · 1000-based", tag: "CNV")]
            return all.filter { seen.insert($0.shown).inserted }
        case .time(let sec): return durationRows(sec, s).filter { seen.insert($0.shown).inserted }
        case .rate(let bps): return rateRows(bps, s).filter { seen.insert($0.shown).inserted }
        }
    }

    static func round2(_ x: Double) -> Double {
        let r = (x * 100).rounded() / 100
        return r == 0 && x != 0 ? x : r
    }

    /// A duration in seconds as: the best-fitting unit, "2h 30m", and plain seconds.
    static func durationRows(_ sec: Double, _ s: String) -> [CalcRow] {
        let a = abs(sec)
        let (div, name): (Double, String) =
            a >= 86400 ? (86400, "d") : a >= 3600 ? (3600, "h") : a >= 60 ? (60, "min") : (a >= 1 || a == 0) ? (1, "s")
            : a >= 1e-3 ? (1e-3, "ms") : a >= 1e-6 ? (1e-6, "µs") : (1e-9, "ns")
        let v = round2(sec / div)
        let best = CalcRow(copy: format(v), shown: "\(fmtG(v)) \(name)", label: "= " + s, tag: "CNV")
        var out = [best]
        if a >= 60 {
            let h = (sec < 0 ? "-" : "") + humanDuration(a)
            let human = CalcRow(copy: h, shown: h, label: "\(s) · as d h m s", tag: "CNV")
            if h.contains(" ") { out.insert(human, at: 0) } else { out.append(human) }
        }
        if a >= 60 {
            let r = round2(sec)
            out.append(CalcRow(copy: format(sec), shown: "\(fmtG(r)) s", label: "\(s) · seconds", tag: "CNV"))
        }
        return out
    }

    /// A rate in bytes/second as bits per second and as bytes per second (the family used in the input first).
    static func rateRows(_ byteRate: Double, _ s: String) -> [CalcRow] {
        func row(_ v: Double, _ names: [String], _ label: String) -> CalcRow {
            var idx = 0, val = v
            while idx + 1 < names.count, abs(val) >= 1000 { val /= 1000; idx += 1 }
            let r = round2(val)
            return CalcRow(copy: format(r), shown: "\(fmtG(r)) \(names[idx])", label: label, tag: "CNV")
        }
        let bits = row(byteRate * 8, ["bps", "Kbps", "Mbps", "Gbps", "Tbps"], "\(s) · bits per second")
        let bytes = row(byteRate, ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"], "\(s) · bytes per second")
        return (s.contains("b/s") || s.contains("byte/s")) ? [bytes, bits] : [bits, bytes]
    }

    /// "2.2gb * 0.6 to mb", "10 min * 6 to h", "100 mbps * 2 to mb/s"
    static func exprTo(_ s: String, _ rhs: String) -> [CalcRow]? {
        if let to = unit(rhs) { return sizeExprTo(s, to) }
        if let tt = timeUnits[rhs] {
            guard case .time(let sec)? = sizeExpr(s) else { return nil }
            let v = sec / tt.sec
            return [CalcRow(copy: format(v), shown: "\(fmtG(v)) \(tt.name)", label: "\(s) → \(tt.name)", tag: "CNV")]
        }
        if let ru = rateUnits[rhs] {
            guard case .rate(let br)? = sizeExpr(s) else { return nil }
            let v = br * 8 / ru.bps
            return [CalcRow(copy: format(v), shown: "\(fmtG(v)) \(ru.name)", label: "\(s) → \(ru.name)", tag: "CNV")]
        }
        return nil
    }

    /// "2.2gb * 0.6 to mb", "2.2gb * 0.6 [MB]"
    static func sizeExprTo(_ s: String, _ to: Unit) -> [CalcRow]? {
        guard case .bytes(let si, let bin)? = sizeExpr(s) else { return nil }
        let head = "\(s) → \(to.name)"
        let a = si / to.si, b = bin / to.bin
        var out = [CalcRow(copy: format(a), shown: "\(fmtG(a)) \(to.name)", label: head + " · 1000-based", tag: "CNV")]
        if abs(a - b) > 1e-12 * abs(a) {
            out.append(CalcRow(copy: format(b), shown: "\(fmtG(b)) \(to.name)", label: head + " · 1024-based", tag: "CNV"))
        }
        return out
    }

    // ───────────────────────────── bases ─────────────────────────────
    static func baseName(_ s: String) -> Int? {
        switch s {
        case "hex", "hexadecimal": return 16
        case "bin", "binary": return 2
        case "oct", "octal": return 8
        case "dec", "decimal": return 10
        default: return nil
        }
    }
    static func baseLabel(_ b: Int) -> String { b == 16 ? "hex" : (b == 2 ? "binary" : (b == 8 ? "octal" : "decimal")) }

    static func formatBase(_ v: Int64, _ base: Int) -> String {
        let body = String(v.magnitude, radix: base, uppercase: true)
        let prefix = base == 16 ? "0x" : (base == 2 ? "0b" : (base == 8 ? "0o" : ""))
        return (v < 0 ? "-" : "") + prefix + body
    }

    struct Literal { let value: Int64; let base: Int; let explicit: Bool }

    static func parseLiteral(_ t0: String) -> Literal? {
        var t = t0.trimmingCharacters(in: .whitespaces)
        var neg = false
        if t.hasPrefix("-") { neg = true; t.removeFirst(); t = t.trimmingCharacters(in: .whitespaces) }
        var base = 10, explicit = false
        if t.count > 2, t.hasPrefix("0x") { base = 16; explicit = true; t.removeFirst(2) }
        else if t.count > 2, t.hasPrefix("0b") { base = 2; explicit = true; t.removeFirst(2) }
        else if t.count > 2, t.hasPrefix("0o") { base = 8; explicit = true; t.removeFirst(2) }
        else if let sp = t.lastIndex(of: " "), let b = baseName(String(t[t.index(after: sp)...])) {
            base = b; explicit = true; t = String(t[..<sp]).trimmingCharacters(in: .whitespaces)
        }
        t = t.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "_", with: "")
        guard !t.isEmpty, let m = Int64(t, radix: base) else { return nil }
        return Literal(value: neg ? -m : m, base: base, explicit: explicit)
    }

    static func intValue(_ s: String) -> Int64? {
        if let l = parseLiteral(s) { return l.value }
        var p = Parser(Array(s))
        if let v = p.parseAll(), v.isFinite, v == v.rounded(), abs(v) < 9e18 { return Int64(v) }
        return nil
    }

    static func rawValue(_ s: String) -> Double? {
        var p = Parser(Array(s))
        if let v = p.parseAll(), v.isFinite { return v }
        return nil
    }

    static func splitConversion(_ s: String) -> (String, String)? {
        var best: Range<String.Index>? = nil
        for k in [" to ", " in ", " -> ", " as ", " → "] {
            if let r = s.range(of: k), best == nil || r.lowerBound < best!.lowerBound { best = r }
        }
        guard let r = best else { return nil }
        let l = s[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
        let rr = s[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return l.isEmpty || rr.isEmpty ? nil : (l, rr)
    }

    // ───────────────────────────── integer types ─────────────────────────────
    struct IntType { let bits: Int; let signed: Bool; let name: String }

    /// Reduces any spelling of a C base type to one name: "unsigned long long int" → "unsigned long long".
    static func canonicalC(_ words: [String]) -> String? {
        let w = words.filter { $0 != "const" && $0 != "volatile" }
        guard !w.isEmpty, w.allSatisfy({ typeWords.contains($0) }) else { return nil }
        let uns = w.contains("unsigned")
        let longs = w.filter { $0 == "long" }.count
        if w.contains("float") { return "float" }
        if w.contains("double") { return longs > 0 ? "long double" : "double" }
        if w.contains("char") { return uns ? "unsigned char" : "char" }
        if w.contains("short") { return uns ? "unsigned short" : "short" }
        if longs >= 2 { return uns ? "unsigned long long" : "long long" }
        if longs == 1 { return uns ? "unsigned long" : "long" }
        return uns ? "unsigned int" : "int"
    }
    static let typeWords: Set<String> = ["signed", "unsigned", "short", "long", "int", "char", "double", "float", "const", "volatile"]

    static func normalizeType(_ raw: String) -> String {
        var n = raw.trimmingCharacters(in: .whitespaces)
        if n == "std::byte" { return "uint8" }
        if n.hasPrefix("std::") { n.removeFirst(5) }
        if let c = canonicalC(n.split(separator: " ").map(String.init)) { return c }
        return n
    }

    /// Sizes follow 64-bit macOS/Linux (LP64). char is signed, wchar_t is 32-bit.
    static func typeInfo(_ raw: String) -> IntType? {
        func t(_ b: Int, _ sgn: Bool) -> IntType { IntType(bits: b, signed: sgn, name: (sgn ? "int" : "uint") + "\(b)") }
        let n = normalizeType(raw)
        for b in [8, 16, 32, 64] {
            let forms = ["int\(b)", "int\(b)_t", "i\(b)", "int_least\(b)_t", "int_fast\(b)_t"]
            let uforms = ["uint\(b)", "uint\(b)_t", "u\(b)", "uint_least\(b)_t", "uint_fast\(b)_t"]
            if forms.contains(n) { return t(b, true) }
            if uforms.contains(n) { return t(b, false) }
        }
        switch n {
        case "char", "schar": return t(8, true)
        case "unsigned char", "uchar", "char8_t": return t(8, false)
        case "short": return t(16, true)
        case "unsigned short", "ushort", "char16_t": return t(16, false)
        case "int", "wchar_t", "pid_t": return t(32, true)
        case "unsigned int", "uint", "char32_t": return t(32, false)
        case "long", "long long", "isize", "ssize_t", "ptrdiff_t", "intptr_t", "intmax_t", "time_t", "off_t": return t(64, true)
        case "unsigned long", "unsigned long long", "ulong", "usize", "size_t", "uintptr_t", "uintmax_t": return t(64, false)
        default: return nil
        }
    }

    /// Bytes for a type name used in an expression ("int * 1000"). std:: sizes are libc++ (macOS).
    static let otherSizes: [String: Double] = [
        "bool": 1, "_bool": 1, "float": 4, "double": 8, "long double": 8, "float_t": 4, "double_t": 8, "f32": 4, "f64": 8,
        "ptr": 8, "pointer": 8, "nullptr_t": 8, "clock_t": 8, "__int128": 16, "__uint128_t": 16, "__int128_t": 16,
        "string": 24, "string_view": 16, "vector": 24, "unique_ptr": 8, "shared_ptr": 16, "weak_ptr": 16,
    ]
    static func sizeOf(_ raw: String) -> Double? {
        if let t = typeInfo(raw) { return Double(t.bits / 8) }
        return otherSizes[normalizeType(raw)]
    }

    /// "float max", "double min", "double epsilon"
    static func floatLimitRows(_ kind: String, _ tname: String) -> [CalcRow]? {
        let n = normalizeType(tname)
        var vals: (max: String, min: String, eps: String)
        switch n {
        case "float", "float_t", "f32": vals = ("3.4028235e+38", "1.1754944e-38", "1.1920929e-07")
        case "double", "double_t", "f64": vals = ("1.7976931348623157e+308", "2.2250738585072014e-308", "2.220446049250313e-16")
        default: return nil
        }
        func row(_ v: String, _ l: String) -> CalcRow { CalcRow(copy: v, shown: v, label: "\(n) \(l)", tag: "CNV") }
        switch kind {
        case "max": return [row(vals.max, "max")]
        case "min": return [row(vals.min, "smallest positive normal")]
        case "epsilon", "eps": return [row(vals.eps, "epsilon")]
        default: return [row(vals.max, "max"), row(vals.min, "smallest positive normal"), row(vals.eps, "epsilon")]
        }
    }

    static func mask(_ bits: Int) -> UInt64 { bits >= 64 ? UInt64.max : (UInt64(1) << UInt64(bits)) - 1 }

    /// "int32 max", "uint8 min", "long long range"
    static func limitRows(_ s: String) -> [CalcRow]? {
        let w = s.split(separator: " ").map(String.init)
        guard w.count >= 2 else { return nil }
        var kind = "", tname = ""
        if ["max", "min", "range", "limit", "limits", "epsilon", "eps"].contains(w.last!) { kind = w.last!; tname = w.dropLast().joined(separator: " ") }
        else if ["max", "min"].contains(w[0]) { kind = w[0]; tname = w.dropFirst().joined(separator: " ") }
        else { return nil }
        if let f = floatLimitRows(kind, tname) { return f }
        guard let t = typeInfo(tname) else { return nil }
        let maxU: UInt64 = t.signed ? mask(t.bits - 1) : mask(t.bits)
        let maxS = t.signed ? "\(maxU)" : "\(maxU)"
        let minS = t.signed ? "-" + String(UInt64(1) << UInt64(t.bits - 1)) : "0"
        let minHex = t.signed ? "0x" + String(UInt64(1) << UInt64(t.bits - 1), radix: 16, uppercase: true) : "0x0"
        let maxHex = "0x" + String(maxU, radix: 16, uppercase: true)
        let pow = t.signed ? "2^\(t.bits - 1) − 1" : "2^\(t.bits) − 1"
        let npow = "−2^\(t.bits - 1)"
        func row(_ v: String, _ lab: String) -> CalcRow { CalcRow(copy: v, shown: group(v), label: lab, tag: "CNV") }
        func hex(_ v: String, _ lab: String) -> CalcRow { CalcRow(copy: v, shown: v, label: lab, tag: "CNV") }
        switch kind {
        case "max": return [row(maxS, "\(t.name) max · \(pow)"), hex(maxHex, "\(t.name) max in hex")]
        case "min": return [row(minS, "\(t.name) min · \(t.signed ? npow : "0")"), hex(minHex, "\(t.name) min in hex")]
        default:
            return [CalcRow(copy: "\(minS) … \(maxS)", shown: "\(group(minS)) … \(group(maxS))", label: "\(t.name) range", tag: "CNV"),
                    row(maxS, "\(t.name) max · \(pow)"), row(minS, "\(t.name) min · \(t.signed ? npow : "0")")]
        }
    }

    /// "-1 to hex 8bit", "-5 to bin int8"
    static func twosComplementRows(_ lhs: String, _ rhs: String) -> [CalcRow]? {
        let parts = rhs.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let base = baseName(parts[0]) else { return nil }
        var width = 0
        var r = parts[1].replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        if r.hasSuffix("bits") { r.removeLast(4) } else if r.hasSuffix("bit") { r.removeLast(3) }
        if let w = Int(r), [8, 16, 32, 64].contains(w) { width = w } else if let t = typeInfo(parts[1]) { width = t.bits }
        guard width > 0 else { return nil }
        guard let v = intValue(lhs) else { return [] }
        let u = UInt64(bitPattern: v) & mask(width)
        var body = String(u, radix: base, uppercase: true)
        if base == 16 { body = String(repeating: "0", count: max(0, width / 4 - body.count)) + body }
        if base == 2 { body = String(repeating: "0", count: max(0, width - body.count)) + body }
        let prefix = base == 16 ? "0x" : (base == 2 ? "0b" : (base == 8 ? "0o" : ""))
        let out = prefix + body
        return [CalcRow(copy: out, shown: base == 10 ? group(out) : out, label: "\(lhs) as \(width)-bit \(baseLabel(base))", tag: "CNV")]
    }

    /// "0xff as int8" → -1,  "-1 as uint8" → 255
    static func asTypeRows(_ lhs: String, _ rhs: String) -> [CalcRow]? {
        guard let t = typeInfo(rhs) else { return nil }
        guard let v = intValue(lhs) else { return [] }
        let m = mask(t.bits)
        let u = UInt64(bitPattern: v) & m
        var dec: String
        if t.signed, u >> UInt64(t.bits - 1) & 1 == 1 { dec = String(Int64(bitPattern: u | ~m)) } else { dec = String(u) }
        let hex = "0x" + String(u, radix: 16, uppercase: true)
        var bin = String(u, radix: 2)
        bin = "0b" + String(repeating: "0", count: max(0, t.bits - bin.count)) + bin
        return [CalcRow(copy: dec, shown: group(dec), label: "\(lhs) as \(t.name)", tag: "CNV"),
                CalcRow(copy: hex, shown: hex, label: "\(t.name) bits in hex", tag: "CNV"),
                CalcRow(copy: bin, shown: bin, label: "\(t.name) bits in binary", tag: "CNV")]
    }

    // ───────────────────────────── characters ─────────────────────────────
    static func charRows(_ orig: String, _ s: String) -> [CalcRow]? {
        // 'A' / "A"  (bare, or "to ascii|hex|bin|oct|dec")
        let chars = Array(orig)
        if chars.count >= 3, chars[0] == "'" || chars[0] == "\"", chars[2] == chars[0] {
            let ch = chars[1]
            guard let sc = String(ch).unicodeScalars.first else { return nil }
            let code = Int64(sc.value)
            let rest = String(orig.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
            var target = ""
            if rest.isEmpty { target = "all" }
            else if let (l, r) = splitConversion("x " + rest), l == "x" { target = r }
            else { return nil }
            func r(_ b: Int, _ name: String) -> CalcRow {
                let t = formatBase(code, b)
                return CalcRow(copy: t, shown: b == 10 ? group(t) : t, label: "'\(ch)' in \(name)", tag: "CNV")
            }
            switch target {
            case "all": return [r(10, "decimal (ASCII/Unicode)"), r(16, "hex"), r(2, "binary")]
            case "ascii", "code", "unicode", "codepoint", "dec", "decimal": return [r(10, "decimal (ASCII/Unicode)"), r(16, "hex")]
            case "hex", "hexadecimal": return [r(16, "hex")]
            case "bin", "binary": return [r(2, "binary")]
            case "oct", "octal": return [r(8, "octal")]
            default: return []
            }
        }
        // 65 → character
        if let (l, r) = splitConversion(s), ["char", "character", "chr", "letter"].contains(r) {
            guard let v = intValue(l), v >= 0, v <= 0x10FFFF, let sc = Unicode.Scalar(UInt32(v)) else { return [] }
            let str = String(Character(sc))
            let shown = v < 32 || v == 127 ? "(control character)" : str
            return [CalcRow(copy: str, shown: shown, label: "\(l) = U+" + String(format: "%04X", Int(v)), tag: "CNV")]
        }
        return nil
    }

    // ───────────────────────────── [unit] suffix ─────────────────────────────
    static func bracketRows(_ s: String) -> [CalcRow]? {
        guard s.hasSuffix("]"), let open = s.lastIndex(of: "[") else { return nil }
        let expr = s[..<open].trimmingCharacters(in: .whitespaces)
        let opt = s[s.index(after: open)..<s.index(before: s.endIndex)].trimmingCharacters(in: .whitespaces)
        if timeUnits[opt] != nil || rateUnits[opt] != nil { return exprTo(expr, opt) ?? [] }
        let target = (opt == "b") ? units["byte"] : unit(opt)
        guard let t = target, !expr.isEmpty else { return [] }
        if let r = sizeExprTo(expr, t) { return r }
        var p = Parser(Array(expr))
        guard let v = p.parseAll(), v.isFinite else { return [] }
        return unitRows(v, units["byte"]!, t)
    }

    // ───────────────────────────── units ─────────────────────────────
    struct Unit { let name: String; let si: Double; let bin: Double; let iec: Bool }
    struct TUnit { let name: String; let sec: Double }
    struct RUnit { let name: String; let bps: Double }

    static let units: [String: Unit] = {
        var m: [String: Unit] = [:]
        func add(_ keys: [String], _ n: String, _ si: Double, _ bin: Double, _ iec: Bool = false) {
            for k in keys { m[k] = Unit(name: n, si: si, bin: bin, iec: iec) }
        }
        add(["bit", "bits"], "bits", 0.125, 0.125)
        add(["byte", "bytes"], "bytes", 1, 1)
        let names: [(String, String, String)] = [("k", "KB", "kilobyte"), ("m", "MB", "megabyte"), ("g", "GB", "gigabyte"),
                                                 ("t", "TB", "terabyte"), ("p", "PB", "petabyte")]
        for (i, n) in names.enumerated() {
            let e = Double(i + 1)
            add([n.0 + "b", n.2, n.2 + "s"], n.1, pow(1000, e), pow(1024, e))
            add([n.0 + "ib"], n.0.uppercased() + "iB", pow(1024, e), pow(1024, e), true)
        }
        return m
    }()

    static let timeUnits: [String: TUnit] = {
        var m: [String: TUnit] = [:]
        func add(_ keys: [String], _ n: String, _ s: Double) { for k in keys { m[k] = TUnit(name: n, sec: s) } }
        add(["ns", "nanosecond", "nanoseconds"], "ns", 1e-9)
        add(["us", "µs", "μs", "microsecond", "microseconds"], "µs", 1e-6)
        add(["ms", "millisecond", "milliseconds"], "ms", 1e-3)
        add(["s", "sec", "secs", "second", "seconds"], "s", 1)
        add(["min", "mins", "minute", "minutes"], "min", 60)
        add(["h", "hr", "hrs", "hour", "hours"], "h", 3600)
        add(["d", "day", "days"], "d", 86400)
        add(["w", "wk", "week", "weeks"], "w", 604800)
        return m
    }()

    static let rateUnits: [String: RUnit] = {
        var m: [String: RUnit] = [:]
        func add(_ keys: [String], _ n: String, _ b: Double) { for k in keys { m[k] = RUnit(name: n, bps: b) } }
        add(["bps", "b/s", "bit/s"], "bps", 1)
        add(["kbps", "kbit/s"], "Kbps", 1e3)
        add(["mbps", "mbit/s"], "Mbps", 1e6)
        add(["gbps", "gbit/s"], "Gbps", 1e9)
        add(["tbps", "tbit/s"], "Tbps", 1e12)
        add(["kb/s", "kbyte/s"], "KB/s", 8e3)
        add(["mb/s", "mbyte/s"], "MB/s", 8e6)
        add(["gb/s", "gbyte/s"], "GB/s", 8e9)
        add(["tb/s"], "TB/s", 8e12)
        add(["kib/s"], "KiB/s", 8 * 1024)
        add(["mib/s"], "MiB/s", 8 * 1024 * 1024)
        add(["gib/s"], "GiB/s", 8 * 1024 * 1024 * 1024)
        return m
    }()

    static func unit(_ s: String) -> Unit? { units[s.trimmingCharacters(in: .whitespaces)] }

    enum Quantity {
        case data(Double, Unit), time(Double, TUnit), rate(Double, RUnit)
    }

    /// "5 gb", "5gb", "2*512 mb", "1.5h", "100 mbps"
    static func quantity(_ s: String) -> Quantity? {
        let t = s.trimmingCharacters(in: .whitespaces)
        var i = t.endIndex
        while i > t.startIndex {
            let ch = t[t.index(before: i)]
            if ch.isLetter || ch == "/" || ch == "µ" { i = t.index(before: i) } else { break }
        }
        guard i < t.endIndex, i > t.startIndex else { return nil }
        let u = String(t[i...])
        let num = t[..<i].trimmingCharacters(in: .whitespaces)
        guard !num.isEmpty, let q = rawValue(num) else { return nil }
        if let d = units[u] { return .data(q, d) }
        if let r = rateUnits[u] { return .rate(q, r) }
        if let tu = timeUnits[u] { return .time(q, tu) }
        return nil
    }

    static func convert(_ from: Quantity, _ rhs: String) -> [CalcRow] {
        switch from {
        case .data(let q, let u): if let to = unit(rhs) { return unitRows(q, u, to) }
        case .time(let q, let u): if let to = timeUnits[rhs] { return timeRows(q, u, to) }
        case .rate(let q, let u):
            if let to = rateUnits[rhs] {
                let v = q * u.bps / to.bps
                return [CalcRow(copy: format(v), shown: "\(fmtG(v)) \(to.name)", label: "\(fmtG(q)) \(u.name) → \(to.name)", tag: "CNV")]
            }
        }
        return []
    }

    static func bare(_ q: Quantity) -> [CalcRow] {
        switch q {
        case .data(let v, let u):
            let target = u.name == "bits" ? units["byte"]! : (u.name == "bytes" ? units["bit"]! : units["byte"]!)
            return unitRows(v, u, target)
        case .time(let v, let u):
            let sec = v * u.sec
            var out: [CalcRow] = []
            if u.name != "s" { out += timeRows(v, u, timeUnits["s"]!).prefix(1) }
            if sec >= 60 { out.append(CalcRow(copy: humanDuration(sec), shown: humanDuration(sec), label: "\(fmtG(v)) \(u.name) as d h m s", tag: "CNV")) }
            return out
        case .rate(let v, let u):
            let target = u.name.contains("/s") ? rateUnits["mbps"]! : rateUnits["mb/s"]!
            return convert(.rate(v, u), target.name.lowercased())
        }
    }

    static func unitRows(_ q: Double, _ from: Unit, _ to: Unit) -> [CalcRow] {
        let si = q * from.si / to.si
        let bin = q * from.bin / to.bin
        let head = "\(fmtG(q)) \(from.name) → \(to.name)"
        let differs = abs(si - bin) > 1e-12 * max(abs(si), 1e-300)
        let anyIEC = from.iec || to.iec
        if differs && !anyIEC {
            let k = from.name.hasSuffix("B") && from.name != "bytes" ? from.name : to.name
            return [
                CalcRow(copy: format(si), shown: "\(fmtG(si)) \(to.name)", label: "\(head) · 1 \(k) = 1000-based", tag: "CNV"),
                CalcRow(copy: format(bin), shown: "\(fmtG(bin)) \(to.name)", label: "\(head) · 1 \(k) = 1024-based", tag: "CNV"),
            ]
        }
        return [CalcRow(copy: format(si), shown: "\(fmtG(si)) \(to.name)", label: head, tag: "CNV")]
    }

    static func timeRows(_ q: Double, _ from: TUnit, _ to: TUnit) -> [CalcRow] {
        let sec = q * from.sec
        let v = sec / to.sec
        var out = [CalcRow(copy: format(v), shown: "\(fmtG(v)) \(to.name)", label: "\(fmtG(q)) \(from.name) → \(to.name)", tag: "CNV")]
        if sec >= 60, to.name != "s" || true {
            out.append(CalcRow(copy: humanDuration(sec), shown: humanDuration(sec), label: "\(fmtG(q)) \(from.name) as d h m s", tag: "CNV"))
        }
        return out
    }

    /// "5 gb at 100 mbps" → download time
    static func transferRows(_ s: String) -> [CalcRow]? {
        var parts: (String, String)? = nil
        for k in [" at ", " @ ", " over ", " on "] {
            if let r = s.range(of: k) {
                parts = (s[..<r.lowerBound].trimmingCharacters(in: .whitespaces), s[r.upperBound...].trimmingCharacters(in: .whitespaces))
                break
            }
        }
        guard let (l, r) = parts, let a = quantity(l), let b = quantity(r) else { return nil }
        guard case .data(let size, let du) = a, case .rate(let rate, let ru) = b, rate > 0 else { return [] }
        let bits = size * du.si * 8
        let secs = bits / (rate * ru.bps)
        let human = secs >= 60 ? humanDuration(secs) : "\(fmtG((secs * 100).rounded() / 100)) s"
        let label = "\(fmtG(size)) \(du.name) at \(fmtG(rate)) \(ru.name)"
        var out = [CalcRow(copy: format(secs), shown: human, label: label, tag: "CNV")]
        if secs >= 60 { out.append(CalcRow(copy: format(secs), shown: "\(fmtG((secs * 100).rounded() / 100)) s", label: "\(label) · seconds", tag: "CNV")) }
        return out
    }

    // ───────────────────────────── epoch / dates ─────────────────────────────
    static func fmt(_ pattern: String, _ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        f.timeZone = tz
        return f
    }

    static func epochRows(_ s: String) -> [CalcRow]? {
        let nowWords: Set<String> = ["unix time", "unixtime", "now to unix", "now to epoch", "now to timestamp", "unix now", "epoch now"]
        if nowWords.contains(s) {
            let t = Date().timeIntervalSince1970
            let sec = String(Int64(t)), ms = String(Int64(t * 1000))
            return [CalcRow(copy: sec, shown: group(sec), label: "unix time now · seconds", tag: "CNV"),
                    CalcRow(copy: ms, shown: group(ms), label: "unix time now · milliseconds", tag: "CNV")]
        }
        guard let (l, r) = splitConversion(s) else { return nil }
        if ["date", "time", "datetime", "utc", "iso", "human"].contains(r) {
            guard l.allSatisfy({ $0.isNumber || $0 == "," }), let n = intValue(l) else { return nil }
            let secs = n >= 100_000_000_000 ? Double(n) / 1000 : Double(n)
            let d = Date(timeIntervalSince1970: secs)
            let local = fmt("yyyy-MM-dd HH:mm:ss zzz (EEE)", .current).string(from: d)
            let utc = fmt("yyyy-MM-dd HH:mm:ss 'UTC'", TimeZone(identifier: "UTC")!).string(from: d)
            let unit = n >= 100_000_000_000 ? "ms" : "s"
            return [CalcRow(copy: local, shown: local, label: "\(l) \(unit) · local time", tag: "CNV"),
                    CalcRow(copy: utc, shown: utc, label: "\(l) \(unit) · UTC", tag: "CNV")]
        }
        if ["unix", "epoch", "timestamp", "seconds", "ms"].contains(r) {
            var str = l, tz = TimeZone.current
            if str.hasSuffix("z") { str.removeLast(); tz = TimeZone(identifier: "UTC")! }
            str = str.replacingOccurrences(of: "t", with: " ").trimmingCharacters(in: .whitespaces)
            guard str.first?.isNumber == true, str.contains("-") else { return nil }
            for p in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
                let f = fmt(p, tz); f.isLenient = false
                if let d = f.date(from: str) {
                    let t = d.timeIntervalSince1970
                    let sec = String(Int64(t)), ms = String(Int64(t * 1000))
                    return [CalcRow(copy: sec, shown: group(sec), label: "\(l) · unix seconds", tag: "CNV"),
                            CalcRow(copy: ms, shown: group(ms), label: "\(l) · unix milliseconds", tag: "CNV")]
                }
            }
            return []
        }
        return nil
    }

    // ───────────────────────────── IPv4 ─────────────────────────────
    static func parseIPv4(_ t: String) -> UInt32? {
        let p = t.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count == 4 else { return nil }
        var v: UInt32 = 0
        for x in p {
            guard !x.isEmpty, x.count <= 3, x.allSatisfy({ $0.isASCII && $0.isNumber }), let n = UInt32(x), n <= 255 else { return nil }
            v = v << 8 | n
        }
        return v
    }
    static func ipString(_ v: UInt32) -> String { "\(v >> 24).\(v >> 16 & 255).\(v >> 8 & 255).\(v & 255)" }

    static func ipRows(_ s: String) -> [CalcRow]? {
        func row(_ copy: String, _ shown: String, _ label: String) -> CalcRow { CalcRow(copy: copy, shown: shown, label: label, tag: "CNV") }
        // CIDR
        var cidr = s
        for suf in [" hosts", " mask", " range", " subnet", " netmask"] where s.hasSuffix(suf) { cidr = String(s.dropLast(suf.count)) }
        if let slash = cidr.firstIndex(of: "/"), let ip = parseIPv4(String(cidr[..<slash])), let p = Int(cidr[cidr.index(after: slash)...]), (0...32).contains(p) {
            let m: UInt32 = p == 0 ? 0 : UInt32.max << UInt32(32 - p)
            let net = ip & m, bc = net | ~m
            let hosts: UInt64 = p == 32 ? 1 : (p == 31 ? 2 : (UInt64(1) << UInt64(32 - p)) - 2)
            let first = p >= 31 ? net : net + 1, last = p >= 31 ? bc : bc - 1
            return [row(String(hosts), "\(group(String(hosts))) \(hosts == 1 ? "host" : "hosts")", "\(ipString(net))/\(p) · usable addresses"),
                    row(ipString(m), ipString(m), "netmask for /\(p)"),
                    row("\(ipString(first)) – \(ipString(last))", "\(ipString(first)) – \(ipString(last))", "usable range"),
                    row(ipString(bc), ipString(bc), "broadcast address")]
        }
        if let ip = parseIPv4(s) {
            let hex = "0x" + String(ip, radix: 16, uppercase: true)
            return [row(String(ip), group(String(ip)), "\(s) as an integer"), row(hex, hex, "\(s) in hex")]
        }
        if let (l, r) = splitConversion(s) {
            if let ip = parseIPv4(l) {
                switch r {
                case "int", "integer", "dec", "decimal", "number": return [row(String(ip), group(String(ip)), "\(l) as an integer")]
                case "hex", "hexadecimal": let h = "0x" + String(ip, radix: 16, uppercase: true); return [row(h, h, "\(l) in hex")]
                case "bin", "binary": let b = "0b" + String(ip, radix: 2); return [row(b, b, "\(l) in binary")]
                default: return nil
                }
            }
            if r == "ip", let v = intValue(l), v >= 0, v <= Int64(UInt32.max) {
                let t = ipString(UInt32(v)); return [row(t, t, "\(l) as an IPv4 address")]
            }
        }
        return nil
    }

    // ───────────────────────────── colors ─────────────────────────────
    static func colorRows(_ s: String) -> [CalcRow]? {
        var lhs = s, rhs = ""
        if let (l, r) = splitConversion(s) { lhs = l; rhs = r }
        var rgb: (Int, Int, Int)? = nil
        if lhs.hasPrefix("#") {
            var h = String(lhs.dropFirst())
            if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
            guard h.count == 6, let n = Int(h, radix: 16) else { return nil }
            rgb = (n >> 16 & 255, n >> 8 & 255, n & 255)
        } else if lhs.hasPrefix("rgb("), lhs.hasSuffix(")") {
            let nums = lhs.dropFirst(4).dropLast().split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard nums.count == 3, nums.allSatisfy({ (0...255).contains($0) }) else { return nil }
            rgb = (nums[0], nums[1], nums[2])
        }
        guard let (r, g, b) = rgb else { return nil }
        let hex = String(format: "#%02X%02X%02X", r, g, b)
        let rgbS = "rgb(\(r), \(g), \(b))"
        let (h, sat, l) = hsl(r, g, b)
        let hslS = "hsl(\(h), \(sat)%, \(l)%)"
        func row(_ v: String, _ lab: String) -> CalcRow { CalcRow(copy: v, shown: v, label: lab, tag: "CNV") }
        switch rhs {
        case "rgb": return [row(rgbS, "\(lhs) as rgb")]
        case "hex": return [row(hex, "\(lhs) as hex")]
        case "hsl": return [row(hslS, "\(lhs) as hsl")]
        case "": return lhs.hasPrefix("#") ? [row(rgbS, "\(lhs) as rgb"), row(hslS, "\(lhs) as hsl")]
                                          : [row(hex, "\(lhs) as hex"), row(hslS, "\(lhs) as hsl")]
        default: return []
        }
    }

    static func hsl(_ r8: Int, _ g8: Int, _ b8: Int) -> (Int, Int, Int) {
        let r = Double(r8) / 255, g = Double(g8) / 255, b = Double(b8) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        let l = (mx + mn) / 2
        if d == 0 { return (0, 0, Int((l * 100).rounded())) }
        let sat = d / (1 - abs(2 * l - 1))
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h *= 60
        return (Int(h.rounded()) % 360, Int((sat * 100).rounded()), Int((l * 100).rounded()))
    }

    // ───────────────────────────── expression parser ─────────────────────────────
    struct Parser {
        let c: [Character]
        var i = 0
        var nontrivial = false
        var usedBase = false
        var groupCommas = true
        var allowUnits = false, binaryUnits = false, usedUnit = false, dataScale = 1.0, timeScale = 1.0
        var kinds = 0                                     // bit 1 data, 2 time, 4 rate unit seen
        init(_ c: [Character]) { self.c = c }

        mutating func ws() { while i < c.count, c[i] == " " { i += 1 } }
        mutating func peek() -> Character? { ws(); return i < c.count ? c[i] : nil }
        mutating func peek2(_ a: Character, _ b: Character) -> Bool {
            ws(); return i + 1 < c.count && c[i] == a && c[i + 1] == b
        }
        mutating func word(_ w: String) -> Bool {
            ws()
            let a = Array(w)
            guard i + a.count <= c.count, Array(c[i..<i + a.count]) == a else { return false }
            if i + a.count < c.count, c[i + a.count].isLetter || c[i + a.count].isNumber { return false }
            i += a.count
            return true
        }
        func operandFollows(_ at: Int) -> Bool {
            var j = at + 1
            while j < c.count, c[j] == " " { j += 1 }
            return j < c.count && (c[j].isASCII && c[j].isNumber || c[j] == "." || c[j] == "(")
        }

        mutating func parseAll() -> Double? {
            guard let v = bitor() else { return nil }
            ws()
            return i == c.count ? v : nil
        }

        func ints(_ a: Double, _ b: Double) -> (Int64, Int64)? {
            guard let x = Int64(exactly: a), let y = Int64(exactly: b) else { return nil }
            return (x, y)
        }

        mutating func bitor() -> Double? {
            guard var v = bitxor() else { return nil }
            while peek() == "|" {
                i += 1
                guard let r = bitxor(), let (a, b) = ints(v, r) else { return nil }
                v = Double(a | b); nontrivial = true; usedBase = true
            }
            return v
        }
        mutating func bitxor() -> Double? {
            guard var v = bitand() else { return nil }
            while word("xor") {
                guard let r = bitand(), let (a, b) = ints(v, r) else { return nil }
                v = Double(a ^ b); nontrivial = true; usedBase = true
            }
            return v
        }
        mutating func bitand() -> Double? {
            guard var v = shift() else { return nil }
            while peek() == "&" {
                i += 1
                guard let r = shift(), let (a, b) = ints(v, r) else { return nil }
                v = Double(a & b); nontrivial = true; usedBase = true
            }
            return v
        }
        mutating func shift() -> Double? {
            guard var v = expr() else { return nil }
            while true {
                let left = peek2("<", "<"), right = !left && peek2(">", ">")
                guard left || right else { break }
                i += 2
                guard let r = expr(), let (a, b) = ints(v, r), b >= 0, b < 63 else { return nil }
                v = Double(left ? a << b : a >> b); nontrivial = true; usedBase = true
            }
            return v
        }

        func termIsPercent(_ from: Int, _ to: Int) -> Bool {
            var e = to
            while e > from, c[e - 1] == " " { e -= 1 }
            guard e > from, c[e - 1] == "%" else { return false }
            let t = String(c[from..<e])
            return !t.contains(where: { "*/×÷x".contains($0) }) && !t.contains("mod")
        }

        mutating func expr() -> Double? {
            guard var v = term() else { return nil }
            while let ch = peek(), ch == "+" || ch == "-" {
                i += 1
                let start = i
                guard var r = term() else { return nil }
                if termIsPercent(start, i) { r = v * r }      // 100 + 15%  = 115
                v = ch == "+" ? v + r : v - r
                nontrivial = true
            }
            return v
        }

        mutating func term() -> Double? {
            guard var v = unary() else { return nil }
            while true {
                ws()
                guard i < c.count else { break }
                let ch = c[i]
                var op: Character? = nil
                var step = 1
                if ch == "*", !(i + 1 < c.count && c[i + 1] == "*") { op = "*" }
                else if ch == "/" || ch == "÷" { op = "/" }
                else if ch == "×" { op = "*" }
                else if ch == "x", !(i + 1 < c.count && (c[i + 1].isLetter)) { op = "*" }
                else if ch == "%", operandFollows(i) { op = "%" }
                else if ch == "m", word("mod") { op = "%"; step = 0 }
                guard let o = op else { break }
                i += step
                guard let r = unary() else { return nil }
                switch o {
                case "/": if r == 0 { return nil }; v /= r
                case "%": if r == 0 { return nil }; v = fmod(v, r)
                default: v *= r
                }
                nontrivial = true
            }
            return v
        }

        mutating func unary() -> Double? {
            if let ch = peek(), ch == "-" || ch == "+" {
                i += 1
                guard let v = unary() else { return nil }
                return ch == "-" ? -v : v
            }
            return power()
        }

        mutating func power() -> Double? {
            guard let base = postfix() else { return nil }
            if peek() == "^" { i += 1 }
            else if peek2("*", "*") { i += 2 }
            else { return base }
            guard let e = unary() else { return nil }
            nontrivial = true
            return pow(base, e)
        }

        mutating func postfix() -> Double? {
            guard var v = primary() else { return nil }
            while true {
                if peek() == "!", !(i + 1 < c.count && c[i + 1] == "=") {
                    i += 1
                    guard v >= 0, v == v.rounded(), v <= 170 else { return nil }
                    var f = 1.0
                    if v >= 2 { for k in 2...Int(v) { f *= Double(k) } }
                    v = f; nontrivial = true
                } else if peek() == "%", !operandFollows(i) {
                    i += 1; v /= 100; nontrivial = true
                } else { break }
            }
            return v
        }

        func thousandsAhead() -> Bool {
            guard c[i] == ",", i + 3 < c.count else { return false }
            for k in 1...3 where !(c[i + k].isASCII && c[i + k].isNumber) { return false }
            return !(i + 4 < c.count && c[i + 4].isASCII && c[i + 4].isNumber)
        }

        mutating func number() -> Double? {
            var text = ""
            while i < c.count {
                let ch = c[i]
                if ch.isASCII && ch.isNumber || ch == "." { text.append(ch); i += 1 }
                else if ch == ",", groupCommas, !text.isEmpty, thousandsAhead() { i += 1 }
                else { break }
            }
            if i < c.count, c[i] == "e" {                     // 3e6, 2.5e-3
                var j = i + 1
                if j < c.count, c[j] == "+" || c[j] == "-" { j += 1 }
                if j < c.count, c[j].isASCII && c[j].isNumber {
                    var k = j
                    while k < c.count, c[k].isASCII && c[k].isNumber { k += 1 }
                    text += "e" + String(c[(i + 1)..<k]); i = k; nontrivial = true
                }
            }
            guard let n = Double(text) else { return nil }
            if allowUnits {                                   // 2.2gb → bytes, 1.5h → seconds, 100mbps → bytes/s
                let save = i
                ws()
                if i < c.count, c[i].isLetter {
                    let id = ident()
                    if i + 1 < c.count, c[i] == "/", c[i + 1].isLetter {      // mb/s, kbit/s
                        let before = i
                        i += 1
                        if let r = Calc.rateUnits[id + "/" + ident()] { return unitValue(n * r.bps / 8 * dataScale / timeScale, 4) }
                        i = before
                    }
                    if let u = Calc.units[id] { return unitValue(n * (binaryUnits ? u.bin : u.si) * dataScale, 1) }
                    if let r = Calc.rateUnits[id] { return unitValue(n * r.bps / 8 * dataScale / timeScale, 4) }
                    if let t = Calc.timeUnits[id] { return unitValue(n * t.sec * timeScale, 2) }
                }
                i = save
            }
            return n
        }

        mutating func unitValue(_ v: Double, _ kind: Int) -> Double {
            usedUnit = true; nontrivial = true; kinds |= kind
            return v
        }

        mutating func ident() -> String {
            let s = i
            while i < c.count {
                if c[i].isLetter || c[i].isASCII && c[i].isNumber || c[i] == "_" { i += 1 }
                else if c[i] == ":", i + 1 < c.count, c[i + 1] == ":" { i += 2 }
                else { break }
            }
            return String(c[s..<i])
        }

        mutating func primary() -> Double? {
            guard let ch = peek() else { return nil }
            if ch == "(" {
                i += 1
                guard let v = bitor(), peek() == ")" else { return nil }
                i += 1
                return v
            }
            if ch == "0", i + 2 < c.count, "xbo".contains(c[i + 1]) {
                let radix = c[i + 1] == "x" ? 16 : (c[i + 1] == "b" ? 2 : 8)
                var j = i + 2
                while j < c.count, c[j].isHexDigit, Int(String(c[j]), radix: radix) != nil { j += 1 }
                if j > i + 2, let v = UInt64(String(c[(i + 2)..<j]), radix: radix) {
                    i = j; usedBase = true
                    return Double(v)
                }
                return nil
            }
            if ch.isASCII && ch.isNumber || ch == "." { return number() }
            if ch.isLetter || ch == "_" {
                var name = ident()
                if Calc.typeWords.contains(name) {            // unsigned long long int
                    var words = [name]
                    while true {
                        let save = i
                        ws()
                        let w = i < c.count && c[i].isLetter ? ident() : ""
                        if Calc.typeWords.contains(w) { words.append(w) } else { i = save; break }
                    }
                    name = words.joined(separator: " ")
                }
                if peek() != "(" {
                    if name == "pi" || name == "π" { return .pi }
                    if name == "e" { return M_E }
                    let base = Calc.sizeOf(name)                            // int → 4 bytes
                    guard base != nil || name == "void" else { return nil }
                    var isPtr = false                                       // int*, char**, void*
                    while true {
                        ws()
                        guard i < c.count, c[i] == "*" else { break }
                        var j = i + 1
                        while j < c.count, c[j] == " " { j += 1 }
                        guard j >= c.count || c[j] == "*" || c[j] == ")" else { break }
                        i += 1; isPtr = true
                    }
                    if isPtr { return 8 }
                    return base
                }
                i += 1
                let multi: Set<String> = ["gcd", "lcm", "ncr", "npr", "choose", "min", "max", "pow", "hypot", "atan2"]
                let saved = groupCommas
                if multi.contains(name) { groupCommas = false }
                var args: [Double] = []
                guard let a = bitor() else { groupCommas = saved; return nil }
                args.append(a)
                while peek() == "," {
                    i += 1
                    guard let b = bitor() else { groupCommas = saved; return nil }
                    args.append(b)
                }
                groupCommas = saved
                guard peek() == ")" else { return nil }
                i += 1
                nontrivial = true
                return apply(name, args)
            }
            return nil
        }

        func apply(_ name: String, _ a: [Double]) -> Double? {
            func gcd(_ x: Int64, _ y: Int64) -> Int64 { var (p, q) = (abs(x), abs(y)); while q != 0 { (p, q) = (q, p % q) }; return p }
            if a.count == 1 {
                let x = a[0]
                switch name {
                case "sqrt": return x < 0 ? nil : sqrt(x)
                case "cbrt": return cbrt(x)
                case "sin": return sin(x)
                case "cos": return cos(x)
                case "tan": return tan(x)
                case "asin": return asin(x)
                case "acos": return acos(x)
                case "atan": return atan(x)
                case "log", "log10": return x <= 0 ? nil : log10(x)
                case "log2": return x <= 0 ? nil : log2(x)
                case "ln": return x <= 0 ? nil : log(x)
                case "exp": return exp(x)
                case "abs": return abs(x)
                case "floor": return floor(x)
                case "ceil": return ceil(x)
                case "round": return x.rounded()
                case "trunc": return trunc(x)
                case "sizeof": return x
                case "fact", "factorial":
                    guard x >= 0, x == x.rounded(), x <= 170 else { return nil }
                    var f = 1.0; if x >= 2 { for k in 2...Int(x) { f *= Double(k) } }; return f
                case "popcnt", "popcount":
                    guard let n = Int64(exactly: x), n >= 0 else { return nil }
                    return Double(n.nonzeroBitCount)
                case "bits":                                         // bits needed to store n
                    guard let n = Int64(exactly: x), n >= 0 else { return nil }
                    return Double(64 - n.leadingZeroBitCount)
                default: return nil
                }
            }
            if a.count == 2 {
                let (x, y) = (a[0], a[1])
                switch name {
                case "pow": return pow(x, y)
                case "hypot": return hypot(x, y)
                case "atan2": return atan2(x, y)
                case "min": return min(x, y)
                case "max": return max(x, y)
                case "gcd":
                    guard let p = Int64(exactly: x), let q = Int64(exactly: y) else { return nil }
                    return Double(gcd(p, q))
                case "lcm":
                    guard let p = Int64(exactly: x), let q = Int64(exactly: y), p != 0, q != 0 else { return nil }
                    let (m, o) = (abs(p) / gcd(p, q)).multipliedReportingOverflow(by: abs(q))
                    return o ? nil : Double(m)
                case "ncr", "choose":
                    guard x >= 0, y >= 0, y <= x, x == x.rounded(), y == y.rounded(), x <= 1000 else { return nil }
                    let r = min(y, x - y); var res = 1.0
                    if r >= 1 { for k in 1...Int(r) { res = res * (x - r + Double(k)) / Double(k) } }
                    return res.rounded()
                case "npr":
                    guard x >= 0, y >= 0, y <= x, x == x.rounded(), y == y.rounded(), x <= 1000 else { return nil }
                    var res = 1.0
                    if y >= 1 { for k in 0..<Int(y) { res *= (x - Double(k)) } }
                    return res
                default: return nil
                }
            }
            if name == "min" || name == "max", a.count > 2 { return name == "min" ? a.min() : a.max() }
            return nil
        }
    }
}
