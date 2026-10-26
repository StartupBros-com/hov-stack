# Request flow

1. `src/cli/serve.ts` binds the HTTP listener.
2. `src/core/router.ts` matches the path and calls a handler in `src/core/handlers/`.
3. Handlers call repositories in `src/db/`, which own all SQL.
4. Repositories return `Result<T, E>`; handlers map that to a status code.

Handlers never touch the database driver directly.
