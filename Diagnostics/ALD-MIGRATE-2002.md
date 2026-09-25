# ALD-MIGRATE-2002: A migration file and its type disagree

**Severity:** error

## Meaning

A migration file declares no `Migration` type, more than one, or one whose
name differs from the name in the filename.

## Why alula-data rejects it

The registry is generated from filenames and the types they promise; a file
that disagrees would register the wrong migration or none. The conformance
must be declared at the type definition, where the scan can see it.

## Fixes

1. Declare exactly one type, named as the file says: `struct CreateUsers: Migration { … }`.
2. Rename the file or the type so they match.

## Related

ALD-MIGRATE-2001.
