import AlulaMigrateCore
import AlulaMigrate
import Foundation
import Testing

@testable import AlulaMigrateCLI

@Suite("DatabaseURL")
struct DatabaseURLTests {
    @Test func fullURL() throws {
        let url = try DatabaseURL.parse("postgres://alice:s3cret@db.example.com:6543/alula?sslmode=require")
        #expect(url.host == "db.example.com")
        #expect(url.port == 6543)
        #expect(url.username == "alice")
        #expect(url.password == "s3cret")
        #expect(url.database == "alula")
        #expect(url.sslMode == .require)
    }

    @Test func defaultsApplied() throws {
        let url = try DatabaseURL.parse("postgres://bob@localhost")
        #expect(url.port == 5432)
        #expect(url.database == "bob")  // database defaults to username, like libpq
        #expect(url.password == nil)
        #expect(url.sslMode == .prefer)
    }

    @Test func hostDefaultsToLocalhost() throws {
        let url = try DatabaseURL.parse("postgres://bob@/mydb")
        #expect(url.host == "localhost")
        #expect(url.database == "mydb")
    }

    @Test func postgresqlSchemeAccepted() throws {
        let url = try DatabaseURL.parse("postgresql://bob@h/db")
        #expect(url.host == "h")
    }

    @Test func percentEncodedPassword() throws {
        let url = try DatabaseURL.parse("postgres://alice:p%40ss%2Fword@h/db")
        #expect(url.password == "p@ss/word")
    }

    @Test(arguments: [
        "mysql://alice@h/db",  // wrong scheme
        "postgres://h/db",  // no username
        "postgres://alice@h/db?sslmode=bogus",  // unknown sslmode
        "not a url at all",  // unparseable / wrong shape
    ])
    func invalidURLs(raw: String) {
        #expect(throws: CLIError.self) {
            _ = try DatabaseURL.parse(raw)
        }
    }

    @Test(arguments: [
        ("disable", DatabaseURL.SSLMode.disable),
        ("allow", .allow),
        ("prefer", .prefer),
        ("require", .require),
        ("verify-ca", .verifyCA),
        ("verify-full", .verifyFull),
    ])
    func sslModes(raw: String, expected: DatabaseURL.SSLMode) throws {
        let url = try DatabaseURL.parse("postgres://u@h/db?sslmode=\(raw)")
        #expect(url.sslMode == expected)
    }

    @Test func resolutionOrder() throws {
        let env = [
            "ALULA_DATABASE_URL": "postgres://alula@h/db1",
            "DATABASE_URL": "postgres://generic@h/db2",
        ]
        #expect(
            try DatabaseURL.resolve(flag: "postgres://flag@h/db0", environment: env).username
                == "flag")
        #expect(try DatabaseURL.resolve(flag: nil, environment: env).username == "alula")
        #expect(
            try DatabaseURL.resolve(
                flag: nil, environment: ["DATABASE_URL": "postgres://generic@h/db2"]
            ).username == "generic")
        #expect(throws: CLIError.self) {
            _ = try DatabaseURL.resolve(flag: nil, environment: [:])
        }
    }
}

