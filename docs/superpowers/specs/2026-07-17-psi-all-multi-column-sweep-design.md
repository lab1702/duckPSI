# Design: `psi_all` — multi-column PSI sweep

**Date:** 2026-07-17
**Status:** Approved
**Target:** DuckDB ≥ 1.3, developed and tested against 1.5.4 (uses `UNPIVOT`
over `COLUMNS(*)`, `query_table()`, `duckdb_columns()`, grouped
`approx_quantile`)

## Goal

One call that runs PSI across every shared column of two tables and returns one
row per column, sorted so the biggest drift is on top:

```sql
SELECT * FROM psi_all('features_q1', 'features_q2');
```

This is how PSI is used in practice — sweep a whole feature table, then drill
into the drifting column with the existing `psi_detail` / `psi_cat_detail`.
This supersedes the original spec's non-goal "CSI over multiple columns at
once" (2026-07-11 design), which deferred exactly this feature.

## Deliverables

| File | Change |
|---|---|
| `psi_macros.sql` | `psi_all` macro + internal `_psi_all_long` helper appended; existing macros untouched |
| `test_psi.sql` | New fixtures/assertions in the existing conventions, above the report block |
| `README.md` | Usage, output schema, dispatch table, edge-case semantics, agreement caveat |

## Public interface

One new table macro; the existing four macros and `psi_interpret` are
unchanged.

```sql
psi_all(ref_tbl, cur_tbl, bins := 10, eps := 1e-4, exclude := [])
```

- `bins` / `eps` apply uniformly to every column, with the same defaults and
  meaning as the single-column macros (`bins < 1` errors).
- `exclude` is a list of column names (exact, case-sensitive match) to skip —
  for IDs, keys, and other columns whose PSI is noise. Excluded columns
  produce no output row.

Output: one row per non-excluded column that appears in either table, ordered
by `psi DESC NULLS LAST, column ASC`:

| Column | Type | Meaning |
|---|---|---|
| `column` | VARCHAR | column name |
| `kind` | VARCHAR | `'continuous'` or `'categorical'` — how the column was analyzed |
| `status` | VARCHAR | `'ok'`, `'ref only'`, `'cur only'`, `'type mismatch'` |
| `psi` | DOUBLE | total PSI; NULL when uncomputable |
| `interpretation` | VARCHAR | via shared `psi_interpret` (NULL → `'insufficient data'`) |
| `groups` | INT | effective bins used (continuous) or category count (categorical); NULL for one-sided columns |
| `ref_rows` | BIGINT | same counting rules as the single-column macros: non-NULL values for continuous, all rows for categorical; 0 on a missing side |
| `cur_rows` | BIGINT | ditto |

There is deliberately no `psi_all_detail`: drill-down belongs to the existing
per-column detail macros.

## Type dispatch

Kind is decided from the **declared catalog type** (`duckdb_columns()`),
independently per side:

- **Continuous** — numeric types (`TINYINT`/`SMALLINT`/`INTEGER`/`BIGINT`/
  `HUGEINT`, unsigned variants, `FLOAT`, `DOUBLE`, `DECIMAL(…)`) and the
  temporal types `DATE`, `TIMESTAMP`, `TIMESTAMP WITH TIME ZONE`. Temporal
  values are converted to epoch seconds, so quantile binning is over time —
  "did the event-date distribution shift" is a meaningful answer.
- **Categorical** — everything else (`VARCHAR`, `BOOLEAN`, `ENUM`, `UUID`,
  `TIME`, `INTERVAL`, `BLOB`, nested types), cast to VARCHAR exactly like
  `psi_cat`.

Cross-side rules:

- Both sides continuous (any mix of numeric/temporal widths, e.g. INT vs
  DOUBLE) → continuous, `status = 'ok'`.
- Sides disagree on kind (e.g. DOUBLE in ref, VARCHAR in cur) → analyzed as
  **categorical** (VARCHAR comparison is always defined) with
  `status = 'type mismatch'` — usually schema drift worth surfacing, so it is
  flagged rather than silent or fatal.
- Column present on one side only → row with `psi = NULL`,
  `status = 'ref only'` / `'cur only'`, `kind` from the side that has it,
  counts from that side and 0 on the other. Schema drift is visible instead of
  silently ignored, and never aborts the sweep.

## Semantics inherited unchanged from the single-column macros

- Quantile cuts come from the **reference** side only, at `i/bins`, via the
  same `approx_quantile` (T-Digest) sketch; duplicates deduplicated;
  effective count reported in `groups`.
- Half-open `[lo, hi)` bins with ±∞ edge bins; NaN lands in the top bin.
- Epsilon floor applies only inside the PSI contribution term.
- Continuous NULLs excluded; categorical NULL is the `'(NULL)'` category (and
  a literal `'(NULL)'` string merges with it, as documented).
- A column present in both tables but empty/all-NULL on one side →
  `psi = NULL`, `'insufficient data'`, `status = 'ok'` (the schema matched;
  the data was insufficient).

**Agreement caveat (documented in README):** categorical rows match
`psi_cat` exactly. Continuous rows can differ from a per-column `psi()` call
within approximate-quantile sketch noise (cut points are already documented as
not bit-exact reproducible); interpretation labels are unaffected in practice.

## Table-name resolution

