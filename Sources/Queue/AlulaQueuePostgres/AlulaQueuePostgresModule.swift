import AlulaCore
import AlulaDataPostgres
import AlulaQueue

/// Makes the application's job queue durable: provides a
/// ``PostgresQueueStore`` over the Postgres pool, which `AlulaQueueModule`
/// takes in place of its in-memory default.
///
/// ```swift
/// await Alula.run(configuration: try .load(), modules: [
///     PostgresDataModule<PrimaryDataSource>.self,
///     AlulaQueuePostgresModule.self,
///     AlulaQueueWorkerModule.self,
///     AppModule.self,
/// ], composedBy: alulaComposeModules)
/// ```
///
/// The table is `queue.postgres.table` (default `alula_jobs`), and it is not
/// created at boot, the same as every other table alula-data touches. Put
/// ``PostgresQueueStore/schema(table:)`` in a migration.
public struct AlulaQueuePostgresModule: AlulaModule {
    /// The store `AlulaQueueModule` takes in place of its in-memory default.
    public let store: any QueueStore

    /// The concrete store, for enqueueing inside a transaction with
    /// ``PostgresQueueStore/enqueue(_:in:)``.
    public let postgresQueueStore: PostgresQueueStore

    /// Reads `queue.postgres.table` and builds the store over the pool.
    /// Touches no table: a missing one fails the first claim, not startup.
    ///
    /// - Parameters:
    ///   - configuration: The application's configuration.
    ///   - dataSource: The pool every queue operation leases from.
    public init(configuration: Configuration, dataSource: PostgresDataSource) throws {
        let table =
            try configuration.getIfPresent(allowingSnakeCase: "queue.postgres.table", as: String.self) ?? "alula_jobs"
        let store = PostgresQueueStore(dataSource: dataSource, table: table)
        self.postgresQueueStore = store
        self.store = store
    }

    /// Traps. Build the module with ``init(configuration:dataSource:)``,
    /// which `alulaComposeModules` does.
    public init() {
        preconditionFailure(
            "AlulaQueuePostgresModule takes its configuration and pool in "
                + "init(configuration:dataSource:), so it cannot be instantiated from its type. "
                + "Pass `composedBy: alulaComposeModules` to Alula.run.")
    }
}
