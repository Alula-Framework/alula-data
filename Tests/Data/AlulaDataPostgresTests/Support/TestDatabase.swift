import Foundation
import AlulaCore
import AlulaDataCore
import AlulaDataPostgres

/// Integration tests run against a real Postgres — the whole
/// value of this package is that queries are real SQL; mocking the
/// connection would test nothing that matters. They are gated on
/// `ALULA_POSTGRES_TEST_DATABASE_URL`:
///
/// ```
/// $ docker run -d --name alula-data-pg -e POSTGRES_PASSWORD=alula \
///     -e POSTGRES_DB=alula_data_test -p 127.0.0.1:55432:5432 postgres:16-alpine
/// $ export ALULA_POSTGRES_TEST_DATABASE_URL="postgres://postgres:alula@127.0.0.1:55432/alula_data_test?sslmode=disable"
/// $ swift test
/// ```
///
/// Without the variable, integration suites are skipped and only the
/// no-server unit tests run.
enum TestDatabase {
    static let url = ProcessInfo.processInfo.environment["ALULA_POSTGRES_TEST_DATABASE_URL"]

    static var isConfigured: Bool { url != nil }

    /// A `Configuration` whose `datasource.<name>.url` points at the test
    /// database — what `PostgresDataModule`'s factory reads at freeze().
    static func configuration(
        datasource name: String = PrimaryDataSource.name,
        poolSize: Int = 4,
        resetOnRelease: Bool = true
    ) throws -> Configuration {
        let url = try requireURL()
        return Configuration(values: [
            DataSourceConfigKey.url(datasource: name): url,
            DataSourceConfigKey.poolSize(datasource: name): "\(poolSize)",
            "datasource.\(name).reset_on_release": "\(resetOnRelease)",
        ])
    }

    /// The values `configuration` is built from, for a test adding its own.
    static func values(datasource name: String = PrimaryDataSource.name, poolSize: Int = 4)
        throws -> [String: String]
    {
        [
            DataSourceConfigKey.url(datasource: name): try requireURL(),
            DataSourceConfigKey.poolSize(datasource: name): "\(poolSize)",
        ]
    }

    static func settings(
        datasource name: String = PrimaryDataSource.name,
        poolSize: Int = 4
    ) throws -> DataSourceSettings {
        try DataSourceSettings(name: name, url: try requireURL(), poolSize: poolSize)
    }

    static func requireURL() throws -> String {
        guard let url else {
            throw TestDatabaseError.notConfigured
        }
        return url
    }
}

enum TestDatabaseError: Error {
    case notConfigured
}
