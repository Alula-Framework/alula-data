// A repository file imports AlulaDataPostgres and writes @Entity types,
// @Repository types, and repo.all(...) — one import covers the whole
// surface: Alula Core (Container, @Repository, @Inject),
// Alula Data Core (DataSource seam), Hangar (the query layer: @Entity,
// Query, Repo, changesets via its Changesets re-export), and PostgresNIO's
// connection types (via Hangar's re-export).
@_exported import AlulaCore
@_exported import AlulaDataCore
@_exported import Hangar
