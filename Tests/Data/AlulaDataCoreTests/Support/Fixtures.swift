import AlulaCore
import AlulaDataCore
import AlulaDataTesting

// MARK: - The repository fixture
//
// The canonical `UserRepository`: a @Repository-stereotyped component holding
// the *pool*, leasing a connection per operation. Hand-registered (like Core's
// own container tests) so these results say nothing about macro correctness —
// the macro layer has its own suites in alula-core.
//
// It is a singleton. It used to be `.scoped`, holding one connection for a
// whole request, which made every service holding a repository `.scoped` too
// — lifetime propagating up the graph from a pooling concern.

final class UserRepository: Sendable {
    let pool: InMemoryDataSource

    init(pool: InMemoryDataSource) {
        self.pool = pool
    }

    func save(_ user: String) async throws {
        try await pool.withConnection { connection in
            connection.perform("INSERT \(user)")
        }
    }

    /// Two statements that must land on one connection say so explicitly.
    /// Nothing pins a connection across operations implicitly any more.
    func saveBoth(_ first: String, _ second: String) async throws {
        try await pool.withConnection { connection in
            connection.perform("INSERT \(first)")
            connection.perform("INSERT \(second)")
        }
    }
}

// MARK: - Named datasources

enum Analytics: DataSourceName {
    static let name = "analytics"
}
