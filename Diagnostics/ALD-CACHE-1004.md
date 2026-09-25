# ALD-CACHE-1004: A cache key parameter the macro cannot use

**Severity:** error

## Meaning

A parameter that would make up the cache key has no internal name
(`func f(_: Int)`), or `excluding:` names a parameter the method does not have.

## Why alula-data rejects it

The key is built from parameters by internal name, and `excluding:` removes
them by the same name. A parameter with no name cannot be used either way,
and a misspelled exclusion would silently change the key.

## Fixes

1. Name the parameter: `func f(_ id: Int)`.
2. Correct the name in `excluding:`, or remove it.

## Related

ALD-CACHE-1002.
