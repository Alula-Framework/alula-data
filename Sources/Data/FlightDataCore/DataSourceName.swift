/// A compile-time datasource name.
///
/// Named datasources are the mechanism for multiple stores (or multiple
/// databases of the same store): a store package's `FlightModule` is
/// instantiated per named datasource, registering its components under a qualifier
/// matching the name. `FlightModule` requires `init()` (Flight Core), so
/// the name cannot be passed to a module instance — it is carried in the
/// module's *type* instead, exactly as `FlightWebModule<Transport>` carries
/// its transport:
///
/// ```swift
/// enum Analytics: DataSourceName { static let name = "analytics" }
///
/// await Flight.run(
///     configuration: try Configuration.load(),
///     modules: [PostgresDataModule<Analytics>.self],
///     composedBy: flightComposeModules
/// )
/// ```
///
/// Each generic instantiation is a distinct module type, so the module DAG and
/// health tracking distinguish them with no extra machinery.
///
/// **One datasource module of a given store per application, for now.** Two
/// instantiations — `<PrimaryDataSource>` and `<Analytics>` — both provide the
/// same type, `PostgresDataSource`, and composition keys registrations by type
/// alone, so listing both fails the build with "two modules provide
/// PostgresDataSource". The generic parameter names the *configuration key*,
/// not the provided type. Modules of different stores (`ValkeyDataModule` beside
/// `PostgresDataModule`) coexist fine, because their provided types differ.
public protocol DataSourceName {
    /// The name as it appears in configuration (`datasource.<name>.…`) and
    /// as the registration qualifier for the datasource's components.
    static var name: String { get }
}

/// The conventional default datasource (`primary`). Apps with one
/// database never need to define their own `DataSourceName`.
public enum PrimaryDataSource: DataSourceName {
    public static let name = "primary"
}
