# ALD-CACHE-1003: A method that cannot be cached

**Severity:** error

## Meaning

A cache annotation is on something that is not a function with a body, or on
a method that is not `async`, uses typed throws, or returns nothing.

## Why alula-data rejects it

The cache is asynchronous and there is no blocking store API; coalesced
callers share one error, which is `any Error`; and there is nothing to store
for a method that returns `Void`.

## Fixes

1. Make the method `async`.
2. Use an untyped `throws`.
3. For invalidation without a result, use `@CacheEvict`.

## Related

ALD-CACHE-1005.
