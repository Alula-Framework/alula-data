import SwiftDiagnostics
import SwiftSyntaxMacrosGenericTestSupport

@testable import AlulaCacheMacrosImpl

extension DiagnosticSpec {
    /// A cache macro diagnostic as it reaches the reader: the message leads
    /// with its code, and a note at the same place links the code's page.
    static func coded(
        _ code: CacheDiagnosticCode,
        message: String,
        line: Int,
        column: Int,
        originatorFileID: StaticString = #fileID,
        originatorFile: StaticString = #filePath,
        originatorLine: UInt = #line,
        originatorColumn: UInt = #column
    ) -> DiagnosticSpec {
        DiagnosticSpec(
            message: "[\(code.rawValue)] \(message)",
            line: line,
            column: column,
            notes: [
                NoteSpec(
                    message: "see \(code.documentationURL)", line: line, column: column,
                    originatorFileID: originatorFileID, originatorFile: originatorFile,
                    originatorLine: originatorLine, originatorColumn: originatorColumn)
            ],
            originatorFileID: originatorFileID,
            originatorFile: originatorFile,
            originatorLine: originatorLine,
            originatorColumn: originatorColumn)
    }
}