@Suite("Scaffold")
struct ScaffoldTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alula-migrate-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func createsFileWithUTCTimestampAndTemplate() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 2026-07-15 18:30:22 UTC
        let date = Date(timeIntervalSince1970: 1_784_313_022)
        let created = try Scaffold.makeMigration(name: "CreateUsers", date: date, directory: dir)

        #expect(created.url.lastPathComponent == "\(created.version)_CreateUsers.swift")
        #expect(created.version == Scaffold.utcVersion(of: date))
        // The version must be a valid migration filename by our own rules.
        let contents = try String(contentsOf: created.url, encoding: .utf8)
        #expect(contents.contains("struct CreateUsers: Migration {"))
        #expect(contents.contains("import AlulaMigrate"))
        #expect(contents.contains("func up(_ schema: SchemaBuilder)"))
        #expect(contents.contains("func down(_ schema: SchemaBuilder)"))
    }

    @Test func utcVersionIsUTC() {
        // 2026-01-02 03:04:05 UTC — verifies no local-time leakage.
        let date = Date(timeIntervalSince1970: 1_767_323_045)
        #expect(Scaffold.utcVersion(of: date) == 20260102030405)
    }

    @Test func sameSecondCollisionBumpsVersion() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let date = Date(timeIntervalSince1970: 1_784_313_022)
        let first = try Scaffold.makeMigration(name: "First", date: date, directory: dir)
        let second = try Scaffold.makeMigration(name: "Second", date: date, directory: dir)

        // Different name, same second: still bumped, because duplicate *versions* are a
        // build error regardless of name.
        #expect(second.version == first.version + 1)
    }

    @Test(arguments: ["create-users", "9Lives", "Create Users", "class", ""])
    func invalidNamesRejected(name: String) throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: CLIError.self) {
            _ = try Scaffold.makeMigration(name: name, date: Date(), directory: dir)
        }
    }

    @Test func resolveDirectoryPrefersConventionalPaths() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // No conventional directory: error listing what was searched.
        #expect(throws: CLIError.self) {
            _ = try Scaffold.resolveDirectory(flag: nil, currentDirectory: root)
        }

        // Sources/Migrations wins once it exists.
        let conventional = root.appendingPathComponent("Sources/Migrations")
        try FileManager.default.createDirectory(at: conventional, withIntermediateDirectories: true)
        let resolved = try Scaffold.resolveDirectory(flag: nil, currentDirectory: root)
        #expect(resolved.path == conventional.path)

        // An explicit flag always wins.
        let explicit = try Scaffold.resolveDirectory(flag: "Custom/Dir", currentDirectory: root)
        #expect(explicit.path.hasSuffix("Custom/Dir"))
    }
}

@Suite("CLI parsing")
struct CLIParsingTests {
    @Test func bareInvocationIsApply() throws {
        let command = try RootCommand.parseAsRoot([])
        #expect(command is ApplyCommand)
    }

    @Test func applyFlagsParse() throws {
        let command = try RootCommand.parseAsRoot([
            "apply", "--dry-run", "--database-url", "postgres://u@h/db",
            "--migrations-table", "ops.ledger",
        ])
        let apply = try #require(command as? ApplyCommand)
        #expect(apply.dryRun)
        #expect(apply.database.databaseUrl == "postgres://u@h/db")
        #expect(apply.database.migrationsTable == "ops.ledger")
    }

    @Test func rollbackStepsAndToAreExclusive() {
        #expect(throws: (any Error).self) {
            _ = try RootCommand.parseAsRoot(["rollback", "--steps", "2", "--to", "20260714120000"])
        }
    }

    @Test func rollbackToParses() throws {
        let command = try RootCommand.parseAsRoot(["rollback", "--to", "20260714120000"])
        let rollback = try #require(command as? RollbackCommand)
        #expect(rollback.to == 20260714120000)
        #expect(rollback.steps == nil)
    }

    @Test func rollbackRejectsZeroSteps() {
        #expect(throws: (any Error).self) {
            _ = try RootCommand.parseAsRoot(["rollback", "--steps", "0"])
        }
    }

    @Test func statusJSONFlagParses() throws {
        let command = try RootCommand.parseAsRoot(["status", "--json"])
        let status = try #require(command as? StatusCommand)
        #expect(status.json)
    }

    @Test func createParsesNameAndDirectory() throws {
        let command = try RootCommand.parseAsRoot(["create", "AddUsersEmail", "--directory", "X"])
        let create = try #require(command as? CreateCommand)
        #expect(create.name == "AddUsersEmail")
        #expect(create.directory == "X")
    }

    @Test func unknownSubcommandFails() {
        #expect(throws: (any Error).self) {
            _ = try RootCommand.parseAsRoot(["destroy-everything"])
        }
    }

    @Test("--version matches the changelog's most recent release")
    func versionIsNotStale() throws {
        // It sat at "0.1.0" through two releases, because nothing connected it
        // to anything. A compiled binary cannot read the package manifest and
        // the build plugin cannot see the tag, so the constant is
        // hand-maintained — and this is what makes forgetting it fail.
        let changelog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AlulaMigrateTests
            .deletingLastPathComponent()  // Migrate
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("CHANGELOG.md")
        let contents = try String(contentsOf: changelog, encoding: .utf8)

        let latest = contents
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("## [") else { return nil }
                return String(line.dropFirst(4).prefix(while: { $0 != "]" }))
            }
            .first { $0 != "Unreleased" }

        #expect(
            alulaMigrateVersion == latest,
            """
            alula-migrate --version reports \(alulaMigrateVersion) but the changelog's most \
            recent release is \(latest ?? "none"). Update `alulaMigrateVersion` in \
            Commands.swift when cutting a release.
            """)
    }
}

