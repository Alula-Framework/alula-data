// The changeset layer — Changeset, ValidationRule/CrossFieldRule,
// TableModel/TableColumn, ValidatedChanges — was extracted to the
// standalone `swift-changeset` package (module `Changesets`) on 2026-08-21,
// Hangar consumes changesets directly and cannot
// depend on Alula, so the layer now lives where both can reach it.
//
// AlulaDataCore's own public API traffics in those types (the DataSource
// apply seam, AlulaDataTesting's InMemory driver), so it re-exports the
// module: every existing consumer — alula-data-postgres,
// alula-data-valkey, the Demo app — keeps compiling with a single
// `import AlulaDataCore`.
@_exported import Changesets
