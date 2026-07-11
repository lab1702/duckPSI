# duckPSI — Population Stability Index in pure DuckDB SQL

PSI as four DuckDB table macros. No extensions, no UDFs — load one SQL file
and compare any two tables.

```
PSI = Σ over bins of (cur% − ref%) · ln(cur% / ref%)
```

## Requirements

DuckDB ≥ 1.3 (uses Python-style lambda syntax and `query_table`). Tested on 1.5.4.

## Setup

```sql
.read psi_macros.sql
```

## Usage

Continuous variables (model scores, amounts — anything castable to DOUBLE):

```sql
-- summary: one row
SELECT * FROM psi('scores_2024q1', 'scores_2024q2', 'score');
-- ┌─────────┬────────────────┬────────────────┬───────────┬──────────┬──────────┐
-- │   psi   │ interpretation │ bins_requested │ bins_used │ ref_rows │ cur_rows │
-- ├─────────┼────────────────┼────────────────┼───────────┼──────────┼──────────┤
-- │  0.0847 │ stable         │             10 │        10 │   100000 │    98000 │

-- diagnosis: one row per bin
SELECT * FROM psi_detail('scores_2024q1', 'scores_2024q2', 'score', bins := 20);
```

Categorical variables (segments, product codes — anything castable to VARCHAR):

```sql
SELECT * FROM psi_cat('customers_jan', 'customers_jun', 'segment');
SELECT * FROM psi_cat_detail('customers_jan', 'customers_jun', 'segment');
```

Views work anywhere a table name is accepted, so any query can be PSI'd:

```sql
CREATE VIEW ref AS SELECT score FROM predictions WHERE month = '2024-01';
CREATE VIEW cur AS SELECT score FROM predictions WHERE month = '2024-06';
SELECT * FROM psi('ref', 'cur', 'score');
```

## Interpretation

| PSI | Label |
|---|---|
| < 0.10 | `stable` |
| 0.10 – 0.25 | `moderate shift` |
| ≥ 0.25 | `significant shift` |

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `bins` | `10` | Number of quantile bins (continuous macros only); must be `>= 1` |
| `eps` | `1e-4` | Floor applied to each bin proportion inside the PSI term, so empty bins contribute a large-but-finite amount instead of ±∞ |

## Semantics and edge cases

- **Binning** (continuous): cut points are `quantile_cont` of the *reference*
  population at `i/bins`. Both populations are bucketed against the same cuts.
  Bins are half-open `[lo, hi)`; a value exactly on a cut belongs to the upper
  bin. The first/last bins extend to ±∞, so current values outside the
  reference range land in the edge bins rather than being dropped.
- **Tied data**: duplicate cut points are deduplicated; `bins_used` in the
  summary reports the effective count (can be less than `bins_requested`).
- **Reported vs clamped**: `ref_pct` / `cur_pct` columns are the true
  proportions; the `eps` floor applies only inside `psi_contrib`.
- **NULLs**: excluded for continuous macros (`ref_rows`/`cur_rows` count
  non-NULL values). For categorical macros NULL is its own `'(NULL)'`
  category — a drifting null rate is real drift.
- **Empty inputs**: summaries return `psi = NULL` with interpretation
  `'insufficient data'` instead of erroring.
- **Column matching**: the column name is matched anchored (`^name$`) via
  DuckDB's `COLUMNS()` regex — regex metacharacters in column names are not
  supported.
- **Case sensitivity**: column matching is case-sensitive — a column created
  as `Score` is not matched by `'score'` (the error message suggests the
  right name).
- **`bins` validation**: `bins` must be `>= 1`; values below 1 raise an error
  instead of silently behaving like a single bin.
- **Empty-input detail behavior**: with one side empty, the detail macros
  still return rows — the empty side's `pct` is `NULL` and contributions are
  eps-floored finite values; only the summary macros report `'insufficient
  data'`.
- **NaN handling**: `NaN` values in continuous data are counted (they sort
  above all cut points, landing in the top bin) — they are not excluded like
  `NULL`.
- **`'(NULL)'` collisions**: in categorical macros, a literal string value
  `'(NULL)'` merges with real NULLs into one category.
- **Schema-qualified tables**: names like `'myschema.mytable'` work via
  `query_table`.

## Tests

```sh
duckdb -c ".read test_psi.sql"
```

Prints one PASS/FAIL row per assertion and exits non-zero on any failure.

## License

[MIT](LICENSE)