@Suite("Connecting before a run")
struct ConnectionCheckTests {
    @Test("a closed port is reported at once, with where it was dialling and why")
    func closedPortFailsFast() async throws {
        // Relay #41: a minute of silence, then the pool's
        // `connectionCreationCircuitBreakerTripped`, for every kind of failure.
        let url = try DatabaseURL.parse("postgres://app:hunter2-secret@127.0.0.1:1/appdb?sslmode=disable")
        let started = ContinuousClock.now
        do {
            try await Runtime.checkConnection(to: url)
            Issue.record("connected to a closed port")
        } catch let error as CLIError {
            let text = error.description
            #expect(text.hasPrefix("could not connect to postgres at 127.0.0.1:1, database 'appdb'"))
            #expect(text.lowercased().contains("refused"))
            #expect(!text.contains("hunter2-secret"))
            #expect(!text.contains("CircuitBreaker"))
        }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test("a wrong password gets the server's answer and SQLSTATE",
          .enabled(if: ProcessInfo.processInfo.environment["ALULA_MIGRATE_TEST_DATABASE_URL"] != nil))
    func wrongPassword() async throws {
        let real = try #require(
            URLComponents(string: ProcessInfo.processInfo.environment["ALULA_MIGRATE_TEST_DATABASE_URL"]!))
        var wrong = real
        wrong.password = "hunter2-secret"
        let url = try DatabaseURL.parse(try #require(wrong.string))
        await #expect {
            try await Runtime.checkConnection(to: url)
        } throws: { error in
            let text = String(describing: error)
            return text.contains("28P01") && !text.contains("hunter2-secret")
        }
    }
}

@Suite("Readable connection failures")
struct ReadableConnectionFailureTests {
    @Test("PostgresNIO's refused-connection text becomes what an operator reads")
    func refused() {
        let raw =
            "Connection errors: SingleConnectionFailure(target: [IPv4]127.0.0.1/127.0.0.1:1, error: connection reset (error set): Connection refused) (errno: 111))"
        #expect(readableConnectionFailure(raw) == "connection refused (127.0.0.1:1)")
    }

    @Test("every address tried is listed")
    func severalAddresses() {
        let raw =
            "Connection errors: SingleConnectionFailure(target: [IPv4]127.0.0.1/127.0.0.1:5432, error: connection reset (error set): Connection refused) (errno: 111)), SingleConnectionFailure(target: [IPv6]localhost/::1:5432, error: connection reset (error set): Connection refused) (errno: 111))"
        #expect(
            readableConnectionFailure(raw) == "connection refused (127.0.0.1:5432); connection refused (::1:5432)")
    }

    @Test("a failure on an open connection, which names no address")
    func resetByPeer() {
        #expect(
            readableConnectionFailure("read(descriptor:pointer:size:): Connection reset by peer) (errno: 104)")
                == "connection reset by peer")
    }

    @Test("text in a shape it does not know comes back unchanged")
    func unknownShape() {
        #expect(readableConnectionFailure("serverClosedConnection") == "serverClosedConnection")
    }
}

