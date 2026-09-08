import FlightCore

///: a thin wrapper producing a frozen `Container` from a set of modules
/// without going through full `ServiceGroup` bootstrap — scoping and
/// lifecycle logic don't need real services running.
///
///     let container = try TestContainer.build { InMemoryDataModule<PrimaryDataSource>() }
///
/// Declared module dependencies are honored: instantiated (via `init()`) and
/// configured first, in DAG order, exactly as real bootstrap would.
///
/// Deliberately identical to `FlightWebTesting.TestContainer` — a data test
/// must not need the web package to get a container. If a test target
/// imports both testing libraries, qualify the name
/// (`FlightDataTesting.TestContainer`); hoisting this into a shared
/// flight-testing package is the recorded follow-up (README, delta D6).
public enum TestContainer {

    /// Lets `build { InMemoryDataModule<PrimaryDataSource>() }` and
    /// multi-statement module lists read naturally at test sites.
    @resultBuilder
    public enum ModuleBuilder {
        public static func buildBlock(_ modules: any FlightModule...) -> [any FlightModule] {
            modules
        }
    }

    /// The closure throws because a module that takes its configuration can
    /// fail to build — `try PostgresDataModule(configuration:)` in a block is
    /// the ordinary case now.
    public static func build(
        configuration: Configuration = Configuration(),
        @ModuleBuilder _ modules: () throws -> [any FlightModule]
    ) throws -> Container {
        let instances = try modules()
        let container = Container()
        container.register(Configuration.self, scope: .singleton) { _ in configuration }

        // Same ordering rules as bootstrap (Flight Core step 5). Transitive
        // dependencies the block never named are built here, which is where a
        // module that takes initializer parameters is refused — with a message
        // saying to add the built instance to the block.
        let ordered = try Flight.resolveModuleOrder(instances.map { type(of: $0) })
        for module in try Flight.instantiateModules(ordered, supplying: instances) {
            try module.configure(container)
        }

        try container.freeze()
        return container
    }

    /// A frozen, empty container (plus optional configuration) — enough for
    /// tests that only need `Configuration` or hand-registered components.
    public static func empty(configuration: Configuration = Configuration()) -> Container {
        let container = Container()
        container.register(Configuration.self, scope: .singleton) { _ in configuration }
        // An empty registration set cannot fail eager singleton construction.
        try! container.freeze()
        return container
    }
}
