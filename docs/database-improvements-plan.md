# Database improvements: implementation and PR plan

Approved scope: PRs 1–4 below, implemented, independently reviewed, and merged sequentially. PR 5 (permanent report versions) is explicitly excluded at the user’s request. Access-control and existing result-locking fixes remain in scope.

Keep the existing client → order → sample → worksheet → result structure. Preserve current order-level report grouping unless a separate product decision changes it. These are incremental changes, not a backend replacement.

## PR 1 — Protect access and issued results

- Restrict client lookup and worksheet creation to explicitly authorized roles; remove anonymous execution of privileged application functions.
- Make issued-result protection work for analysts whose permissions hide the parent order.
- Prevent direct changes to protected relationships or order status from bypassing the lock. Coordinate result updates and issuance against the same order lock.
- Add a disposable local database test harness that replays the existing SQL and supplies synthetic authentication roles/users.
- Test denied anonymous/client access, allowed staff operations, and denied edits to issued results for every application role.

This is a prerequisite for reliable report preservation, although it was outside the seven schema explanations.

## PR 2 — Keep references and numbering consistent

Covers: correct report/sample relationships, permanent client identifiers, and independent reference-number generation.

- Introduce order creation that accepts a client UUID. Update the form to pass the selected client's UUID; retire or temporarily wrap old entry points without keeping the broken name lookup.
- Ensure each report draft's order is the order containing its sample. Prefer deriving the order; a composite foreign key is an acceptable compatibility step.
- Replace record-count/max-based allocation with atomic counters per document type and year. Seed counters from existing identifiers without renumbering historical records.
- Preserve current display formats and document their capacity limits.
- Audit inconsistent existing relationships before enforcing constraints; report ambiguous records rather than silently guessing.
- Test multiple branches with the same client name, invalid references, concurrent allocations, deletion followed by creation, and year rollover.

## PR 3 — Identify staff and record changes

Covers: stable personnel references and reliable change history.

- Link laboratory participants to laboratory_staff, which is distinct from application user accounts. Store the signed-in actor separately from the analyst or reviewer credited with the work.
- Update staff selection in the application and retain readable legacy attribution.
- Backfill references only when names/initials identify exactly one person. Preserve ambiguous historical text for explicit reconciliation.
- Record meaningful changes to results and report workflow, including actor, database-generated time, previous/new values, and correction reason where required.
- Protect audit records from ordinary editing/deletion and provide authorized read access.
- Save a worksheet's related changes in one transaction and detect stale edits so concurrent users do not silently overwrite each other.
- Test attribution, renames, inactive staff, ambiguous legacy values, rollback on partial failures, stale edits, and audit access restrictions.

## PR 4 — Structure measurements without losing original values

Covers: separate numeric values, qualifiers, and descriptive results.

- Retain the original reported text; add an exact numeric value and qualifier where applicable, or a descriptive value for qualitative tests.
- Support values such as 0.05, <0.05, and “not detected” without forcing all tests into numeric fields.
- Define which combinations are valid and validate them in the database and entry form. Interpret values consistently with the parameter's result type.
- Convert only unambiguous historical values automatically. Keep other values unchanged for review.
- Make the new fields and preserved text consistent through a single write path.
- Test decimal precision, zero, negative values where allowed, qualifiers, qualitative results, invalid combinations, and legacy display compatibility.

## PR 5 — Preserve report versions permanently

Covers: frozen issued reports and explicit correction versions.

- Preserve the parameter name, unit, and method applicable to an analysis rather than resolving historical results solely from the current catalog.
- At issuance, save a complete report snapshot: client/sample details, results, units/methods, personnel attribution, draft content, report number, and issuance metadata.
- Render issued reports from that snapshot. Drafts may continue to reflect editable source data.
- Require every sample to have its required tests and complete results; reject empty worksheets and missing required draft information.
- Issue atomically with validation, audit recording, and protection against concurrent result changes.
- Make repeated issuance safe; corrections create a new version with an author/reason and preserve earlier versions. Explicitly control cancellation/deletion of issued records.
- Label historical snapshots accurately: current records cannot prove exactly what an old report contained at its original issue date. Preserve any original report artifacts and avoid inventing historical certainty.
- Test catalog/client/staff edits after issuance, unchanged historical rendering, repeated requests, corrections, concurrent issuance, empty/missing results, and access to earlier versions.

## Delivery and verification

- Each PR includes its database changes, application updates, and focused database tests. Use additive changes first so application and database deployment can be coordinated safely.
- Target main sequentially after each prerequisite merges. If work is prepared ahead, clearly mark dependent PRs and their required predecessors.
- Before production deployment, compare the actual schema and applied changes with the repository. The audit replayed repository SQL locally; it did not inspect production.
- Establish a migration baseline before enabling automatic deployments. Do not blindly replay all historical SQL or renumber already tracked migrations. Resolve duplicate historical prefixes in the baseline procedure.
- Run a clean migration replay and role/workflow tests in CI. Add merge-triggered database deployment only after the target project, migration baseline, and deployment credentials are configured.
- Run application lint/build and focused UI checks for changed entry/report flows. Exercise upgrades with representative synthetic legacy data as well as an empty database.

The PR boundaries above are an implementation sequence. This planning document does not apply migrations or change production settings.
