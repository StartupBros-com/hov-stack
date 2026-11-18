# Atlas Catalog

A synthetic plan for a fictional book catalog.

## Implementation Units

### U1. Workflow draft gate

**Goal:** Validate book records without losing the previous catalog snapshot.

**Requirements:** R1: deterministic processing.

**Dependencies:** none.

**Files:** `src/catalog/stage-1.py`.

**Approach:** Read a snapshot, validate identifiers, and save the result atomically.

**Execution note:** Test each failure before implementing its handler.

**Patterns to follow:** Use the shared `catalog_state` reader.

**Test scenarios:** Accept valid records; reject missing identifiers; preserve state on failure.

**Verification:** Run the catalog tests and compare snapshots.

### U2. Local result record

**Goal:** Validate book records without losing the previous catalog snapshot.

**Requirements:** R2: deterministic processing.

**Dependencies:** none.

**Files:** `src/catalog/stage-2.py`.

**Approach:** Read a snapshot, validate identifiers, and save the result atomically.

**Patterns to follow:** Use the shared `catalog_state` reader.

**Test scenarios:** Accept valid records; reject missing identifiers; preserve state on failure.

**Verification:** Run the catalog tests and compare snapshots.

### U3. Shared head-checks helper and the ready-head readers

**Goal:** Validate book records without losing the previous catalog snapshot.

**Requirements:** R3: deterministic processing.

**Dependencies:** none for the helper; catalog readers arrive together.

**Files:** `src/catalog/stage-3.py`.

**Approach:** Read a snapshot, validate identifiers, and save the result atomically.

**Patterns to follow:** Use the shared `catalog_state` reader.

**Test scenarios:** Accept valid records; reject missing identifiers; preserve state on failure.

**Verification:** Run the catalog tests and compare snapshots.

### U4. Draft paths for the loop-driving readers

**Goal:** Validate book records without losing the previous catalog snapshot.

**Requirements:** R4: deterministic processing.

**Dependencies:** U2, U3.

**Files:** `src/catalog/stage-4.py`.

**Approach:** Read a snapshot, validate identifiers, and save the result atomically.

**Patterns to follow:** Use the shared `catalog_state` reader.

**Test scenarios:** Accept valid records; reject missing identifiers; preserve state on failure.

**Verification:** Run the catalog tests and compare snapshots.

### U5. Owner ready sequence

**Goal:** Validate book records without losing the previous catalog snapshot.

**Requirements:** R5: deterministic processing.

**Dependencies:** U2, U3, U4.

**Files:** `src/catalog/stage-5.py`.

**Approach:** Read a snapshot, validate identifiers, and save the result atomically.

**Patterns to follow:** Use the shared `catalog_state` reader.

**Test scenarios:** Accept valid records; reject missing identifiers; preserve state on failure.

**Verification:** Run the catalog tests and compare snapshots.

### U6. Doctrine and vocabulary

**Goal:** Validate book records without losing the previous catalog snapshot.

**Requirements:** R6: deterministic processing.

**Dependencies:** none; accompanies U1 to U5.

**Files:** `src/catalog/stage-6.py`.

**Approach:** Read a snapshot, validate identifiers, and save the result atomically.

**Patterns to follow:** Use the shared `catalog_state` reader.

**Test scenarios:** Accept valid records; reject missing identifiers; preserve state on failure.

**Verification:** Run the catalog tests and compare snapshots.

### U7. Measurement modes

**Goal:** Validate book records without losing the previous catalog snapshot.

**Requirements:** R7: deterministic processing.

**Dependencies:** U5 for the catalog status fields.

**Files:** `src/catalog/stage-7.py`.

**Approach:** Read a snapshot, validate identifiers, and save the result atomically.

**Patterns to follow:** Use the shared `catalog_state` reader.

**Test scenarios:** Accept valid records; reject missing identifiers; preserve state on failure.

**Verification:** Run the catalog tests and compare snapshots.

## Verification Contract

Catalog stages preserve valid records and reject invalid inputs.

## Definition of Done

The catalog tests pass without external services.
