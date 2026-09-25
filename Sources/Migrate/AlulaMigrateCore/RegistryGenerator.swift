/// Build-time generation of the `_allMigrations()` registry.
///
/// The generator receives every `.swift` source in the migrations target, classifies each
/// file, validates the set as a whole, and emits a single Swift file containing an ordered
/// registry. Every property the generated registry promises is enforced here, which makes them
/// **build-time** errors:
///
/// - malformed timestamp prefixes,
/// - duplicate versions (including across differently-named files),
/// - a file that does not declare the migration type its filename names,
/// - more than one `Migration` type in a single file.
public enum RegistryGenerator {
    /// One input source file.
    public struct InputFile: Sendable {
        /// Path as shown in diagnostics (any form the build system provides).
        public let path: String
        /// The filename component, e.g. `20260714120000_CreateUsers.swift`.
        public let filename: String
        /// Full UTF-8 contents.
        public let contents: String

        public init(path: String, filename: String, contents: String) {
            self.path = path
            self.filename = filename
            self.contents = contents
        }
    }

    /// A discovered, validated migration.
    public struct DiscoveredMigration: Equatable, Sendable {
        public let version: Int64
        public let name: String
        public let checksum: String
        public let path: String
    }

    public struct GeneratorError: Error, CustomStringConvertible, Sendable {
        /// One problem with the migration set, located at the file that has it.
        public struct Issue: Sendable, Equatable {
            /// A stable code with a page in alula-data's `Diagnostics/`.
            public let code: String
            public let path: String
            public let message: String
            /// Other files in the same problem — the other half of a duplicate.
            public let related: [String]

            /// `path:1:1: error: [CODE] message`, which SwiftPM attaches to the
            /// file. The old `error: [AlulaMigrate] path: message` put the path
            /// after the severity, so nothing could point at it.
            public var rendered: String {
                var lines = ["\(path):1:1: error: [\(code)] \(message)"]
                lines.append(
                    "    docs: https://github.com/Alula-Framework/alula-data/blob/main/Diagnostics/\(code).md")
                lines += related.map { "\($0):1:1: note: the same version" }
                return lines.joined(separator: "\n")
            }
        }

        public let issues: [Issue]

        /// Each issue as printed.
        public var problems: [String] { issues.map(\.rendered) }

        public var description: String { problems.joined(separator: "\n") }
    }

    /// Codes for the migration set's problems.
    enum Code {
        static let invalidFilename = "ALD-MIGRATE-2001"
        static let typeMismatch = "ALD-MIGRATE-2002"
        static let duplicateVersion = "ALD-MIGRATE-2003"
    }

    /// Scans and validates the input files, returning discovered migrations sorted by version.
    public static func discover(files: [InputFile]) throws -> [DiscoveredMigration] {
        var discovered: [DiscoveredMigration] = []
        var problems: [GeneratorError.Issue] = []

        for file in files {
            switch MigrationFilename.classify(file.filename) {
            case .notAMigration:
                continue
            case .malformed(let reason):
                problems.append(.init(
                    code: Code.invalidFilename, path: file.path,
                    message: "invalid migration filename: \(reason)", related: []))
            case .migration(let parsed):
                let conformers = SourceScanner.migrationTypeNames(in: file.contents)
                if conformers.isEmpty {
                    problems.append(.init(
                        code: Code.typeMismatch, path: file.path,
                        message: """
                            no Migration type found. Expected a declaration like \
                            'struct \(parsed.name): Migration { ... }'. Note that the conformance must \
                            be declared at the type definition, not in an extension.
                            """,
                        related: []))
                    continue
                }
                if conformers != [parsed.name] {
                    if conformers.count > 1 {
                        problems.append(.init(
                            code: Code.typeMismatch, path: file.path,
                            message: """
                                found multiple Migration types (\(conformers.joined(separator: ", "))). \
                                Each migration file must declare exactly one Migration type, named after the file.
                                """,
                            related: []))
                    } else {
                        problems.append(.init(
                            code: Code.typeMismatch, path: file.path,
                            message: """
                                the filename promises a Migration type named '\(parsed.name)' but \
                                the file declares '\(conformers[0])'. Rename the file or the type so they match.
                                """,
                            related: []))
                    }
                    continue
                }
                discovered.append(
                    DiscoveredMigration(
                        version: parsed.version,
                        name: parsed.name,
                        checksum: MigrationChecksum.compute(
                            version: parsed.version, name: parsed.name, source: file.contents),
                        path: file.path
                    ))
            }
        }

        // Duplicate version detection across the whole target.
        var byVersion: [Int64: [DiscoveredMigration]] = [:]
        for migration in discovered {
            byVersion[migration.version, default: []].append(migration)
        }
        for (version, group) in byVersion.sorted(by: { $0.key < $1.key }) where group.count > 1 {
            let paths = group.map(\.path).sorted()
            problems.append(.init(
                code: Code.duplicateVersion, path: paths[paths.count - 1],
                message: """
                    duplicate migration version \(version), also used by \
                    \(paths.dropLast().map { $0.split(separator: "/").last.map(String.init) ?? $0 }.joined(separator: ", ")). \
                    Each migration must have a unique timestamp prefix. This usually comes from a \
                    hand-edited or merge-conflicted filename; regenerate one of the timestamps with \
                    'alula-migrate create'.
                    """,
                related: Array(paths.dropLast())))
        }

        guard problems.isEmpty else {
            throw GeneratorError(issues: problems)
        }
        return discovered.sorted { $0.version < $1.version }
    }

    /// Generates the registry source for a target. Throws ``GeneratorError`` on invalid input.
    public static func generate(targetName: String, files: [InputFile]) throws -> String {
        let migrations = try discover(files: files)

        var out = """
        // Generated by alula-migrate-gen for target '\(targetName)'. DO NOT EDIT.
        //
        // One entry per migration file, ordered by version (the UTC timestamp prefix).
        // Checksums are SHA-256 over the migration's source (see MigrationChecksum) and
        // are the values verified against the bookkeeping table on every run.

        import AlulaMigrate

        /// All migrations discovered in this target, ordered by version.
        public func _allMigrations() -> [MigrationEntry] {
            [

        """

        for migration in migrations {
            out += """
                    MigrationEntry(
                        version: \(migration.version),
                        name: "\(migration.name)",
                        checksum: "\(migration.checksum)",
                        type: \(migration.name).self
                    ),

            """
        }

        out += """
            ]
        }
        """
        out += "\n"
        return out
    }
}
