import Foundation
import Testing

@testable import AlulaMigrateCore

// alula-data's diagnostic codes (ALD-…) and their pages in Diagnostics/, held
// together: a code nothing documents, a page for a code nothing reports, or a
// code no test proves is reported, is a promise nothing checks.

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

private func codes(in directory: String, pattern: Regex<(Substring, Substring)>) throws -> Set<String> {
    var found: Set<String> = []
    let root = repositoryRoot.appendingPathComponent(directory)
    guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    for case let url as URL in files where url.pathExtension == "swift" {
        let source = try String(contentsOf: url, encoding: .utf8)
        for match in source.matches(of: pattern) { found.insert(String(match.1)) }
    }
    return found
}

@Suite("Diagnostic pages")
struct DiagnosticPagesTests {
    @Test("every code has a page, every page a code, and a test that produces it")
    func pagesAndCodesAgree() throws {
        let declared = try codes(in: "Sources", pattern: /"(ALD-[A-Z]+-\d{4})"/)
        let pages = Set(
            try FileManager.default.contentsOfDirectory(
                atPath: repositoryRoot.appendingPathComponent("Diagnostics").path
            ).filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) })
        #expect(!declared.isEmpty)
        #expect(declared == pages, "codes without pages: \(declared.subtracting(pages)); pages without codes: \(pages.subtracting(declared))")
        for code in pages {
            let page = try String(
                contentsOf: repositoryRoot.appendingPathComponent("Diagnostics/\(code).md"), encoding: .utf8)
            #expect(page.hasPrefix("# \(code): "), "\(code)'s title")
            #expect(page.contains("## Meaning") && page.contains("## Fixes"), "\(code)'s sections")
        }
        // A cache code is proven by a macro test asserting it by name, a
        // migration code by a test asserting its id.
        let cacheNames: [String: String] = [
            "invalidNamespace": "ALD-CACHE-1001", "nonLiteralArgument": "ALD-CACHE-1002",
            "uncacheableMethod": "ALD-CACHE-1003", "invalidKeyParameter": "ALD-CACHE-1004",
            "evictWithoutKey": "ALD-CACHE-1005",
        ]
        var proven = try codes(in: "Tests", pattern: /#expect\(.*(ALD-MIGRATE-\d{4})/)
        for name in try codes(in: "Tests", pattern: /coded\(\.(\w+),/) {
            if let id = cacheNames[name] { proven.insert(id) }
        }
        #expect(Set(cacheNames.values).isSubset(of: declared), "the name table is out of date")
        print("alula-data diagnostic coverage: \(declared.intersection(proven).count)/\(declared.count)")
        #expect(declared.subtracting(proven).isEmpty, "no test produces \(declared.subtracting(proven).sorted())")
    }
}
