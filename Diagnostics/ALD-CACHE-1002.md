# ALD-CACHE-1002: A cache argument that is not a literal

**Severity:** error

## Meaning

`allEntries:` is not the literal `true` or `false`, or `excluding:` is not an
array literal of parameter-name string literals.

## Why alula-data rejects it

What a cache annotation evicts, and which parameters make up its key, are
decided at build time — so a reader, and the macro, can see them from the
declaration.

## Fixes

1. Write the value as a literal: `allEntries: true`, `excluding: ["traceID"]`.

## Related

ALD-CACHE-1004.
