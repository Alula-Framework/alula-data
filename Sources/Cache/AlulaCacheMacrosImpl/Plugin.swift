import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

@main
struct AlulaCacheMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        CacheableMacro.self,
        CacheEvictMacro.self,
        CachePutMacro.self,
    ]
}

/// alula-data's diagnostic codes for the cache annotations. Each has a page
/// in alula-data's `Diagnostics/`, which the note under the error links, and
/// `alula explain` points at it too. Codes are stable: never renumbered or
/// reused.
enum CacheDiagnosticCode: String {
    case invalidNamespace = "ALD-CACHE-1001"
    case nonLiteralArgument = "ALD-CACHE-1002"
    case uncacheableMethod = "ALD-CACHE-1003"
    case invalidKeyParameter = "ALD-CACHE-1004"
    case evictWithoutKey = "ALD-CACHE-1005"

    var documentationURL: String {
        "https://github.com/Alula-Framework/alula-data/blob/main/Diagnostics/\(rawValue).md"
    }
}

/// Every diagnostic names the fix, not just the problem, and leads with its
/// code — the same shape as Alula's own macros.
struct AlulaCacheMacroDiagnostic: DiagnosticMessage {
    let code: CacheDiagnosticCode
    let text: String

    var message: String { "[\(code.rawValue)] \(text)" }
    var diagnosticID: MessageID { MessageID(domain: "AlulaCacheMacros", id: code.rawValue) }
    var severity: DiagnosticSeverity { .error }
}

struct CacheDocumentationNote: NoteMessage {
    let code: CacheDiagnosticCode
    var message: String { "see \(code.documentationURL)" }
    var noteID: MessageID { MessageID(domain: "AlulaCacheMacros", id: "\(code.rawValue).docs") }
}

extension MacroExpansionContext {
    func diagnose(_ code: CacheDiagnosticCode, _ message: String, at node: some SyntaxProtocol) {
        diagnose(
            Diagnostic(
                node: Syntax(node),
                message: AlulaCacheMacroDiagnostic(code: code, text: message),
                notes: [Note(node: Syntax(node), message: CacheDocumentationNote(code: code))]))
    }
}
