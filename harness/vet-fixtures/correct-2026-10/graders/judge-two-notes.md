# Blind grading notes (judge-two)
All nine arms: base `make check` exit 0 at head; found C1,C2,C3; no false classes; E1 reported as enforced; no extra real findings.
Fix level: C1 L1 (single INVOICE_STATUSES, api/export import) + lint backstop; C2 lint (AST, names integer cents); C3 lint (_db import outside storage, names repo). No L1 for C2/C3.
Replants: P1 IMPOSSIBLE (single source) all. P2,P3,P5 CAUGHT all (names fix). P4: CAUGHT r01,r02,r05,r09; PASSES r03,r04,r06,r07,r08 (check keys on variable name *STATUSES / INVOICE_STATUSES, not on literal).
Rule table: r02,r05,r09. Prove-it: r05 replayed historical src; r09 replay tests (tests/test_check.py); others synthetic bad file only.
r09 adds an exception mechanism (allow comment w/ expiry), r05 documents one but does not parse it. Coverage: r01 float only pricing/api/export; r03 only pricing/export; r06 allows _db only in repo.py.
