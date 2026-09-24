// swift-tools-version: 6.3
import CompilerPluginSupport
import Foundation
import PackageDescription

// Alula Data: persistence and caching.
//
// The abstractions and the drivers live together because they break together
// — a change to the DataSource contract breaks every adapter at once, and
// keeping them in one package makes that a compile error in CI rather than a
// discovery weeks later in whichever adapter nobody rebuilt.
//
// The heavy drivers are gated behind traits so that co-location costs nothing.
// SwiftPM does not prune a package's dependencies by which product you use,
// but it *does* prune dependencies that no enabled trait reaches. Without
// traits, an application wanting only the in-memory cache would resolve
// PostgresNIO, valkey-swift, NIOSSL, and swift-crypto; with them it resolves
// none of those.
//
//     .package(url: "...alula-data.git", from: "0.11.0")                      // cache + protocols
//     .package(url: "...alula-data.git", from: "0.11.0", traits: ["Postgres"]) // + Postgres
//
// Building this package itself: `swift test --enable-all-traits`.
let package = Package(
    name: "alula-data",
    platforms: [.macOS(.v15)],
    products: [
        // Always available — no database or cache driver required.
        .library(name: "AlulaCache", targets: ["AlulaCache"]),
        .library(name: "AlulaCacheTesting", targets: ["AlulaCacheTesting"]),
        .library(name: "AlulaDataCore", targets: ["AlulaDataCore"]),
        .library(name: "AlulaDataTesting", targets: ["AlulaDataTesting"]),
        .library(name: "AlulaMigrateCore", targets: ["AlulaMigrateCore"]),
        .plugin(name: "AlulaMigratePlugin", targets: ["AlulaMigratePlugin"]),

        // Requires the "Postgres" trait.
        .library(name: "AlulaDataPostgres", targets: ["AlulaDataPostgres"]),
        .library(name: "AlulaSchedulerPostgres", targets: ["AlulaSchedulerPostgres"]),
        .library(name: "AlulaMigrate", targets: ["AlulaMigrate"]),
        .library(name: "AlulaMigrateCLI", targets: ["AlulaMigrateCLI"]),

        // Requires the "Valkey" trait.
        .library(name: "AlulaCacheValkey", targets: ["AlulaCacheValkey"]),
        .library(name: "AlulaDataValkey", targets: ["AlulaDataValkey"]),
        .library(name: "AlulaPubSubValkey", targets: ["AlulaPubSubValkey"]),
        .library(name: "AlulaSessionsValkey", targets: ["AlulaSessionsValkey"]),
        .library(name: "AlulaRateLimitValkey", targets: ["AlulaRateLimitValkey"]),
    ],
    traits: [
        // Opt-in: name a driver to get it, and resolve nothing else.
        //
        //     traits: []                    cache and protocols only, no driver
        //     traits: ["Postgres"]          + PostgresNIO, Hangar, migrations
        //     traits: ["Postgres", "Valkey"] both
        //
        // Requires Swift 6.3 or later. Through 6.2.x, SwiftPM did not resolve
        // the gated dependencies of a non-default trait enabled on a
        // *versioned* dependency (swiftlang/swift-package-manager #9286,
        // fixed by #9269) — path dependencies worked, so it only showed up
        // once this package was tagged.
        .default(enabledTraits: []),
        .trait(
            name: "Postgres",
            description: "PostgreSQL data source, migrations, and the migration CLI."
        ),
        .trait(
            name: "Valkey",
            description: "Valkey-backed distributed cache and data source."
        ),
    ],
    dependencies: [
        // traits: [] — alula-data needs only the container and lifecycle,
        // never AlulaWeb. Opting out of alula's default "Web" trait keeps
        // Hummingbird, NIO, and the TLS stack out of every consumer that
        // wants a cache or a data source but not an HTTP server.
        .package(url: "https://github.com/Alula-Framework/alula.git", from: "0.37.0", traits: []),
        .package(url: "https://github.com/Alula-Framework/swift-changeset.git", from: "0.2.0"),
        .package(url: "https://github.com/Alula-Framework/hangar.git", from: "0.9.2"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.5.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "601.0.0"..<"999.0.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.8.0"),
        // Reached only through the Postgres trait.
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
        // Reached only through the Valkey trait.
        .package(url: "https://github.com/valkey-io/valkey-swift.git", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.0"),
    ],
    targets: [
        // MARK: Cache — no driver required

        .macro(
            name: "AlulaCacheMacrosImpl",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
            ],
            path: "Sources/Cache/AlulaCacheMacrosImpl"
        ),
        .target(
            name: "AlulaCache",
            dependencies: [
                "AlulaCacheMacrosImpl",
                .product(name: "AlulaCore", package: "alula"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "OrderedCollections", package: "swift-collections"),
            ],
            path: "Sources/Cache/AlulaCache",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AlulaCacheTesting",
            dependencies: ["AlulaCache"],
            path: "Sources/Cache/AlulaCacheTesting",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Data protocols — no driver required

        .target(
            name: "AlulaDataCore",
            dependencies: [
                .product(name: "AlulaCore", package: "alula"),
                .product(name: "Changesets", package: "swift-changeset"),
            ],
            path: "Sources/Data/AlulaDataCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AlulaDataTesting",
            dependencies: [
                "AlulaDataCore",
                .product(name: "AlulaCore", package: "alula"),
            ],
            path: "Sources/Data/AlulaDataTesting",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .target(
            name: "AlulaSchedulerPostgres",
            dependencies: [
                "AlulaDataCore",
                "AlulaDataPostgres",
                .product(name: "AlulaScheduler", package: "alula"),
                // Gated, like every other Postgres-facing target here: an
                // ungated dependency makes a trait-free consumer resolve
                // PostgresNIO, which is exactly what the lean-consumer check
                // exists to catch — and did.
                .product(
                    name: "PostgresNIO", package: "postgres-nio",
                    condition: .when(traits: ["Postgres"])),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Scheduler/AlulaSchedulerPostgres",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .target(
            name: "AlulaPubSubValkey",
            dependencies: [
                .product(name: "AlulaCore", package: "alula"),
                .product(name: "AlulaPubSub", package: "alula"),
                .product(
                    name: "Valkey", package: "valkey-swift",
                    condition: .when(traits: ["Valkey"])),
                .product(
                    name: "NIOSSL", package: "swift-nio-ssl",
                    condition: .when(traits: ["Valkey"])),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Sources/PubSub/AlulaPubSubValkey",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Migrations — the core and generator are driver-free

        .target(name: "AlulaMigrateCore", path: "Sources/Migrate/AlulaMigrateCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(
            name: "alula-migrate-gen",
            dependencies: ["AlulaMigrateCore"],
            path: "Sources/Migrate/alula-migrate-gen",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .plugin(
            name: "AlulaMigratePlugin",
            capability: .buildTool(),
            dependencies: ["alula-migrate-gen"]
        ),

        // MARK: Postgres — requires the "Postgres" trait

        .target(
            name: "AlulaMigrate",
            dependencies: [
                "AlulaMigrateCore",
                .product(name: "PostgresNIO", package: "postgres-nio", condition: .when(traits: ["Postgres"])),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Migrate/AlulaMigrate",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AlulaMigrateCLI",
            dependencies: [
                "AlulaMigrate",
                "AlulaMigrateCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser", condition: .when(traits: ["Postgres"])),
            ],
            path: "Sources/Migrate/AlulaMigrateCLI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ExampleMigrations",
            dependencies: ["AlulaMigrate"],
            path: "Sources/Migrate/ExampleMigrations",
            swiftSettings: [.swiftLanguageMode(.v6)],
            plugins: ["AlulaMigratePlugin"]
        ),
        .executableTarget(
            name: "alula-migrate-example",
            dependencies: ["AlulaMigrateCLI", "ExampleMigrations"],
            path: "Sources/Migrate/alula-migrate-example",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AlulaDataPostgres",
            dependencies: [
                "AlulaDataCore", "AlulaMigrate",
                .product(name: "AlulaCore", package: "alula"),
                .product(name: "Hangar", package: "hangar", condition: .when(traits: ["Postgres"])),
                .product(name: "PostgresNIO", package: "postgres-nio", condition: .when(traits: ["Postgres"])),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Sources/Data/AlulaDataPostgres",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Valkey — requires the "Valkey" trait

        .target(
            name: "AlulaCacheValkey",
            dependencies: [
                "AlulaCache",
                .product(name: "AlulaCore", package: "alula"),
                .product(name: "Valkey", package: "valkey-swift", condition: .when(traits: ["Valkey"])),
                .product(name: "NIOSSL", package: "swift-nio-ssl", condition: .when(traits: ["Valkey"])),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Sources/Cache/AlulaCacheValkey",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Sessions over Valkey. Depends on the cache adapter for the URL
        // grammar and the driver configuration builder — the second copy of
        // each was already one too many, and the third would be this file.
        .target(
            name: "AlulaSessionsValkey",
            dependencies: [
                "AlulaCacheValkey",
                .product(name: "AlulaCore", package: "alula"),
                .product(name: "AlulaSessions", package: "alula"),
                .product(name: "Valkey", package: "valkey-swift", condition: .when(traits: ["Valkey"])),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Sources/Sessions/AlulaSessionsValkey",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Rate limiting over Valkey: GCRA as one EVAL. Depends on the cache
        // adapter for the URL grammar and the driver configuration builder,
        // the same way the session store does.
        .target(
            name: "AlulaRateLimitValkey",
            dependencies: [
                "AlulaCacheValkey",
                .product(name: "AlulaCore", package: "alula"),
                .product(name: "AlulaRateLimit", package: "alula"),
                .product(name: "Valkey", package: "valkey-swift", condition: .when(traits: ["Valkey"])),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Sources/RateLimit/AlulaRateLimitValkey",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AlulaDataValkey",
            dependencies: [
                "AlulaDataCore",
                .product(name: "AlulaCore", package: "alula"),
                .product(name: "Valkey", package: "valkey-swift", condition: .when(traits: ["Valkey"])),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Sources/Data/AlulaDataValkey",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Tests

        .testTarget(
            name: "AlulaCacheTests",
            dependencies: [
                "AlulaCache", "AlulaCacheTesting",
                .product(name: "AlulaCore", package: "alula"),
            ],
            path: "Tests/Cache/AlulaCacheTests"
        ),
        .testTarget(
            name: "AlulaCacheMacroTests",
            dependencies: [
                "AlulaCacheMacrosImpl",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
            ],
            path: "Tests/Cache/AlulaCacheMacroTests"
        ),
        .testTarget(
            name: "AlulaDataCoreTests",
            dependencies: [
                "AlulaDataCore", "AlulaDataTesting",
                .product(name: "AlulaCore", package: "alula"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Tests/Data/AlulaDataCoreTests"
        ),
        .testTarget(
            name: "AlulaMigrateTests",
            dependencies: ["AlulaMigrate", "AlulaMigrateCore", "AlulaMigrateCLI", "ExampleMigrations"],
            path: "Tests/Migrate/AlulaMigrateTests"
        ),
        .testTarget(
            name: "AlulaSchedulerPostgresTests",
            dependencies: [
                "AlulaSchedulerPostgres",
                .product(name: "AlulaScheduler", package: "alula"),
            ],
            path: "Tests/Scheduler/AlulaSchedulerPostgresTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AlulaDataPostgresTests",
            dependencies: [
                "AlulaDataPostgres", "AlulaDataCore", "AlulaDataTesting", "AlulaMigrate",
                .product(name: "AlulaCore", package: "alula"),
                .product(name: "PostgresNIO", package: "postgres-nio", condition: .when(traits: ["Postgres"])),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Tests/Data/AlulaDataPostgresTests"
        ),
        .testTarget(
            name: "AlulaCacheValkeyTests",
            dependencies: [
                "AlulaCacheValkey", "AlulaCache", "AlulaCacheTesting",
                .product(name: "AlulaCore", package: "alula"),
                .product(name: "Valkey", package: "valkey-swift", condition: .when(traits: ["Valkey"])),
            ],
            path: "Tests/Cache/AlulaCacheValkeyTests"
        ),
        .testTarget(
            name: "AlulaRateLimitValkeyTests",
            dependencies: [
                "AlulaRateLimitValkey",
                .product(name: "AlulaCore", package: "alula"),
                .product(name: "AlulaRateLimit", package: "alula"),
                .product(name: "Valkey", package: "valkey-swift", condition: .when(traits: ["Valkey"])),
            ],
            path: "Tests/RateLimit/AlulaRateLimitValkeyTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AlulaSessionsValkeyTests",
            dependencies: [
                "AlulaSessionsValkey",
                .product(name: "AlulaCore", package: "alula"),
                .product(name: "AlulaSessions", package: "alula"),
                .product(name: "AlulaSessionsTesting", package: "alula"),
                .product(name: "Valkey", package: "valkey-swift", condition: .when(traits: ["Valkey"])),
            ],
            path: "Tests/Sessions/AlulaSessionsValkeyTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AlulaPubSubValkeyTests",
            dependencies: [
                "AlulaPubSubValkey",
                .product(name: "AlulaCore", package: "alula"),
                .product(name: "AlulaPubSub", package: "alula"),
                .product(
                    name: "Valkey", package: "valkey-swift",
                    condition: .when(traits: ["Valkey"])),
            ],
            path: "Tests/PubSub/AlulaPubSubValkeyTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AlulaDataValkeyTests",
            dependencies: [
                "AlulaDataValkey", "AlulaDataCore", "AlulaDataTesting",
                .product(name: "AlulaCore", package: "alula"),
                .product(name: "Valkey", package: "valkey-swift", condition: .when(traits: ["Valkey"])),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Tests/Data/AlulaDataValkeyTests"
        ),
    ]
)

// Documentation tooling only, gated so that consumers never resolve it.
if ProcessInfo.processInfo.environment["ALULA_BUILD_DOCS"] != nil {
    package.dependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.3.0")
    )
}

// Strict warnings, opt-in and scoped to Alula's own targets.
//
// `swift build -Xswiftc -warnings-as-errors` cannot be used for this: it
// applies to every module in the build, dependencies included, so a warning
// in third-party code that a newer compiler has already fixed fails the
// build. This setting reaches only the targets declared above.
//
//     ALULA_STRICT_WARNINGS=1 swift build --enable-all-traits
if ProcessInfo.processInfo.environment["ALULA_STRICT_WARNINGS"] != nil {
    // Plugin targets reject build settings outright.
    for target in package.targets where target.type != .plugin {
        var settings = target.swiftSettings ?? []
        settings.append(.treatAllWarnings(as: .error))
        target.swiftSettings = settings
    }
}
