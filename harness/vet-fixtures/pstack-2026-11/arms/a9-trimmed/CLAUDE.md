# Global Rules

- Resolve ambiguities from code, patterns and context; ask only when truly blocked.
- Identify the full scope of affected components, not just what's mentioned. Diagnose root causes: grep every caller before editing; one guard in the shared function beats one per call site.
- Run linters, type checks, and tests before finalizing; fix every failure before committing.
- Ask before reimplementing an existing feature from scratch; a background job, with nobody to answer, reuses it, or reimplements and says why reuse was impossible.
- Don't remove or narrow existing config, flags, compat surfaces or callers as a side effect of a task that didn't ask for it; flag it instead.
- Make the smallest change that meets the request. Add no option, parameter, abstraction, validator or guard the request or spec didn't ask for.
- If the code refutes the request's premise, say so with the evidence before building what was asked.
