# ALD-CACHE-1001: An invalid cache namespace

**Severity:** error

## Meaning

A `@Cacheable`, `@CachePut` or `@CacheEvict` has no `namespace:`, or its
namespace is not a plain string literal, is empty, or uses characters other
than lowercase letters, digits, underscores and dots.

## Why alula-data rejects it

The namespace is the entry's cache identity and its configuration key:
`cache.namespaces.<namespace>` sets its TTL. It must be known at build time,
and it must render as an environment variable a shell can set
(`ALULA_CACHE_NAMESPACES_…`), or the TTL silently cannot be configured.

## Fixes

1. Pass a literal such as `namespace: "product.prices"`.
2. Use lowercase letters, digits, underscores and dots.

## Example

```swift
@Cacheable(namespace: "product.prices")
func price(of id: Product.ID) async throws -> Price
```

## Related

ALD-CACHE-1002.
