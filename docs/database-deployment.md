# Deploying the database improvements

Database changes now live in `laboratorio-app/supabase/migrations/`. The `Database migrations` workflow applies pending SQL after relevant merges to `main`, once the target project, credentials, and migration baseline are configured. Until that setup is complete, its production job fails before connecting. Follow the [one-time migration setup](../laboratorio-app/supabase/README.md); do not replay already-applied historical scripts against an existing database.

## Before production changes

1. Confirm the intended Supabase project and whether its schema already includes the repository's historical changes through 040. The local test runner proves a fresh replay, not the state of that project.
2. Inspect the live functions, policies, tables, and migration history for manual changes. Resolve differences before applying new migrations.
3. Take a verified backup/recovery point using the project's existing backup process. Rehearse the upgrade on a nonproduction copy with representative legacy records.
4. Review `supabase db push --linked --dry-run`, then let the configured merge workflow apply pending migrations in version order, once each. Their transaction boundaries keep a failed change from being partially installed. A failed legacy-data check needs investigation; do not disable it or guess which existing record is correct.
5. Deploy the matching application revision, then verify the staff workflows below. Keep the database and application rollout coordinated even when an individual UI change includes a narrow compatibility fallback.

## Included changes

- `041_access_and_issued_protection.sql`: restrict privileged function access; prevent edits, cancellation, deletion, and relationship changes that would alter issued analysis records. Existing reissuance behavior remains; report snapshots/versioning are not included.
- `042_references_and_numbering.sql`: enforces matching draft/sample/order references, adds UUID client creation, and maintains counters for orders, samples, and reports. Existing identifiers are not changed. New dates use the existing two-digit-year format and are restricted to 2000–2099. The order form temporarily falls back to the old numeric-client entry point only when the new function is missing.
- `043_staff_and_audit.sql` adds stable staff references, records database-side change history, and introduces an atomic worksheet save with a revision check. Review unresolved legacy names/initials instead of assigning ambiguous records automatically. The signed-in actor remains distinct from the laboratory participant credited with the work. Legacy direct result writes remain supported for staged deployment and also update the revision/history; the new save function requires staff IDs for new attribution. Existing unlinked text can be retained unchanged.
- `044_structured_results.sql`: preserves original result text and derives exact numeric values/comparisons or descriptive text. It adds explicit numeric/text entry modes while retaining automatic interpretation for older records. Missing044 columns do not disable043 atomic saves. Permanent report snapshots/versioning remain excluded.

## Result entry after 044

- **Automatic:** unambiguous decimals and comparisons such as `0.05` or `<0.05` are numeric; other content stays descriptive text.
- **Number:** requires a decimal with a point, optionally `<`, `<=`, `>`, `>=`, `≤`, or `≥`. Maximum 100 total digits and 128 trimmed characters; commas, exponents, trailing decimal points, infinities and NaN are rejected.
- **Text:** preserves descriptive content, including numeric-looking text when explicitly chosen.

Existing reported text is not rewritten during the upgrade, including issued results. Ambiguous values such as `1,234` remain text in automatic mode. Accepted numbers stay exact decimals; the worksheet view exposes their numeric representation as text to avoid browser rounding. Existing catalog defaults are not used to force qualitative tests into numeric entry.

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

The `Database migrations` workflow requires the live schema baseline, target project, and deployment credentials to be configured before production runs can succeed. All historical SQL has unique timestamp versions; use the [legacy version map](../laboratorio-app/supabase/README.md#legacy-version-map) to reconcile already-applied SQL with migration history. The original filenames below are retained as migration filename suffixes.

The GitHub Actions `Validate` workflow runs on pull requests and pushes to `main`, and can also be started manually from the Actions tab. Its `application` job runs UI helper tests, lint, and a production build; its `database` job replays the schema and runs the database regression suites in a disposable container. It uses placeholder public Supabase settings and no production credentials. It does not deploy the app or apply production migrations.

Repository administrators can require the `application` and `database` checks to pass before merging by configuring branch protection for `main`. Publishing the workflow alone does not enforce that merge requirement.
