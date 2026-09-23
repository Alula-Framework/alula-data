// Compile-time guard: this target exists only when the "Valkey" trait is on.
// Without it the target's driver dependency is pruned and every file here
// fails with "no such module" — this turns that into an actionable message.
#if !Valkey
    #error(
        """
        AlulaSessionsValkey requires the "Valkey" trait.

        Consuming alula-data:
            .package(url: "https://github.com/Alula-Framework/alula-data.git", \
                     from: "0.8.0", traits: ["Valkey"])

        Building alula-data itself:
            swift build --enable-all-traits
        """)
#endif
