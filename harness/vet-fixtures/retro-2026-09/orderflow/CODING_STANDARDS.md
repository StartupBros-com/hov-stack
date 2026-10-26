# Coding standards

Read during review, not during implementation.

- Error messages should match the voice of the surrounding module: terse in
  `src/core` (the caller is code), explanatory in `src/cli` (the caller is a
  person). Judge this against the neighbouring messages in the same file.
- A new abstraction needs two existing call sites, not one anticipated one.
- Prefer default exports for single-export modules.
