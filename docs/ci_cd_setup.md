# CI/CD setup: service account and GitHub secrets

Phase 9 wires up `.github/workflows/daily_pipeline.yml` (scheduled prod run)
and `.github/workflows/ci.yml` (slim CI on pull requests). Both need a GCP
service account and three GitHub repo secrets. Neither workflow has been
run for real yet -- this is what's needed before they can.

## 1. Create a least-privilege service account

Two roles are enough for this project. Extraction talks to public HTTP
APIs (open.canada.ca, bankofcanada.ca) with no GCP auth; the service
account only ever touches BigQuery.

```bash
gcloud iam service-accounts create bank-reg-platform-ci \
  --project=bank-regulatory-platform \
  --display-name="Bank regulatory platform CI/CD"

gcloud projects add-iam-policy-binding bank-regulatory-platform \
  --member="serviceAccount:bank-reg-platform-ci@bank-regulatory-platform.iam.gserviceaccount.com" \
  --role="roles/bigquery.dataEditor"

gcloud projects add-iam-policy-binding bank-regulatory-platform \
  --member="serviceAccount:bank-reg-platform-ci@bank-regulatory-platform.iam.gserviceaccount.com" \
  --role="roles/bigquery.jobUser"
```

- `bigquery.dataEditor` — create/modify datasets and tables (needed: CI and
  a fresh prod both auto-create their own datasets on first run, e.g.
  `dbt_ci_finance`).
- `bigquery.jobUser` — run query/load jobs.

Deliberately not `roles/bigquery.admin` or a project-wide `editor`/`owner`
role -- neither extraction nor dbt needs IAM, billing, or non-BigQuery
resource management.

## 2. Generate and download the key

```bash
gcloud iam service-accounts keys create bank-reg-platform-ci-key.json \
  --iam-account=bank-reg-platform-ci@bank-regulatory-platform.iam.gserviceaccount.com
```

This file matches the `.gitignore` pattern `gcp-key*.json` -- move it
somewhere outside the repo, or rename it to be extra safe. Never commit it.

## 3. Create the three GitHub repo secrets

Repo Settings -> Secrets and variables -> Actions -> New repository secret:

| Secret name | Value |
|---|---|
| `GCP_SA_KEY` | The **entire contents** of `bank-reg-platform-ci-key.json` (paste the whole JSON file) |
| `GCP_PROJECT_ID` | `bank-regulatory-platform` |
| `BQ_LOCATION` | `northamerica-northeast1` |

`GCP_SA_KEY` is consumed by `google-github-actions/auth@v2` in both
workflows, which authenticates and exports `GOOGLE_APPLICATION_CREDENTIALS`
automatically for subsequent steps -- no extra wiring needed.

## 4. Refreshing `transform/prod-manifest/manifest.json`

`ci.yml` runs `dbt build --select state:modified+ --defer --state
./prod-manifest --target ci`, which needs a manifest from the last known
good `prod` state to diff against. It's a committed file (the one
`.gitignore` exception to the repo's broad `*.json` rule), not
regenerated automatically.

**Bootstrap** (already done once for this repo): run the full pipeline
against `prod` locally, then copy the manifest in:

```bash
cd transform
dbt seed --target prod && dbt snapshot --target prod && dbt build --target prod
cp target/manifest.json prod-manifest/manifest.json
git add prod-manifest/manifest.json
git commit -m "Refresh prod-manifest after <describe the prod change>"
```

**Ongoing refresh**: once `daily_pipeline.yml` is running for real, the
cleanest path is to add a step at the end of that workflow that commits
`target/manifest.json` back into `prod-manifest/` (e.g. via
`git-auto-commit-action`) whenever the prod build succeeds -- not yet
wired up, since it means giving the workflow push access to `main`. Until
then, refresh it manually the same way as the bootstrap, after any change
that touches prod models/tests.

If `prod-manifest` goes stale (doesn't reflect prod's actual current
state), `state:modified+` will either miss real changes (comparing against
an outdated baseline) or flag false positives -- it will not silently
corrupt anything, since `--defer` only affects *unselected* upstream refs,
but a stale baseline does weaken what CI actually proves.

## Checkpoint

Verified locally (not yet in real GitHub Actions, since that needs the
secrets above): a deliberately broken control (`REC-001`'s tolerance
expression changed to an always-false condition) was picked up by
`state:modified+` -- exactly 1 test selected out of 44 -- and failed with
shell exit code 1. Reverted immediately after. Once the secrets exist,
opening a PR with the same kind of change should produce a red check on
GitHub for the same reason.
