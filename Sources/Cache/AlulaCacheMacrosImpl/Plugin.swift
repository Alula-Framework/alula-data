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

/// Shared diagnostic shape, mirroring AlulaCoreMacros: every diagnostic
/// names the fix, not just the problem — these fire at build time and are
/// the compile-time-first pitch in action.
struct AlulaCacheMacroDiagnostic: DiagnosticMessage {
    let message: String
    let id: String
    let severity: DiagnosticSeverity

    var diagnosticID: MessageID { MessageID(domain: "AlulaCacheMacros", id: id) }

    static func error(_ id: String, _ message: String) -> AlulaCacheMacroDiagnostic {
        AlulaCacheMacroDiagnostic(message: message, id: id, severity: .error)
    }
}

extension MacroExpansionContext {
    func diagnoseError(_ id: String, _ message: String, at node: some SyntaxProtocol) {
        diagnose(Diagnostic(node: Syntax(node), message: AlulaCacheMacroDiagnostic.error(id, message)))
    }
}