@Suite("The database from alula.yaml")
struct ConfiguredDatabaseTests {
    /// A directory holding `files`, removed afterwards.
    private func withDirectory<T>(_ files: [String: String], _ body: (String) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("migrate-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, contents) in files {
            try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return try body(directory.path)
    }

    private let base = """
        datasource:
          primary:
            url: postgres://app:secret@db.internal:5432/app_dev
          reporting:
            url: postgres://reader@replica:5432/app_dev
        """

    @Test("with no URL given, the application's datasource is used, and said to be")
    func fromConfiguration() throws {
        // Relay #29: the database was configured twice, once for the app and
        // once for migrate, and the two could drift apart.
        try withDirectory(["alula.yaml": base]) { directory in
            let (url, source) = try DatabaseURL.resolve(
                flag: nil, datasource: "primary", configDirectory: directory, environment: [:])
            #expect(url.host == "db.internal" && url.database == "app_dev" && url.username == "app")
            #expect(source.description == "datasource.primary.url in \(directory)/alula.yaml")
        }
    }

    @Test("the environment overlay and ALULA_ variables apply as they do for the application")
    func overlayAndEnvironment() throws {
        try withDirectory([
            "alula.yaml": base,
            "alula-prod.yaml": "datasource:\n  primary:\n    url: postgres://app@db.prod:5432/app\n",
        ]) { directory in
            let prod = try DatabaseURL.resolve(
                flag: nil, datasource: "primary", configDirectory: directory,
                environment: ["ALULA_ENV": "prod"])
            #expect(prod.url.host == "db.prod")
            let overridden = try DatabaseURL.resolve(
                flag: nil, datasource: "primary", configDirectory: directory,
                environment: ["ALULA_DATASOURCE_PRIMARY_URL": "postgres://ops@db.override:5432/app"])
            #expect(overridden.url.host == "db.override")
        }
    }

    @Test("a substituted variable resolves from the environment")
    func substitution() throws {
        try withDirectory([
            "alula.yaml": "datasource:\n  primary:\n    url: ${APP_DATABASE_URL}\n"
        ]) { directory in
            let resolved = try DatabaseURL.resolve(
                flag: nil, datasource: "primary", configDirectory: directory,
                environment: ["APP_DATABASE_URL": "postgres://app@db.sub:5432/app"])
            #expect(resolved.url.host == "db.sub")
        }
    }

    @Test("--datasource picks another; the flag and the environment still come first")
    func precedence() throws {
        try withDirectory(["alula.yaml": base]) { directory in
            #expect(
                try DatabaseURL.resolve(
                    flag: nil, datasource: "reporting", configDirectory: directory, environment: [:]
                ).url.host == "replica")
            let flag = try DatabaseURL.resolve(
                flag: "postgres://f@flag:5432/x", datasource: "primary", configDirectory: directory,
                environment: ["ALULA_DATABASE_URL": "postgres://e@env:5432/x"])
            #expect(flag.url.host == "flag" && flag.source == .flag)
            let env = try DatabaseURL.resolve(
                flag: nil, datasource: "primary", configDirectory: directory,
                environment: ["ALULA_DATABASE_URL": "postgres://e@env:5432/x"])
            #expect(env.url.host == "env" && env.source == .environment("ALULA_DATABASE_URL"))
        }
    }

    @Test("a missing datasource says which key, and where")
    func missingDatasource() throws {
        try withDirectory(["alula.yaml": base]) { directory in
            #expect {
                _ = try DatabaseURL.resolve(
                    flag: nil, datasource: "analytics", configDirectory: directory, environment: [:])
            } throws: { error in
                String(describing: error).hasPrefix("\(directory)/alula.yaml has no usable datasource.analytics.url")
            }
        }
    }

    @Test("no URL and no alula.yaml says where a URL can come from")
    func nothingAnywhere() throws {
        try withDirectory([:]) { directory in
            #expect {
                _ = try DatabaseURL.resolve(
                    flag: nil, datasource: "primary", configDirectory: directory, environment: [:])
            } throws: { error in
                String(describing: error).contains("alula.yaml")
            }
        }
    }
}
