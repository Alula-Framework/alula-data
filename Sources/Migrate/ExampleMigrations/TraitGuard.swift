// Compile-time guard: this target exists only when the "Postgres" trait is on.
// Without it the target's driver dependency is pruned and every file here
// fails with "no such module" — this turns that into an actionable message.
#if !Postgres
#error("""
    ExampleMigrations requires the "Postgres" trait.

    Consuming alula-data:
        .package(url: "https://github.com/Alula-Framework/alula-data.git", \
                 from: "0.1.0", traits: ["Postgres"])

    Building alula-data itself:
        swift build --enable-all-traits
    """)
#endif
