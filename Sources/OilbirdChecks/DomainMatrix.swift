import Foundation

/// `DM-0`, `DM-1` and `DM-6` over `domains.yaml`.
///
/// `DM-0`  every source file is in a domain, and every one was READ. An
///         unreadable file is a finding, not a skip — a checker that dies on
///         its input is indistinguishable from a green one at the exit code
///         alone.
/// `DM-1`  no domain references a domain its row does not allow.
/// `DM-6`  for each forbidden cell, synthesise a violating reference and
///         assert a violation comes back. A cell that CANNOT be made to fail
///         is itself a finding. This is what separates an enforced matrix from
///         an aspiration, and it runs first on every run, not only when asked.
///
/// ⚠ One rule here the Python original did not have: a `may_reference` row
/// naming a domain that does not exist. `Kit` was granted `Core` and kept the
/// grant after the `Core` domain was deleted — an edge to nowhere, sitting in
/// the matrix reading like a permission. It matched nothing and nothing
/// noticed, which is DM-4 exactly.
struct DomainMatrix: Check {
    let name = "domains"
    let holds = "every file is in a domain, and references only what its row allows"

    private static let indented = Rx("^\\s+(\\w+):\\s*(.*)$", [.anchorsMatchLines])

    /// The domain map: name to its path prefix, and name to what it may reach.
    private struct Map {
        let owners: [String: String]
        let mayReference: [String: [String]]
    }

    /// The `key: value` lines indented under a top-level `name:` key.
    private static func block(_ text: String, _ key: String) -> [(String, String)] {
        var found: [(String, String)] = []
        var inside = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix(key + ":") {
                inside = true
                continue
            }
            guard inside else { continue }
            if !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") { break }
            if let hit = indented.first(in: line as NSString),
                let name = hit.group(1), let value = hit.group(2)
            {
                found.append((name, value.trimmingCharacters(in: .whitespaces)))
            }
        }
        return found
    }

    private static func load() throws -> Map {
        let text = try Checkout.read("domains.yaml")
        let owners = Dictionary(block(text, "domains"), uniquingKeysWith: { _, last in last })
        var references: [String: [String]] = [:]
        for (name, value) in block(text, "may_reference") {
            references[name] =
                value
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        guard !owners.isEmpty, !references.isEmpty else {
            throw Shape("domains.yaml parsed to no domains or no rows")
        }
        return Map(owners: owners, mayReference: references)
    }

    /// The domain a file belongs to: the longest prefix that claims it.
    private static func owner(of path: String, in map: Map) -> String? {
        var best: (name: String, prefix: String)?
        for (name, prefix) in map.owners where path.hasPrefix(prefix) {
            guard let winner = best else {
                best = (name, prefix)
                continue
            }
            if prefix.count > winner.prefix.count { best = (name, prefix) }
        }
        return best?.name
    }

    /// The file with its comments removed.
    ///
    /// A doc comment naming another domain is prose, not a reference — and the
    /// matcher said otherwise on its first run.
    private static func codeOnly(_ text: String) -> String { Code.withoutProse(text) }

    /// Does this source reference the domain's namespace?
    private static func references(_ code: String, _ domain: String) -> Bool {
        Rx("\\b\(domain)\\s*\\.").matches(code)
    }

    private static func check(
        _ path: String, _ code: String, _ map: Map, into findings: inout [String]
    ) {
        guard let home = owner(of: path, in: map) else {
            findings.append("DM-0  \(path) is in no domain")
            return
        }
        var allowed = Set(map.mayReference[home] ?? [])
        allowed.insert(home)
        for other in map.owners.keys where !allowed.contains(other) {
            if references(code, other) {
                findings.append(
                    "DM-1  \(home) -> \(other)   \(path) may not reference `\(other)`")
            }
        }
    }

    func selfTest() throws {
        let map = try Self.load()
        var unfailable: [String] = []
        for (row, prefix) in map.owners {
            for column in map.owners.keys {
                if column == row || (map.mayReference[row] ?? []).contains(column) { continue }
                var probe: [String] = []
                Self.check(prefix + "/__probe.swift", "let x = \(column).something\n", map, into: &probe)
                if probe.isEmpty { unfailable.append("\(row) -> \(column)") }
            }
        }
        guard unfailable.isEmpty else {
            throw SelfTest(
                "these cells cannot be made to fail:\n"
                    + unfailable.sorted().map { "  DM-6  \($0)" }.joined(separator: "\n"))
        }
    }

    func run() throws -> Report {
        let map = try Self.load()
        var report = Report(summary: "")

        // A grant to a domain that does not exist. DM-4: the zero IS the
        // finding — the row reads like a permission and reaches nothing.
        for (row, columns) in map.mayReference.sorted(by: { $0.key < $1.key }) {
            if map.owners[row] == nil {
                report.findings.append(
                    "DM-4  may_reference has a row for `\(row)`, which is not a domain")
            }
            for column in columns where map.owners[column] == nil {
                report.findings.append(
                    "DM-4  \(row) is granted `\(column)`, which is not a domain — the grant "
                        + "reaches nothing and reads as though it did")
            }
        }
        for row in map.owners.keys.sorted() where map.mayReference[row] == nil {
            report.findings.append(
                "DM-0  domain `\(row)` has no may_reference row, so nothing constrains it")
        }

        var read = 0
        for file in Checkout.swiftFiles(under: "Sources") {
            guard let text = try? String(contentsOf: Checkout.url(file), encoding: .utf8) else {
                report.findings.append(
                    "DM-0  \(file) could not be read, so no rule ran against it")
                continue
            }
            read += 1
            Self.check(file, Self.codeOnly(text), map, into: &report.findings)
        }

        let forbidden = map.owners.keys.reduce(into: 0) { total, row in
            total +=
                map.owners.keys.filter {
                    $0 != row && !(map.mayReference[row] ?? []).contains($0)
                }.count
        }
        report.summary =
            "\(read) files, \(map.owners.count) domains, \(forbidden) forbidden cells"
        return report
    }
}
