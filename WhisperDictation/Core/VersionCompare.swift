import Foundation

/// Numeric dotted-version comparison for the update check ("1.10.0" must beat
/// "1.9.4" — string comparison gets that wrong). Pure, unit-tested.
enum VersionCompare {
    /// True when `candidate` is strictly newer than `current`. Missing
    /// components count as 0 ("1.9" == "1.9.0"); a leading "v" is tolerated.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(of: candidate)
        let b = components(of: current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func components(of version: String) -> [Int] {
        var v = version.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("v") || v.hasPrefix("V") { v = String(v.dropFirst()) }
        return v.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}
