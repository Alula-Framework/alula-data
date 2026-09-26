import Foundation

/// PostgresNIO's text for a failed dial, cut down to what an operator reads.
///
/// A refused connection arrives as
/// `Connection errors: SingleConnectionFailure(target: [IPv4]127.0.0.1/127.0.0.1:1,
/// error: connection reset (error set): Connection refused) (errno: 111))` —
/// the answer is in there, behind two type names and unbalanced parentheses
/// (Relay #34, #41). This returns `connection refused (127.0.0.1:1)`, one
/// entry per address tried, or `connection reset by peer` for a failure on a
/// connection that was already open. Text in any other shape comes back unchanged, so
/// a format this does not know costs polish, never information.
package func readableConnectionFailure(_ text: String) -> String {
    let pattern = #/target: \[[^\]]*\][^\/,]*\/([^,]+), error: (.*?)\(errno: \d+\)/#
    let failures = text.matches(of: pattern).map { match -> String in
        // "connection reset (error set): Connection refused) " → the part
        // after the last ": ", without the stray parenthesis.
        let error = String(match.output.2)
        let reason = error.components(separatedBy: ": ").last ?? error
        let trimmed = reason.trimmingCharacters(in: CharacterSet(charactersIn: ") "))
        return "\(trimmed.lowercased()) (\(match.output.1))"
    }
    if !failures.isEmpty { return failures.joined(separator: "; ") }
    // A failure on an open connection names no target:
    // `read(descriptor:pointer:size:): Connection reset by peer) (errno: 104)`.
    if let match = text.firstMatch(of: #/:\s*([A-Za-z][^:()]*?)\)?\s*\(errno: \d+\)/#) {
        return match.output.1.lowercased()
    }
    return text
}
