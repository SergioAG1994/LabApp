# Deploying the database improvements

Merging these PRs updates application code and SQL source. It does not apply SQL to the hosted Supabase database. No production migration runner is configured. Do not replay all historical scripts against an existing database.

## Before production changes

1. Confirm the intended Supabase project and whether its schema already includes the repository's historical changes through 040. The local test runner proves a fresh replay, not the state of that project.
2. Inspect the live functions, policies, tables, and migration history for manual changes. Resolve differences before applying new migrations.
3. Take a verified backup/recovery point using the project's existing backup process. Rehearse the upgrade on a nonproduction copy with representative legacy records.
4. Apply the new scripts in ascending filename order, once each. Their transaction boundaries keep a failed change from being partially installed. A failed legacy-data check needs investigation; do not disable it or guess which existing record is correct.
5. Deploy the matching application revision, then verify the staff workflows below. Keep the database and application rollout coordinated even when an individual UI change includes a narrow compatibility fallback.

## Included changes

- `041_access_and_issued_protection.sql`: restrict privileged function access; prevent edits, cancellation, deletion, and relationship changes that would alter issued analysis records. Existing reissuance behavior remains; report snapshots/versioning are not included.
- `042_references_and_numbering.sql`: enforces matching draft/sample/order references, adds UUID client creation, and maintains counters for orders, samples, and reports. Existing identifiers are not changed. New dates use the existing two-digit-year format and are restricted to 2000–2099. The order form temporarily falls back to the old numeric-client entry point only when the new function is missing.
- `043_staff_and_audit.sql` adds stable staff references, records database-side change history, and introduces an atomic worksheet save with a revision check. Review unresolved legacy names/initials instead of assigning ambiguous records automatically. The signed-in actor remains distinct from the laboratory participant credited with the work. Legacy direct result writes remain supported for staged deployment and also update the revision/history; the new save function requires staff IDs for new attribution. Existing unlinked text can be retained unchanged.
- Structured measurement changes follow in a separate PR. Permanent report snapshots/versioning are excluded.

## Verification

Run `python3 laboratorio-app/tests/database/run.py` with Docker before deployment. It exercises synthetic roles and data in a disposable, network-isolated PostgreSQL container. Also run `npm run lint` and `npm run build` from `laboratorio-app` using the application's normal public Supabase environment variables. Run `node --test laboratorio-app/tests/ui/*.test.mjs` from the repository root with Node 22.18+ to verify the UI attribution/compatibility helpers.

On the nonproduction upgrade rehearsal, verify:

- An anonymous user cannot retrieve a client through a privileged function. Analysts cannot retrieve client details.
- Reception can create an order and samples. Analysts can edit open results. Authorized staff can issue a complete report.
- Issued results cannot be edited or moved to another worksheet; issued records cannot be unlocked through cancellation or deletion.
- Existing open records remain usable and legacy attribution/result text remains readable.
- Each newly deployed feature's database tests also pass against representative legacy data.

Do not run synthetic write tests against production. Use the project dashboard or authorized read-only inspection to confirm deployed definitions, and observe normal staff workflows after release.

## Automation

Automatic migration deployment should be added only after the live schema baseline and target project have been reconciled and deployment credentials configured. Historical numeric prefixes 016 and 017 each occur twice; do not rename already applied migrations without reconciling their history.

The current GitHub publishing login cannot create workflow files because it lacks `workflow` scope. Until that is resolved, validation is local and required before each PR merge. There is no claim of GitHub CI or production deployment from these PRs.
