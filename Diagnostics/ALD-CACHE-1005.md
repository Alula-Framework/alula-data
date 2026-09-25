# ALD-CACHE-1005: @CacheEvict with nothing to key on

**Severity:** error

## Meaning

A `@CacheEvict` method has no parameter left to derive the entry's key from,
and `allEntries:` is not `true`.

## Why alula-data rejects it

Without a key it cannot name one entry, and evicting the whole namespace is
a decision the declaration should state.

## Fixes

1. Pass `allEntries: true` to evict the whole namespace.
2. Or add the parameter that identifies the entry.

## Example

```swift
@CacheEvict(namespace: "product.prices", allEntries: true)
func repriceEverything() async throws
```

## Related

ALD-CACHE-1004.
