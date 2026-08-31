# Interview prep

Five questions the build guide flags as certain to come up. Every fact
below is real — pulled from this project's actual commits, actual query
output, and actual bugs found and fixed, not invented for the interview.
Practice both lengths out loud; the 90-second version is what you lead
with, the 5-minute version is what you have ready when they say "go
deeper."

---

## 1. "Walk me through what happens when a bank restates a prior quarter."

### 90 seconds

The landing zone is append-only and content-addressed — a corrected file
never overwrites the original, it lands at a new SHA-256 path. A dbt
snapshot watches the raw table with a `check` strategy on the amount
column; when a restated value shows up, the snapshot closes the old
version row (`dbt_valid_to` gets set) and opens a new one (`dbt_valid_from`
= now). Staging exposes those as `known_from_ts`/`known_to_ts` — knowledge
time, not business time. The mart's incremental logic filters on
`known_from_ts > max(already loaded)`, never on `reporting_period_end` —
that's the part that actually matters, because a restatement of a
two-year-old period arrives with an *old* business date but a *new*
knowledge timestamp. Filter on the wrong one and you silently drop it
forever.

I proved this for real, not just asserted it: changed one figure in a
landed file, reloaded, re-snapshotted, ran the mart incrementally — the
`MERGE` touched exactly one row, and that row's value updated to the new
figure while every other row was untouched.

### 5 minutes

Add: the natural key problem this depends on. The base key (institution +
return + period + line item) isn't actually unique — OSFI republishes the
same line item under two accounting bases during a standards transition
(IAS 39 wording vs. IFRS 9 wording), so there's a `variant_seq` in the
key, ordered by `(return_title, label)` — not label alone, because 162 of
270 duplicate groups have byte-identical label text and label-only
ordering silently falls back to physical row order, which I proved is
*not stable* for at least one institution (traced it down to two
line-items whose subtotal identity requires opposite pairing conventions
in the same file pull — there's no single row-order rule that's correct
for both, so that institution-period is quarantined rather than guessed
at).

Also worth having ready: `int_filings__restatement_events.sql` isn't a
side effect, it's a first-class model — restatement frequency by
institution is a dashboard tile specifically because it's a genuinely rare
thing to show in a portfolio project and it's real signal about data
quality practices at the source institution.

