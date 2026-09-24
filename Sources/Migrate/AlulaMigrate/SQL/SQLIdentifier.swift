import Foundation

/// Quoting helpers for rendered DDL.
enum SQL {
    /// Quotes an identifier, treating dots as schema qualification:
    /// `users` → `"users"`, `analytics.events` → `"analytics"."events"`.
    /// Embedded double quotes are escaped by doubling. An identifier that itself contains
    /// a literal dot is not expressible through the DSL — use `schema.raw(_:)`.
    static func identifier(_ raw: String) -> String {
        raw.split(separator: ".", omittingEmptySubsequences: false)
            .map { part in "\"\(part.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: ".")
    }

    /// Quotes a single (non-qualified) identifier: dots are treated literally.
    static func columnIdentifier(_ raw: String) -> String {
        "\"\(raw.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Renders a string literal: `it's` → `'it''s'`.
    ///
    /// A value containing a backslash is written in escape-string form
    /// (`E'a\\b'`), which means the same thing whatever the server's
    /// `standard_conforming_strings` is — in a plain literal a backslash is
    /// data with the setting on and an escape with it off, so the same
    /// migration would store different text on two servers.
    static func stringLiteral(_ raw: String) -> String {
        let quoted = raw.replacingOccurrences(of: "'", with: "''")
        guard raw.contains("\\") else { return "'\(quoted)'" }
        return "E'\(quoted.replacingOccurrences(of: "\\", with: "\\\\"))'"
    }
}
