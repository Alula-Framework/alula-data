# ALD-DATA-1001: A data source could not connect at startup

**Severity:** error

## Meaning

At startup, a data source dialled its database and could not connect. A
Postgres data source dials in a before-start hook, before any other service
starts, so this is the only thing reported; a Valkey data source dials when
its service starts. The report names the data source, the host, port and database it
dialled, and what the network or the server answered — never the URL's
password.

## Why alula-data rejects it

An application whose database is unreachable would start, announce that it is
listening, and fail every request that needs the pool. Dialling first means
the one line that says why is the first thing an operator reads.

## Common causes

- The database is not running, or not yet accepting connections.
- A wrong host or port in `datasource.<name>.url`.
- A wrong password (`authentication failed`, SQLSTATE 28P01) or database name
  (`the database does not exist`, 3D000).

## Fixes

1. Start the database, or wait for it — in a container setup, order the
   application after the database's health check.
2. Correct `datasource.<name>.url`, or the environment variable that
   overrides it.

## Related

ALU-CONFIG-5004.