`query_table()` reads the data; `duckdb_columns()` supplies the types. The
catalog match accepts a bare table/view name or `'schema.table'`, matched
case-insensitively (mirroring how `query_table` resolves identifiers). A bare
name that matches tables in more than one schema raises a descriptive
`error(...)` instead of guessing. Views work exactly like tables (verified:
`duckdb_columns()` lists view columns).

## Algorithm

Long-format reshape, then grouped PSI math — a small constant number of scans
of each input regardless of column count (versus 2 scans *per column* when
calling `psi()` N times). The single-column macros remain the fast path for
one column: per-value bin assignment here uses list operations, not the native
`histogram()` aggregate, because `histogram(x, bounds)` cannot take per-group
bounds.

1. **Reshape** (internal helper macro `_psi_all_long(tbl)`): each table becomes
   `(col VARCHAR, v VARCHAR)` via
   `UNPIVOT (SELECT coalesce(COLUMNS(*)::VARCHAR, '(NULL)') FROM query_table(tbl)) ON COLUMNS(*)`.
   The coalesce sentinel is load-bearing: UNPIVOT drops NULL cells. `'(NULL)'`
   doubles as the categorical NULL category; in the continuous path it fails
   `try_cast` and is thereby excluded, reproducing the NULL-exclusion rule.
   The VARCHAR round trip is exact for DOUBLE (DuckDB uses shortest-round-trip
   float formatting; verified over 100k random values).
2. **Catalog dispatch**: `duckdb_columns()` filtered to each table →
   `(column, kind)` per side → full outer join by name → per-column `kind` and
   `status`; `exclude`d names dropped.
3. **Categorical branch**: long rows for categorical columns, grouped by
   `(col, category)`, counts full-outer-merged between sides per column,
   percentages via window sums partitioned by `col`, eps-floored contribution
   term — `psi_cat_detail`'s math in grouped form — then aggregated to one row
   per column.
4. **Continuous branch**: value extracted as `try_cast(v AS DOUBLE)`, with an
   epoch fallback for temporal columns (`epoch` over a `try_cast` to
   TIMESTAMP/TIMESTAMPTZ; the exact cast chain is pinned during
   implementation, with the requirement that every DATE/TIMESTAMP/TIMESTAMPTZ
   value round-trips through VARCHAR to a non-NULL epoch — probe-tested like
   the mechanisms below). Grouped `approx_quantile` over reference values yields per-column
   cut lists (verified working grouped). Each value's bin is computed against
   its column's cut list (count of cuts `<= v`, preserving the upper-bin rule
   for values exactly on a cut). A per-column bin scaffold generated from the
   cut lists guarantees empty bins contribute; window sums partitioned by
   `col` derive totals — `psi_detail`'s math in grouped form.
5. **Assembly**: union both branches plus the one-sided rows, apply
   `psi_interpret`, order by `psi DESC NULLS LAST, column`.

Feasibility of every load-bearing mechanism was probe-verified on DuckDB
1.5.4 before this design was written: UNPIVOT + `COLUMNS(*)::VARCHAR` +
coalesce inside a table macro over `query_table`; `duckdb_columns()` inside a
macro, including views; exact DOUBLE round-trip; timestamp round-trip to
epoch; grouped `approx_quantile`.

## Error handling

- `bins < 1` → `error('bins must be >= 1')` (same as `psi_detail`).
- Unresolvable table name → `query_table`'s natural error.
- Table resolvable but not matchable in the catalog, or a bare name ambiguous
  across schemas → descriptive `error(...)`.
- No shared columns → the one-sided status rows only; zero columns at all →
  empty result. Neither is an error.
- Empty tables → rows with `psi = NULL`, `'insufficient data'`.

## Testing

Extends `test_psi.sql` in its existing conventions (fixtures + assertions
above the report block, PASS/FAIL rows, non-zero exit on failure):

1. **Dispatch:** INT/DOUBLE/DECIMAL → continuous; TIMESTAMP/DATE → continuous
   with epoch binning; VARCHAR/BOOLEAN → categorical.
2. **Agreement:** on a mixed-type fixture, `psi_all`'s categorical rows equal
   `psi_cat` exactly; continuous rows equal `psi()` within tolerance.
3. **Status rows:** one-sided columns (`'ref only'` / `'cur only'`) with NULL
   psi and correct one-sided counts; kind-mismatched column analyzed as
   categorical with `'type mismatch'`.
4. **`exclude`:** excluded column produces no row; others unaffected.
5. **NULL and NaN handling:** continuous excludes NULLs from counts and puts
   NaN in the top bin; categorical surfaces `'(NULL)'` drift.
6. **Parameters:** non-default `bins` and `eps` take effect.
7. **Degenerate inputs:** empty side → `'insufficient data'`; no shared
   columns → status rows only.
8. **Ordering and shape:** `psi DESC NULLS LAST, column` order; `groups`,
   `ref_rows`, `cur_rows` values correct per kind.
9. **Ambiguity error:** same table name in two schemas + bare-name call →
   descriptive error.

## Non-goals

- `psi_all_detail` (drill down with the existing per-column detail macros).
- Include-lists or pattern-based column selection (`exclude` plus views cover
  it).
- Weighted PSI, time-series PSI windows, non-DuckDB dialects (unchanged from
  the original design).
- Temporal support beyond DATE/TIMESTAMP/TIMESTAMPTZ (`TIME`, `INTERVAL` are
  categorical).
