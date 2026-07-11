# Design: Population Stability Index (PSI) macros in pure DuckDB SQL

**Date:** 2026-07-11
**Status:** Approved
**Target:** DuckDB ≥ 1.3 (Python-style lambda syntax; developed and tested against 1.5.4)

## Goal

Provide the PSI statistical method as reusable, pure-SQL DuckDB macros: load one
SQL file into any DuckDB session and compare a reference (expected) population
against a current (actual) population with a single `FROM psi(...)` call. No
extensions, no UDFs, no client-side code.

## Background

PSI measures distribution shift between two populations over the same variable:

```
PSI = Σ_bins (cur_pct − ref_pct) · ln(cur_pct / ref_pct)
```

Conventional interpretation thresholds:

| PSI | Label |
|---|---|
| < 0.10 | `stable` |
| 0.10 – 0.25 | `moderate shift` |
| ≥ 0.25 | `significant shift` |

## Deliverables

| File | Contents |
|---|---|
| `psi_macros.sql` | All macro definitions, `CREATE OR REPLACE MACRO`, idempotent, loadable via `.read` |
| `test_psi.sql` | Self-checking test suite; emits one row per assertion with a PASS/FAIL column |
| `README.md` | Usage examples, interpretation table, edge-case semantics |

## Public interface

Four **table macros**. Table names and column names are passed as strings and
resolved with `query_table()` and `COLUMNS()` (verified working on DuckDB 1.5.4).

### Continuous variables

```sql
FROM psi('ref_table', 'cur_table', 'score');                     -- summary
FROM psi('ref_table', 'cur_table', 'score', bins := 20);         -- custom bins
FROM psi_detail('ref_table', 'cur_table', 'score');              -- per-bin rows
```

- `psi(ref, cur, col, bins := 10, eps := 1e-4)` → single row:
  `psi DOUBLE, interpretation VARCHAR, bins_requested INT, bins_used INT,
  ref_rows BIGINT, cur_rows BIGINT`
- `psi_detail(ref, cur, col, bins := 10, eps := 1e-4)` → one row per bin:
  `bin INT, bin_range VARCHAR, lo DOUBLE, hi DOUBLE, ref_count BIGINT,
  cur_count BIGINT, ref_pct DOUBLE, cur_pct DOUBLE, psi_contrib DOUBLE`.
  `lo` is NULL for the first bin and `hi` is NULL for the last bin (open ends).
  `bin_range` renders as `'< c1'`, `'[ck, ck+1)'`, and `'>= cn'` respectively.

### Categorical variables

```sql
FROM psi_cat('ref_table', 'cur_table', 'segment');               -- summary
FROM psi_cat_detail('ref_table', 'cur_table', 'segment');        -- per-category
```

- `psi_cat(ref, cur, col, eps := 1e-4)` → single row:
  `psi DOUBLE, interpretation VARCHAR, categories INT, ref_rows BIGINT, cur_rows BIGINT`
- `psi_cat_detail(ref, cur, col, eps := 1e-4)` → one row per category:
  `category VARCHAR, ref_count BIGINT, cur_count BIGINT, ref_pct DOUBLE,
  cur_pct DOUBLE, psi_contrib DOUBLE`

The summary macros are thin wrappers aggregating the corresponding detail
macros, so the PSI math exists in exactly one place per variant.

## Algorithm

### Continuous binning

1. Compute cut points as quantiles of the **reference** population:
   `quantile_cont(v, i/bins for i in 1 .. bins−1)`.
2. Deduplicate cut points (heavily tied data can produce duplicate quantiles).
   The effective bin count (`bins_used`) may therefore be lower than requested;
   it is reported in the summary output.
3. Bucket **both** populations against the same cuts. Bins are half-open
   `[lo, hi)`; a value equal to a cut point belongs to the upper bin. Bin 1 is
   `(−∞, cut_1)` and the last bin is `[cut_last, +∞)`, so current-population
   values outside the reference range land in the edge bins instead of being
   dropped.
4. Build the bin scaffold from the cut list (not from observed data), so bins
   empty in both populations still appear in the detail output.
5. `ref_pct = ref_count / ref_total`, same for `cur_pct`.
6. Per-bin contribution uses epsilon-floored proportions (below).

Alternative considered: NTILE-based binning on the reference with per-tile
min/max as edges. Rejected — more moving parts, same result, and quantile cuts
match the textbook definition directly.

### Categorical binning

One bin per distinct value across the **union** of both populations (full outer
join on the value cast to VARCHAR). A category present on only one side gets
count 0 on the other and is rescued by the epsilon floor.

### Epsilon floor (empty bins)

Each proportion is clamped with `greatest(pct, eps)` (default `eps = 1e-4`)
before computing `(cur − ref) · ln(cur / ref)`. No renormalization — this is
the standard industry fix and keeps well-populated bins untouched. Reported
`ref_pct` / `cur_pct` columns show the **true** (unclamped) proportions; only
the contribution term uses the clamped values.

### NULL handling

- **Continuous:** NULLs are excluded from both populations before binning
  (documented in README). `ref_rows` / `cur_rows` report non-NULL counts.
- **Categorical:** NULL becomes its own `'(NULL)'` category — a drifting null
  rate is real drift worth surfacing.

### Degenerate inputs

- Empty (or all-NULL) reference or current table → summary returns `psi = NULL`
  with interpretation `'insufficient data'` rather than erroring.
- Reference with a single distinct value → all cut points collapse; one bin;
  PSI is 0 against an identical current population, positive otherwise via the
  epsilon floor.

## Testing

Pure-SQL assertions in `test_psi.sql`; each test emits a row with a name and
PASS/FAIL, and the suite is run with `duckdb -c ".read test_psi.sql"`.

1. **Identity:** `psi(t, t, col)` = 0 (within 1e-12) for continuous and categorical.
2. **Known values:** tiny hand-computed datasets, tolerance-based comparison of
   total PSI and individual bin contributions.
3. **Shift sanity:** a location-shifted distribution yields PSI > 0, and a
   bigger shift yields a bigger PSI.
4. **Empty-bin path:** category / bin absent in current population produces a
   finite contribution via the epsilon floor.
5. **Tied values:** duplicate quantile cuts collapse; `bins_used < bins_requested`.
6. **NULL handling:** continuous excludes NULLs; categorical shows `'(NULL)'`.
7. **Non-default `bins` and `eps`** parameters take effect.
8. **Degenerate inputs** return `'insufficient data'` instead of erroring.

Additionally, one representative case is cross-checked against an independent
Python/numpy PSI computation if Python is available on the development machine
(verification step, not part of the shipped test suite).

## Non-goals

- Weighted PSI, CSI over multiple columns at once, time-series PSI windows.
- Handling of table names requiring schema qualification beyond what
  `query_table()` supports.
- Non-DuckDB dialects.
