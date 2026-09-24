# Database migrations

The `Database migrations` GitHub Actions workflow validates SQL on pull requests
and applies pending migrations after changes under `laboratorio-app/supabase/`,
database tests, or the workflow itself reach `main`. Other application-only merges do not run it.
A manual run from the Actions tab can retry deployment; only `main` can deploy.
Production jobs run one at a time and do not cancel an in-progress migration.
Supabase records applied versions, so successful migrations are skipped on retry.

## One-time production setup

The old SQL files were applied manually. They are now in `migrations/` with unique
14-digit versions; their SQL is unchanged. **Do not push this history into an
existing database until its migration records match the changes already applied.**
The workflow fails before connecting until `SUPABASE_MIGRATIONS_READY` is `true`.
No production history repair or schema changes happen as part of opening this PR.

1. Install Supabase CLI **2.117.0** (the version pinned in the workflow). From
   `laboratorio-app`, authenticate and select the intended project:

   ```sh
   supabase login
   supabase link --project-ref YOUR_PROJECT_REF
   supabase migration list --linked
   ```

   The project reference is the ID in the Supabase dashboard URL, not its API key.
   Confirm the project's PostgreSQL major version in the dashboard and update
   `config.toml` to match if it differs from 17.

2. Reconcile the existing database with the legacy version map below. For each
   file whose changes have **already been applied**, record its new version:

   ```sh
   # Example: only after verifying schema.sql was previously applied.
   supabase migration repair --linked --status applied 20260722000001
   ```

   `migration repair` only updates history; it does not execute SQL. Do not mark
   missing changes as applied, and do not mark every file just because it exists
   in Git. Verify schema objects, function definitions, and data changes against
   the SQL and the team's deployment records. If older migration records already
   exist under different IDs, reconcile those IDs before proceeding. A fresh,
   empty Supabase project needs no repair: all 43 files should be pending.

3. Review the resulting history and pending SQL:

   ```sh
   supabase migration list --linked
   supabase db push --linked --dry-run
   ```

   On an existing project, the pending list must contain only changes that have
   not been applied yet. Stop and reconcile if it includes already-applied SQL.
   A dry run lists pending files; it does not validate their SQL against live data.

4. Add these **repository Actions secrets** in GitHub → Settings → Secrets and
   variables → Actions:

   | Secret | Value |
   | --- | --- |
   | `SUPABASE_ACCESS_TOKEN` | Supabase personal access token with access to the target project |
   | `SUPABASE_DB_PASSWORD` | Target project's database password |
   | `SUPABASE_PROJECT_ID` | Target project's reference ID |

   These are deployment credentials, not the application's public anon key.
   After completing the history review, set the **repository Actions variable**
   `SUPABASE_MIGRATIONS_READY` to `true`. These settings must be supplied before
   the first production run can succeed. If the target project changes, clear
   this variable and repeat the setup for that database.

5. Merge the PR, or run **Database migrations → Run workflow → main** if it was
   already merged. Verify that both validation and production deployment succeed.
   If the database restricts network access, the runner must be allowed to connect.

## Adding a migration

From `laboratorio-app` with the same CLI version and Docker available:

```sh
supabase migration new describe_your_change
# Edit the generated SQL file in supabase/migrations/.
supabase db start
supabase db reset --local --no-seed
supabase stop --no-backup
```

Commit the generated file and open a PR. Use a unique timestamp greater than the
latest migration on `main`; rebase and adjust an unmerged timestamp if needed.
Do not edit, delete, or renumber migrations after they have deployed. Make further
changes in a new migration. The PR workflow rejects invalid/duplicate versions
and applies the full history to a disposable database without production secrets,
then runs the existing role/access and concurrency regression tests.

The CLI applies SQL in version order. A failure stops deployment; previously
successful files remain recorded. Inspect the failed SQL and database state before
retrying. Never automatically repair history or reset the remote database to make
CI pass. Use a reviewed forward migration for rollback when appropriate.

Application hosting is independent of this workflow. Use backward-compatible
schema changes when the app and database may deploy in either order.

## Legacy version map

These versions encode import order, not the original execution times. The old
filename is retained as a suffix for traceability. The privilege fix for normalized
relationships follows its dependency, before the later template cleanup; the
previous duplicate `016` and `017` prefixes are no longer migration IDs.

| Original file | Supabase version |
| --- | --- |
| `schema.sql` | `20260722000001` |
| `002_orders_rpc.sql` | `20260722000002` |
| `003_sample_intake.sql` | `20260722000003` |
| `004_report_issuance_fields.sql` | `20260722000004` |
| `005_cancel_entries.sql` | `20260722000005` |
| `006_permanent_delete_entries.sql` | `20260722000006` |
| `007_restore_cancelled_entries.sql` | `20260722000007` |
| `008_nom001_2021_24h_template.sql` | `20260722000008` |
| `009_correct_nom001_2021_units.sql` | `20260722000009` |
| `010_analysis_order_row_details.sql` | `20260722000010` |
| `011_nom001_2021_exact_template.sql` | `20260722000011` |
| `012_reconcile_lab_domain.sql` | `20260722000012` |
| `013_worksheet_report_action.sql` | `20260722000013` |
| `014_client_directory.sql` | `20260722000014` |
| `015_seed_excel_analysis_packages.sql` | `20260722000015` |
| `016_normalize_analysis_order_sample_relationships.sql` | `20260722000016` |
| `017_restrict_normalized_relationship_functions.sql` | `20260722000017` |
| `016_secure_excel_analysis_packages.sql` | `20260722000018` |
| `017_remove_unused_sample_parameters.sql` | `20260722000019` |
| `018_consolidate_analysis_rows.sql` | `20260722000020` |
| `019_remove_parameter_aggregation.sql` | `20260722000021` |
| `020_sync_worksheet_marker.sql` | `20260722000022` |
| `021_remove_empty_legacy_packages.sql` | `20260722000023` |
| `022_add_parameter_formal_name.sql` | `20260722000024` |
| `023_multi_sample_analysis_workflow.sql` | `20260722000025` |
| `024_multi_package_creator_index.sql` | `20260722000026` |
| `025_multi_sample_lookup_indexes.sql` | `20260722000027` |
| `026_automatic_sample_numbers.sql` | `20260722000028` |
| `027_use_multi_package_name_as_analysis_label.sql` | `20260722000029` |
| `028_staff_sample_list.sql` | `20260722000030` |
| `029_reception_creates_parameters.sql` | `20260722000031` |
| `030_add_client_branch.sql` | `20260722000032` |
| `031_sync_parameter_catalog.sql` | `20260722000033` |
| `032_correct_cot_formal_name.sql` | `20260722000034` |
| `033_reception_updates_parameters.sql` | `20260722000035` |
| `034_clients_by_branch.sql` | `20260722000036` |
| `035_lock_exported_analysis_orders.sql` | `20260722000037` |
| `036_report_preview_drafts.sql` | `20260722000038` |
| `037_report_draft_sample_identification.sql` | `20260722000039` |
| `038_laboratory_staff.sql` | `20260722000040` |
| `039_staff_sample_analysis.sql` | `20260722000041` |
| `040_save_custom_analysis_package.sql` | `20260722000042` |
| `041_access_and_issued_protection.sql` | `20260722000043` |

See Supabase's [migration guide](https://supabase.com/docs/guides/deployment/database-migrations)
and [CI deployment guide](https://supabase.com/docs/guides/deployment/managing-environments).