**If pushed on "what's the catch":** restatement history only exists from
whenever this pipeline started running. It has no visibility into
restatements that happened before that — a real production system running
for years would have real history; this one currently shows 4 events, and
they're my own injected test restatement, not a genuine OSFI republication
(I haven't left it running long enough to catch a real one yet — see the
build guide's own advice on this).

---

## 2. "How do you know your numbers are right?"

### 90 seconds

A control registry — 21 controls, each mapped to a BCBS 239 principle,
with a category, severity, and owner. Every control run gets logged by an
`on-run-end` hook into an audit table, joined back to the registry, and
aggregated into a scorecard: pass rate by category, breach detail with
severity, trailing 30-day trend. And they use a materiality tolerance, not
exact equality — OSFI reports in thousands and rounds, so an exact-match
reconciliation would false-fail on real, correct data.

Then the actual tie-out: I computed RBC's total assets from the raw
filings and checked it against their real published Q2 2026 report — off
by $299K on a $2.4 trillion base. That's the number I'd lead with in an
interview, because it's independently verifiable against something the
interviewer could look up themselves.

### 5 minutes

Add: I don't just claim the controls pass — I show my work on where they
*don't*. REC-002 (subtotal rollup) is scoped to M4 only, not because I
didn't try it on P3/E3, but because I found — by direct query, not
assumption — that P3/E3's granular detail-line codes are essentially
unfiled in current-era data (one code's declared children: 5 of 6 have
zero rows anywhere in the scoped data). Extending REC-002 there would mean
evaluating zero real comparisons and creating an illusion of coverage that
isn't real, so I didn't.

Same honesty on REC-004/REC-005: both need OSFI codes (dividends declared,
P3's own retained-earnings rollforward) that have zero rows anywhere in
the loaded data. I considered an approximation that dropped the missing
term and rejected it — it would systematically false-fail every
profitable, dividend-paying institution every quarter, which trains
whoever's watching the scorecard to ignore it. A control that reliably
cries wolf is worse than no control.

**If pushed on methodology:** the NIM/ROA/ROE numbers specifically are
verified against RBC's actual disclosures, not just internally
consistent — computed NIM (~1.4-1.5%), ROE (~13-17%), and efficiency ratio
(~52-60%) all land inside RBC's real published range for the same
quarters. That's a stronger claim than "my code doesn't error."

---

## 3. "What breaks if the source changes?"

### 90 seconds

The extractor asserts a pinned schema before it ever lands a file — if a
*consumed* (contract-critical) column disappears or gets renamed, it
raises loudly and refuses to land; a non-consumed column drifting only
warns. Row count has a floor and a growth ceiling, both checked against a
pinned baseline, to catch a truncated download or an unexplained volume
spike. Source freshness thresholds are tied to the actual publication
calendar — OSFI's monthly/quarterly cadence gets 45/75-day warn/error
windows, Bank of Canada's daily cadence gets 2/5 days. And CI catches a
broken model or control before it merges: slim CI runs only
`state:modified+`, deferring everything unchanged to the last known-good
prod state.

### 5 minutes

Add the two times this actually happened, for real, not hypothetically:
OSFI changed M4's deposit line-item codes around 2008-2009 — I found this
because REC-001 failed on 1,712 of 3,533 rows with variances up to ~$214B,
traced it to 8 of 12 deposit codes having zero rows before ~2009, and the
fix wasn't a patch to the code list, it was applying the 5-year scope
window that was always the documented design intent but had never
actually been wired into staging. Same pattern, independently confirmed,
for P3: a `net_income` code that simply doesn't exist before 2011.

**If pushed on "how would you catch it faster next time":** honestly, I'd
add a control that watches for a code's *presence* going to zero across a
scope boundary, not just its value being wrong — right now that class of
break only surfaces when a downstream reconciliation control happens to
fail loudly enough to investigate.

---

## 4. "What would you do differently at scale?"

### 90 seconds

Real orchestration instead of the Dagster-local/GitHub-Actions-schedule
split I have now — those are deliberately two different systems today
(Dagster gives a demoable local asset graph, Actions runs the actual
cron), which is an honest trade-off for a portfolio project but not how
I'd run it for real. Alerting to PagerDuty or Slack on a control breach,
not just a scorecard someone has to remember to check. Data contracts
enforced at ingestion, not caught three models downstream. Genuinely
separate dev/staging/prod projects, with real least-privilege IAM per
service. Cost governance — bytes-billed caps per query, budget alerts.

### 5 minutes

Add the specific, concrete gap this project actually has, because it's
more convincing than a generic list: dev and prod currently share the
*exact same physical BigQuery tables* for anything with a custom schema —
a Phase 5 design decision (clean dataset names, no `dbt_dev_finance` /
`dbt_prod_finance` clutter) that I only fully reckoned with in Phase 9,
when I found it meant a CI run against an unreviewed PR could have
overwritten the same tables a scheduled prod pipeline serves from, before
the PR was even merged. I fixed CI specifically (isolated, disposable
schemas) but left dev/prod sharing tables, because for a solo developer
that's a genuine, bounded trade-off — at scale, with more than one person
touching `dev`, it wouldn't be.

Also real: I reused one service account for both the extraction pipeline
and the Evidence dashboard connector, rather than provisioning a
dashboard-specific least-privilege one, because the IAM API was disabled
on this GCP project and enabling it plus granting new roles was a bigger
step than the situation warranted. At scale, that's not a judgment call
you get to make — every service gets its own least-privilege identity.

---

## 5. "What's the weakest part of this?"

Answer this one *first*, unprompted, if it comes up naturally — it reads
as more confident than waiting to be asked, and it's the question the
guide is most emphatic about not dodging.

- **Restatement history only from first ingest.** No visibility into
  anything that happened before this pipeline started running.
- **Two controls are structurally impossible against current data**
  (REC-004, REC-005) — not a gap I plan to close, because the source data
  genuinely doesn't exist for them.
- **The line-item hierarchy is one person's judgment call in a handful of
  genuinely ambiguous places.** Parsed from OSFI's Data Dictionary and
  cross-checked against the Validation Rules XLSX, but where those two
  sources didn't fully resolve an edge case, I made the call myself.
- **No real access controls.** Personal GCP project, one person's
  credentials doing everything, broader permissions in a few places than
  a real production system would tolerate (see the service-account reuse
  above).
- **Dev and prod share physical tables**, discussed above — an accepted
  trade-off at this scale, not one I'd defend at any other scale.
- **Neither GitHub Actions workflow has actually run in CI yet** — the
  service account and secrets exist as documented instructions, not as
  configured reality. What I *have* verified is the logic itself: a
  deliberately broken control, run through the same `state:modified+`
  selection CI would use, failed with exit code 1, locally, for real.
- **Power BI wasn't built.** The build guide calls for both Evidence and
  Power BI versions; only Evidence is done, because Power BI Desktop is a
  GUI-only tool I can't drive from a coding environment, and I said so
  rather than skip it silently.

The thread connecting all of these: every one was either found by actually
running something and getting a real, specific number back (not
assumed), or is stated as a scope decision with the reason attached. That
consistency is itself the answer to "how do I know you didn't just get
lucky."
