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
    public let store: any QueueStore

    /// The concrete store, for enqueueing inside a transaction with
    /// ``PostgresQueueStore/enqueue(_:in:)``.
    public let postgresQueueStore: PostgresQueueStore

    public init(configuration: Configuration, dataSource: PostgresDataSource) throws {
        let table =
            try configuration.getIfPresent(allowingSnakeCase: "queue.postgres.table", as: String.self) ?? "alula_jobs"
        let store = PostgresQueueStore(dataSource: dataSource, table: table)
        self.postgresQueueStore = store
        self.store = store
    }

    public init() {
        preconditionFailure(
            "AlulaQueuePostgresModule takes its configuration and pool in "
                + "init(configuration:dataSource:), so it cannot be instantiated from its type. "
                + "Pass `composedBy: alulaComposeModules` to Alula.run.")
    }
}
