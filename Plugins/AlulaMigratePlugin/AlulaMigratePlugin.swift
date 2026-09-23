import Foundation
import PackagePlugin

/// Build tool plugin for migration targets.
///
/// Attach to the SwiftPM target that holds migration files:
///
/// ```swift
/// .target(
///     name: "Migrations",
///     dependencies: [.product(name: "AlulaMigrate", package: "alula-migrate")],
///     plugins: [.plugin(name: "AlulaMigratePlugin", package: "alula-migrate")]
/// )
/// ```
///
/// The plugin runs `alula-migrate-gen` over the target's sources and compiles the
/// generated `_allMigrations()` registry into the target. Discovery is therefore
/// compile-time and deterministic: malformed or duplicate timestamp prefixes fail the
/// build instead of surprising a deploy.
@main
struct AlulaMigratePlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let module = target as? SourceModuleTarget else { return [] }

        let inputs = module.sourceFiles(withSuffix: ".swift").map(\.url)
        let output = context.pluginWorkDirectoryURL
            .appendingPathComponent("AlulaMigrateRegistry.swift")
        let tool = try context.tool(named: "alula-migrate-gen")

        return [
            .buildCommand(
                displayName: "AlulaMigrate: generating migration registry for \(module.name)",
                executable: tool.url,
                arguments: ["--target-name", module.name, "--output", output.path]
                    + inputs.map(\.path),
                inputFiles: inputs,
                outputFiles: [output]
            )
        ]
    }
}
