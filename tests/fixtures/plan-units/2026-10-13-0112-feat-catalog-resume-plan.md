# Atlas Catalog

A synthetic plan for a fictional book catalog.

## Implementation Units

### U1. Catalog import stage 1

**Goal:** Validate book records without losing the previous catalog snapshot.

**Requirements:** R1: deterministic processing.

**Dependencies:** none

**Files:** `src/catalog/stage-1.py`.

**Approach:** Read a snapshot, validate identifiers, and save the result atomically.

**Patterns to follow:** Use the shared `catalog_state` reader.

**Test scenarios:** Accept valid records; reject missing identifiers; preserve state on failure.

**Verification:** Run the catalog tests and compare snapshots.

### U2. Catalog import stage 2

**Goal:** Validate book records without losing the previous catalog snapshot.

**Requirements:** R2: deterministic processing.

**Dependencies:** U1, U3

**Files:** `src/catalog/stage-2.py`.

**Approach:** Read a snapshot, validate identifiers, and save the result atomically.

**Execution note:** Test each failure before implementing its handler.

**Patterns to follow:** Use the shared `catalog_state` reader.

**Test scenarios:** Accept valid records; reject missing identifiers; preserve state on failure.

**Verification:** Run the catalog tests and compare snapshots.

### U3. Catalog import stage 3

**Goal:** Validate book records without losing the previous catalog snapshot.

**Requirements:** R3: deterministic processing.

**Dependencies:** none

**Files:** `src/catalog/stage-3.py`.

**Approach:** Read a snapshot, validate identifiers, and save the result atomically.

**Patterns to follow:** Use the shared `catalog_state` reader.

**Test scenarios:** Accept valid records; reject missing identifiers; preserve state on failure.

**Verification:** Run the catalog tests and compare snapshots.

### U4. Catalog import stage 4

**Goal:** Validate book records without losing the previous catalog snapshot.

**Requirements:** R4: deterministic processing.

**Dependencies:** U1, U3, U5 (sample records exercise classification)

**Files:** `src/catalog/stage-4.py`.

**Approach:** Read a snapshot, validate identifiers, and save the result atomically.

**Patterns to follow:** Use the shared `catalog_state` reader.

**Test scenarios:** Accept valid records; reject missing identifiers; preserve state on failure.

**Verification:** Run the catalog tests and compare snapshots.

### U5. Catalog import stage 5

**Goal:** Validate book records without losing the previous catalog snapshot.

**Requirements:** R5: deterministic processing.

**Dependencies:** none

**Files:** `src/catalog/stage-5.py`.

**Approach:** Read a snapshot, validate identifiers, and save the result atomically.

**Patterns to follow:** Use the shared `catalog_state` reader.

**Test scenarios:** Accept valid records; reject missing identifiers; preserve state on failure.

**Verification:** Run the catalog tests and compare snapshots.

### U6. Catalog import stage 6

**Goal:** Validate book records without losing the previous catalog snapshot.

**Requirements:** R6: deterministic processing.

**Dependencies:** U4

**Files:** `src/catalog/stage-6.py`.

**Approach:** Read a snapshot, validate identifiers, and save the result atomically.

**Test expectation:** Documentation agrees with catalog behavior.

**Verification:** Run the catalog tests and compare snapshots.

## Verification Contract

Catalog stages preserve valid records and reject invalid inputs.

## Definition of Done

The catalog tests pass without external services.
