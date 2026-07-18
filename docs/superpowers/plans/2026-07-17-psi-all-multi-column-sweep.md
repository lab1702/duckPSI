# psi_all Multi-Column Sweep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `psi_all(ref_tbl, cur_tbl, bins := 10, eps := 1e-4, exclude := [])` — one call that runs PSI across every shared column of two tables, one output row per column, biggest drift first.

**Architecture:** Long-format reshape (`UNPIVOT` over `COLUMNS(*)` with a `'(NULL)'` sentinel) plus catalog-driven type dispatch (`duckdb_columns()`), then grouped PSI math partitioned by column name — `psi_cat_detail`'s and `psi_detail`'s formulas in grouped form. Five small internal helper macros keep the main macro readable and DRY. A small constant number of scans per input regardless of column count.

**Tech Stack:** Pure DuckDB SQL macros. No extensions, no UDFs, no client-side code.

**Spec:** `docs/superpowers/specs/2026-07-17-psi-all-multi-column-sweep-design.md`

**Plan amendment vs spec:** the spec names one internal helper (`_psi_all_long`). During prototyping this expanded to five tiny helpers (`_psi_kind`, `_psi_to_double`, `_psi_contrib`, `_psi_all_long`, `_psi_cols`) for DRY — each is a few lines with one purpose. Also, the temporal epoch chain was pinned (probe-verified) to `coalesce(try_cast(v AS DOUBLE), epoch(try_cast(v AS TIMESTAMPTZ)))`: casting through TIMESTAMPTZ honors UTC offsets that a plain TIMESTAMP cast silently drops, and it parses everything TIMESTAMP/DATE strings produce. **All macro SQL in this plan was validated end-to-end against DuckDB 1.5.4 before the plan was written** — agreement with `psi()`/`psi_cat()`, statuses, errors, NaN, empty inputs, and schema-qualified names all confirmed.

## Global Constraints

- DuckDB ≥ 1.3 (Python-style lambdas); developed and tested against 1.5.4.
- Pure SQL: no extensions, no UDFs, no client-side code.
- `psi_macros.sql` stays idempotent: every definition is `CREATE OR REPLACE MACRO`, loadable via `.read psi_macros.sql`.
- The existing macros (`psi`, `psi_detail`, `psi_cat`, `psi_cat_detail`, `psi_interpret`) are **not modified**.
- Test harness conventions: fixtures and `INSERT INTO _results` assertions go **above** the report block in `test_psi.sql` (marked `-- Report (KEEP LAST ...)`); suite must end `0 failed` and exit 0.
- Error paths (`error(...)`) cannot be asserted inside the suite — `error()` aborts the script. They are verified manually with one-off `duckdb -c` commands in the task steps, like the original plan's canary check.
- Run the suite from the repo root: `duckdb -c ".read test_psi.sql"`.
- Commit after each task with the trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Baseline before Task 1: 36 assertions, 0 failed.

---

### Task 1: Internal helper macros

**Files:**
- Modify: `psi_macros.sql` (append helpers at end of file)
- Modify: `test_psi.sql` (insert fixtures + 5 assertions above the report block)

**Interfaces:**
- Consumes: nothing new (existing harness conventions).
- Produces (used verbatim by Task 2's `psi_all`):
  - `_psi_kind(dt VARCHAR) -> VARCHAR` — maps a `duckdb_columns().data_type` string to `'continuous'`/`'categorical'`.
  - `_psi_to_double(v VARCHAR) -> DOUBLE` — long-format value to DOUBLE; temporal strings via epoch; non-numeric/non-temporal (including the `'(NULL)'` sentinel) to NULL.
  - `_psi_contrib(cur_pct, ref_pct, eps) -> DOUBLE` — eps-floored PSI contribution term.
  - `_psi_all_long(tbl VARCHAR)` table macro -> rows `(col VARCHAR, v VARCHAR)` — one row per table cell, NULLs as `'(NULL)'`.
  - `_psi_cols(tbl VARCHAR)` table macro -> rows `(col VARCHAR, kind VARCHAR)` — one row per column; errors on unknown/ambiguous table names.
  - Test fixtures `sweep_ref` (9 columns × 200 rows) and `sweep_cur` (9 columns × 180 rows), reused by Tasks 2–3.

- [ ] **Step 1: Write the failing tests**

In `test_psi.sql`, insert this block immediately **above** the `-- Report (KEEP LAST ...)` banner:

```sql
------------------------------------------------------------------
-- Fixtures: psi_all sweep (mixed-type pair; shared by the psi_all tasks)
------------------------------------------------------------------
CREATE OR REPLACE TABLE sweep_ref AS
SELECT i AS id,
       (i % 10) / 10.0 AS score,
       ((i % 7) * 11.5)::DECIMAL(10,2) AS amount,
       CASE i % 4 WHEN 0 THEN 'a' WHEN 1 THEN 'b' WHEN 2 THEN 'c' ELSE NULL END AS seg,
       i % 2 = 0 AS flag,
       TIMESTAMP '2024-01-01' + INTERVAL (i % 30) DAY AS ts,
       (DATE '2024-01-01' + INTERVAL (i % 30) DAY)::DATE AS d,
       (i % 5)::DOUBLE AS mix,
       i AS only_ref
FROM range(1, 201) t(i);

CREATE OR REPLACE TABLE sweep_cur AS
SELECT i AS id,
       ((i % 10) / 10.0) + 0.25 AS score,                -- shifted
       ((i % 7) * 11.5)::DECIMAL(10,2) AS amount,        -- same distribution
       CASE i % 4 WHEN 0 THEN 'a' WHEN 1 THEN 'a' WHEN 2 THEN 'c' ELSE NULL END AS seg,  -- shifted
       i % 2 = 0 AS flag,                                -- identical proportions
       TIMESTAMP '2024-02-01' + INTERVAL (i % 30) DAY AS ts,   -- shifted one month
       (DATE '2024-01-01' + INTERVAL (i % 30) DAY)::DATE AS d, -- near-identical
       ((i % 5)::DOUBLE)::VARCHAR AS mix,                -- type mismatch vs ref (DOUBLE there)
       'x' || (i % 3)::VARCHAR AS only_cur
FROM range(1, 181) t(i);

------------------------------------------------------------------
-- Tests: psi_all internal helpers
------------------------------------------------------------------
INSERT INTO _results
SELECT 'all-helpers: five internal macros exist',
       coalesce(count(DISTINCT function_name) = 5, false),
       'found ' || count(DISTINCT function_name)::VARCHAR
FROM duckdb_functions()
WHERE function_name IN ('_psi_kind', '_psi_to_double', '_psi_contrib',
                        '_psi_all_long', '_psi_cols');

INSERT INTO _results
SELECT 'all-helpers: _psi_kind type mapping',
       coalesce(_psi_kind('DOUBLE') = 'continuous'
            AND _psi_kind('INTEGER') = 'continuous'
            AND _psi_kind('DECIMAL(10,2)') = 'continuous'
            AND _psi_kind('DATE') = 'continuous'
            AND _psi_kind('TIMESTAMP') = 'continuous'
            AND _psi_kind('TIMESTAMP WITH TIME ZONE') = 'continuous'
            AND _psi_kind('VARCHAR') = 'categorical'
            AND _psi_kind('BOOLEAN') = 'categorical'
            AND _psi_kind('UUID') = 'categorical', false),
       'mapping checked';

INSERT INTO _results
SELECT 'all-helpers: _psi_to_double numeric, temporal, sentinel',
       coalesce(abs(_psi_to_double('0.9') - 0.9) < 1e-12
            AND _psi_to_double('(NULL)') IS NULL
            AND _psi_to_double('abc') IS NULL
            AND isnan(_psi_to_double('nan'))
            AND _psi_to_double('2024-01-06') - _psi_to_double('2024-01-05') = 86400.0
            AND _psi_to_double('2024-01-05 12:30:00') - _psi_to_double('2024-01-05 12:00:00') = 1800.0, false),
       'conversions checked';

INSERT INTO _results
SELECT 'all-helpers: _psi_all_long shape and NULL sentinel',
       coalesce(count(*) = 1800     -- 9 columns x 200 rows
            AND count(*) FILTER (WHERE col = 'seg' AND v = '(NULL)') = 50, false),
       'rows=' || count(*)::VARCHAR
FROM _psi_all_long('sweep_ref');

INSERT INTO _results
SELECT 'all-helpers: _psi_cols kinds for mixed table',
       coalesce(count(*) = 9
            AND bool_and(CASE WHEN col IN ('id', 'score', 'amount', 'ts', 'd', 'mix', 'only_ref')
                              THEN kind = 'continuous'
                              ELSE kind = 'categorical' END), false),
       string_agg(col || ':' || kind, ', ' ORDER BY col)
FROM _psi_cols('sweep_ref');
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `duckdb -c ".read test_psi.sql"`
Expected: aborts with a Catalog/Binder error naming `_psi_kind` (macro does not exist). The 36 pre-existing assertions still bind; the script dies at the first helper assertion.

- [ ] **Step 3: Implement the helpers**

Append to the end of `psi_macros.sql`:

```sql
-- ==================================================================
-- psi_all internal helpers. Underscore-prefixed macros are
-- implementation details of psi_all, not public API.
-- ==================================================================

-- Maps a duckdb_columns().data_type string to the PSI flavor psi_all
-- runs for that column. Numeric and temporal types are continuous
-- (temporal values are compared on the epoch-seconds axis); everything
-- else is categorical.
CREATE OR REPLACE MACRO _psi_kind(dt) AS
  CASE WHEN dt IN ('TINYINT', 'SMALLINT', 'INTEGER', 'BIGINT', 'HUGEINT',
                   'UTINYINT', 'USMALLINT', 'UINTEGER', 'UBIGINT', 'UHUGEINT',
                   'FLOAT', 'DOUBLE', 'DATE', 'TIMESTAMP', 'TIMESTAMP WITH TIME ZONE')
         OR dt LIKE 'DECIMAL%'
       THEN 'continuous' ELSE 'categorical' END;

-- Long-format VARCHAR cell -> DOUBLE. The TIMESTAMPTZ (not TIMESTAMP)
-- cast is deliberate: it parses DATE / TIMESTAMP / TIMESTAMPTZ strings
-- alike AND honors explicit UTC offsets, which a TIMESTAMP cast would
-- silently drop (skewing epochs across DST-mixed data). Non-numeric,
-- non-temporal strings -- including the '(NULL)' sentinel -- yield NULL,
-- which reproduces the continuous NULL-exclusion rule.
CREATE OR REPLACE MACRO _psi_to_double(v) AS
  coalesce(try_cast(v AS DOUBLE), epoch(try_cast(v AS TIMESTAMPTZ)));

-- The eps-floored PSI contribution term (same formula the single-column
-- macros inline).
CREATE OR REPLACE MACRO _psi_contrib(cur_pct, ref_pct, eps) AS
  (greatest(cur_pct, eps) - greatest(ref_pct, eps))
    * ln(greatest(cur_pct, eps) / greatest(ref_pct, eps));

-- Reshapes a table to (col, v) long form, one row per cell. The
-- coalesce sentinel is load-bearing: UNPIVOT drops NULL cells, so NULLs
-- are smuggled through as '(NULL)' -- which doubles as the categorical
-- NULL category. The VARCHAR round trip is exact for DOUBLE (DuckDB
-- prints shortest-round-trip floats).
CREATE OR REPLACE MACRO _psi_all_long(tbl) AS TABLE
  UNPIVOT (SELECT coalesce(COLUMNS(*)::VARCHAR, '(NULL)') FROM query_table(tbl))
  ON COLUMNS(*) INTO NAME col VALUE v;

-- Column catalog for a table or view: (col, kind). Accepts a bare name
-- or 'schema.table', matched case-insensitively (mirroring query_table
-- resolution). Errors if a bare name matches tables in more than one
-- schema (query_table would silently pick one) or matches nothing.
CREATE OR REPLACE MACRO _psi_cols(tbl) AS TABLE
WITH matches AS (
    SELECT database_name, schema_name, table_name, column_name, data_type
    FROM duckdb_columns()
    WHERE NOT "internal"
      AND CASE WHEN contains(tbl, '.')
               THEN lower(schema_name || '.' || table_name) = lower(tbl)
               ELSE lower(table_name) = lower(tbl) END
),
guard AS (
    SELECT CASE
        WHEN count(DISTINCT database_name || '.' || schema_name || '.' || table_name) > 1
          THEN error('psi_all: table name ''' || tbl || ''' matches more than one table; qualify as schema.table')
        WHEN count(*) = 0
          THEN error('psi_all: table ''' || tbl || ''' not found')
        ELSE true END AS ok
    FROM matches
)
SELECT m.column_name AS col, _psi_kind(m.data_type) AS kind
FROM matches m CROSS JOIN guard g
WHERE g.ok;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `duckdb -c ".read test_psi.sql"`
Expected: `41 assertions, 0 failed`, exit code 0.

- [ ] **Step 5: Verify the catalog error paths manually**

```sh
duckdb -c ".read psi_macros.sql" -c "SELECT * FROM _psi_cols('no_such_table');"
```
Expected: `Invalid Input Error: psi_all: table 'no_such_table' not found` (non-zero exit).

```sh
duckdb -c ".read psi_macros.sql" \
       -c "CREATE SCHEMA s1; CREATE TABLE dup (a INT); CREATE TABLE s1.dup (a INT); SELECT * FROM _psi_cols('dup');"
```
Expected: `Invalid Input Error: psi_all: table name 'dup' matches more than one table; qualify as schema.table`.

- [ ] **Step 6: Commit**

```bash
git add psi_macros.sql test_psi.sql
git commit -m "feat: add psi_all internal helper macros"
```

---

### Task 2: The `psi_all` macro

**Files:**
- Modify: `psi_macros.sql` (append `psi_all` after the Task 1 helpers)
- Modify: `test_psi.sql` (insert fixtures + 11 assertions after Task 1's tests, above the report block)

**Interfaces:**
- Consumes: all five Task 1 helpers (exact signatures above); `psi_interpret(p)` from the existing file; fixtures `sweep_ref`/`sweep_cur`; existing fixtures `cat_ab_ref`, `cat_a_cur`.
- Produces: `psi_all(ref_tbl, cur_tbl, bins := 10, eps := 1e-4, exclude := [])` table macro returning
  `("column" VARCHAR, kind VARCHAR, status VARCHAR, psi DOUBLE, interpretation VARCHAR, groups INT, ref_rows BIGINT, cur_rows BIGINT)`
  ordered `psi DESC NULLS LAST, "column"`. Task 3 relies on this exact shape.

- [ ] **Step 1: Write the failing tests**

In `test_psi.sql`, insert after Task 1's helper tests (above the report block):

```sql
------------------------------------------------------------------
-- Tests: psi_all (core)
------------------------------------------------------------------
CREATE OR REPLACE VIEW sweep_ref_ts AS SELECT epoch(ts) AS ts_e FROM sweep_ref;
CREATE OR REPLACE VIEW sweep_cur_ts AS SELECT epoch(ts) AS ts_e FROM sweep_cur;

INSERT INTO _results
SELECT 'all: macro exists',
       coalesce(count(*) >= 1, false),
       'found ' || count(*)::VARCHAR
FROM duckdb_functions() WHERE function_name = 'psi_all';

INSERT INTO _results
SELECT 'all: one row per column with correct kinds',
       coalesce(count(*) = 10
            AND bool_and(CASE WHEN "column" IN ('id', 'score', 'amount', 'ts', 'd')
                              THEN kind = 'continuous' AND status = 'ok'
                              WHEN "column" IN ('seg', 'flag')
                              THEN kind = 'categorical' AND status = 'ok'
                              ELSE true END), false),
       string_agg("column" || ':' || kind || ':' || status, ', ' ORDER BY "column")
FROM psi_all('sweep_ref', 'sweep_cur');

INSERT INTO _results
SELECT 'all: continuous column agrees with psi()',
       coalesce(abs(
           (SELECT psi FROM psi_all('sweep_ref', 'sweep_cur') WHERE "column" = 'score')
         - (SELECT psi FROM psi('sweep_ref', 'sweep_cur', 'score'))) < 1e-9, false),
       'score compared';

INSERT INTO _results
SELECT 'all: DECIMAL column agrees with psi()',
       coalesce(abs(
           (SELECT psi FROM psi_all('sweep_ref', 'sweep_cur') WHERE "column" = 'amount')
         - (SELECT psi FROM psi('sweep_ref', 'sweep_cur', 'amount'))) < 1e-9, false),
       'amount compared';

INSERT INTO _results
SELECT 'all: categorical column equals psi_cat()',
       coalesce(abs(
           (SELECT psi FROM psi_all('sweep_ref', 'sweep_cur') WHERE "column" = 'seg')
         - (SELECT psi FROM psi_cat('sweep_ref', 'sweep_cur', 'seg'))) < 1e-12, false),
       'seg compared';

INSERT INTO _results
SELECT 'all: timestamp column matches psi() over an epoch view',
       coalesce(abs(
           (SELECT psi FROM psi_all('sweep_ref', 'sweep_cur') WHERE "column" = 'ts')
         - (SELECT psi FROM psi('sweep_ref_ts', 'sweep_cur_ts', 'ts_e'))) < 1e-9, false),
       'ts compared';

INSERT INTO _results
SELECT 'all: identical boolean distribution is exactly zero',
       coalesce(abs((SELECT psi FROM psi_all('sweep_ref', 'sweep_cur') WHERE "column" = 'flag')) < 1e-12
            AND (SELECT groups FROM psi_all('sweep_ref', 'sweep_cur') WHERE "column" = 'flag') = 2, false),
       'flag checked';

INSERT INTO _results
SELECT 'all: groups and row counts per kind',
       coalesce(
           max(CASE WHEN "column" = 'score' THEN groups END) = 10
       AND max(CASE WHEN "column" = 'seg' THEN groups END) = 4   -- a, b, c, (NULL)
       AND bool_and(CASE WHEN status = 'ok' THEN ref_rows = 200 AND cur_rows = 180 ELSE true END), false),
       'groups/rows checked'
FROM psi_all('sweep_ref', 'sweep_cur');

INSERT INTO _results
SELECT 'all: sorted by psi desc, nulls last',
       coalesce(
           (SELECT "column" FROM psi_all('sweep_ref', 'sweep_cur') LIMIT 1) = 'ts'
       AND (SELECT bool_and(psi IS NULL)
            FROM (SELECT psi FROM psi_all('sweep_ref', 'sweep_cur') OFFSET 8)), false),
       'order checked';

INSERT INTO _results
SELECT 'all: bins parameter forwarded',
       coalesce(
           (SELECT groups FROM psi_all('sweep_ref', 'sweep_cur', bins := 4) WHERE "column" = 'score') = 4
       AND abs((SELECT psi FROM psi_all('sweep_ref', 'sweep_cur', bins := 4) WHERE "column" = 'score')
             - (SELECT psi FROM psi('sweep_ref', 'sweep_cur', 'score', bins := 4))) < 1e-9, false),
       'bins=4 checked';

-- Same fixture + eps as the existing 'cat: custom eps changes result' test.
INSERT INTO _results
SELECT 'all: eps parameter forwarded',
       coalesce(abs(
           (SELECT psi FROM psi_all('cat_ab_ref', 'cat_a_cur', eps := 0.01) WHERE "column" = 'seg')
         - 0.217768709935247) < 1e-9, false),
       'eps=0.01 checked';
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `duckdb -c ".read test_psi.sql"`
Expected: the 41 prior assertions bind and run, then the script aborts with a Catalog/Binder error naming `psi_all`.

- [ ] **Step 3: Implement `psi_all`**

Append to the end of `psi_macros.sql`:

```sql
-- ==================================================================
-- psi_all(ref_tbl, cur_tbl, bins := 10, eps := 1e-4, exclude := [])
-- Multi-column PSI sweep: one row per column across both tables,
-- ordered biggest drift first (NULL psi rows last). Kind is dispatched
-- from the DECLARED column type (numeric/temporal -> continuous via
-- psi_detail's math, everything else -> categorical via psi_cat_detail's
-- math); a column whose kind differs between the tables is analyzed as
-- categorical and flagged status = 'type mismatch'; columns present on
-- one side only are flagged 'ref only' / 'cur only' with psi = NULL.
-- exclude lists column names (exact, case-sensitive) to skip entirely.
-- Cost is a small constant number of scans of each input regardless of
-- column count; for a single column, psi()/psi_cat() remain the fast
-- path (native histogram binning vs per-row list ops here). Continuous
-- results can differ from a per-column psi() call within approx-
-- quantile sketch noise; categorical results match psi_cat exactly.
-- ==================================================================
CREATE OR REPLACE MACRO psi_all(ref_tbl, cur_tbl, bins := 10, eps := 1e-4, exclude := []) AS TABLE
WITH
cols AS (
    SELECT coalesce(r.col, c.col) AS col,
           CASE WHEN r.col IS NULL THEN c.kind
                WHEN c.col IS NULL THEN r.kind
                WHEN r.kind = 'continuous' AND c.kind = 'continuous' THEN 'continuous'
                ELSE 'categorical' END AS kind,
           CASE WHEN r.col IS NULL THEN 'cur only'
                WHEN c.col IS NULL THEN 'ref only'
                WHEN r.kind <> c.kind THEN 'type mismatch'
                ELSE 'ok' END AS status
    FROM _psi_cols(ref_tbl) r
    FULL OUTER JOIN _psi_cols(cur_tbl) c ON r.col = c.col
    -- the ::VARCHAR[] cast also types the [] default (untyped otherwise)
    WHERE NOT list_contains(exclude::VARCHAR[], coalesce(r.col, c.col))
),
-- ---- categorical branch: psi_cat_detail's math, partitioned by col ----
cat_ref AS (
    SELECT l.col, l.v AS category, count(*) AS cnt
    FROM _psi_all_long(ref_tbl) l JOIN cols k ON l.col = k.col
    WHERE k.kind = 'categorical'
    GROUP BY 1, 2
),
cat_cur AS (
    SELECT l.col, l.v AS category, count(*) AS cnt
    FROM _psi_all_long(cur_tbl) l JOIN cols k ON l.col = k.col
    WHERE k.kind = 'categorical'
    GROUP BY 1, 2
),
cat_merged AS (
    SELECT coalesce(r.col, u.col) AS col,
           coalesce(r.cnt, 0)::BIGINT AS ref_count,
           coalesce(u.cnt, 0)::BIGINT AS cur_count
    FROM cat_ref r FULL OUTER JOIN cat_cur u
      ON r.col = u.col AND r.category = u.category
),
cat_pcts AS (
    SELECT col, ref_count, cur_count,
           ref_count / nullif(sum(ref_count) OVER (PARTITION BY col), 0)::DOUBLE AS ref_pct,
           cur_count / nullif(sum(cur_count) OVER (PARTITION BY col), 0)::DOUBLE AS cur_pct
    FROM cat_merged
),
cat_summary AS (
    SELECT col,
           CASE WHEN sum(ref_count) = 0 OR sum(cur_count) = 0 THEN NULL
                ELSE sum(_psi_contrib(cur_pct, ref_pct, eps)) END AS psi,
           count(*)::INT AS groups,
           sum(ref_count)::BIGINT AS ref_rows,
           sum(cur_count)::BIGINT AS cur_rows
    FROM cat_pcts GROUP BY col
),
-- ---- continuous branch: psi_detail's math, partitioned by col ----
cont_ref_vals AS (
    SELECT col, vd FROM (
        SELECT l.col, _psi_to_double(l.v) AS vd
        FROM _psi_all_long(ref_tbl) l JOIN cols k ON l.col = k.col
        WHERE k.kind = 'continuous'
    ) WHERE vd IS NOT NULL
),
cont_cur_vals AS (
    SELECT col, vd FROM (
        SELECT l.col, _psi_to_double(l.v) AS vd
        FROM _psi_all_long(cur_tbl) l JOIN cols k ON l.col = k.col
        WHERE k.kind = 'continuous'
    ) WHERE vd IS NOT NULL
),
cont_cuts AS (
    SELECT col, list_sort(list_distinct(
             approx_quantile(vd, list_transform(generate_series(1, bins - 1),
                                                lambda i: (i / bins::DOUBLE)::FLOAT)))) AS cuts
    FROM cont_ref_vals GROUP BY col
),
-- The scaffold comes from the catalog (cols), not from observed data, so
-- every continuous column gets rows even when one side is empty; the
-- bins guard lives here so it fires whenever a continuous column exists.
cont_scaffold AS (
    SELECT k.col,
           unnest(generate_series(1, CASE WHEN bins < 1 THEN error('bins must be >= 1')
                                          ELSE coalesce(len(c.cuts), 0) + 1 END)) AS bin
    FROM cols k LEFT JOIN cont_cuts c ON k.col = c.col
    WHERE k.kind = 'continuous'
),
-- Half-open [lo, hi) binning: bin = 1 + count of cuts <= value, so a
-- value exactly on a cut lands in the upper bin. NaN compares greater
-- than every cut (DuckDB total order) -> top bin, matching psi_detail.
-- A column with no cuts row (empty ref side) gets NULL -> bin 1.
cont_ref_binned AS (
    SELECT v.col, 1 + coalesce(len(list_filter(c.cuts, lambda x: v.vd >= x)), 0) AS bin,
           count(*) AS cnt
    FROM cont_ref_vals v LEFT JOIN cont_cuts c ON v.col = c.col
    GROUP BY 1, 2
),
cont_cur_binned AS (
    SELECT v.col, 1 + coalesce(len(list_filter(c.cuts, lambda x: v.vd >= x)), 0) AS bin,
           count(*) AS cnt
    FROM cont_cur_vals v LEFT JOIN cont_cuts c ON v.col = c.col
    GROUP BY 1, 2
),
cont_merged AS (
    SELECT s.col, s.bin,
           coalesce(r.cnt, 0)::BIGINT AS ref_count,
           coalesce(u.cnt, 0)::BIGINT AS cur_count,
           sum(coalesce(r.cnt, 0)) OVER (PARTITION BY s.col) AS ref_total,
           sum(coalesce(u.cnt, 0)) OVER (PARTITION BY s.col) AS cur_total
    FROM cont_scaffold s
    LEFT JOIN cont_ref_binned r ON s.col = r.col AND s.bin = r.bin
    LEFT JOIN cont_cur_binned u ON s.col = u.col AND s.bin = u.bin
),
cont_summary AS (
    SELECT col,
           CASE WHEN max(ref_total) = 0 OR max(cur_total) = 0 THEN NULL
                ELSE sum(_psi_contrib(cur_count / nullif(cur_total, 0)::DOUBLE,
                                      ref_count / nullif(ref_total, 0)::DOUBLE, eps)) END AS psi,
           count(*)::INT AS groups,
           max(ref_total)::BIGINT AS ref_rows,
           max(cur_total)::BIGINT AS cur_rows
    FROM cont_merged GROUP BY col
),
summaries AS (
    SELECT * FROM cat_summary
    UNION ALL
    SELECT * FROM cont_summary
)
SELECT k.col AS "column",
       k.kind,
       k.status,
       s.psi,
       psi_interpret(s.psi) AS interpretation,
       -- one-sided columns are never scored, so a group count would be
       -- misleading (it reflects only the present side)
       CASE WHEN k.status IN ('ref only', 'cur only') THEN NULL ELSE s.groups END AS groups,
       coalesce(s.ref_rows, 0) AS ref_rows,
       coalesce(s.cur_rows, 0) AS cur_rows
FROM cols k LEFT JOIN summaries s ON k.col = s.col
ORDER BY s.psi DESC NULLS LAST, k.col;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `duckdb -c ".read test_psi.sql"`
Expected: `52 assertions, 0 failed`, exit code 0.

- [ ] **Step 5: Commit**

```bash
git add psi_macros.sql test_psi.sql
git commit -m "feat: add psi_all multi-column sweep macro"
```

---

### Task 3: Edge and status coverage

**Files:**
- Modify: `test_psi.sql` (insert fixtures + 12 assertions after Task 2's tests, above the report block)

**Interfaces:**
- Consumes: `psi_all` (Task 2 shape), fixtures `sweep_ref`/`sweep_cur` (Task 1), existing fixtures `cat_ref_nulls`, `cat_ref`, `cont_ref`, `cont_empty`, `cat_empty`.
- Produces: nothing new — this task is verification coverage for the spec's status/edge semantics.

- [ ] **Step 1: Write the tests** (they should pass immediately if Task 2 is correct — this task pins the spec's edge semantics against regressions)

In `test_psi.sql`, insert after Task 2's tests (above the report block):

```sql
------------------------------------------------------------------
-- Tests: psi_all (statuses, exclude, edges)
------------------------------------------------------------------
CREATE OR REPLACE TABLE nan_sweep_ref AS SELECT (range % 10) / 10.0 AS x FROM range(100);
CREATE OR REPLACE TABLE nan_sweep_cur AS
    SELECT (range % 10) / 10.0 AS x FROM range(100)
    UNION ALL SELECT 'nan'::DOUBLE;

INSERT INTO _results
SELECT 'all: identity sweep is all zero and ok',
       coalesce(count(*) = 9 AND bool_and(status = 'ok') AND bool_and(abs(psi) < 1e-12), false),
       'rows=' || count(*)::VARCHAR
FROM psi_all('sweep_ref', 'sweep_ref');

INSERT INTO _results
SELECT 'all: ref-only column flagged, not scored',
       coalesce(bool_and(status = 'ref only' AND psi IS NULL
                     AND interpretation = 'insufficient data'
                     AND groups IS NULL AND ref_rows = 200 AND cur_rows = 0), false),
       'only_ref checked'
FROM psi_all('sweep_ref', 'sweep_cur') WHERE "column" = 'only_ref';

INSERT INTO _results
SELECT 'all: cur-only column flagged, not scored',
       coalesce(bool_and(status = 'cur only' AND psi IS NULL
                     AND interpretation = 'insufficient data'
                     AND groups IS NULL AND ref_rows = 0 AND cur_rows = 180), false),
       'only_cur checked'
FROM psi_all('sweep_ref', 'sweep_cur') WHERE "column" = 'only_cur';

-- mix is DOUBLE in ref, VARCHAR in cur, with identical value distributions:
-- analyzed as categorical (5 distinct values), flagged, psi exactly 0.
INSERT INTO _results
SELECT 'all: type mismatch analyzed as categorical and flagged',
       coalesce(bool_and(kind = 'categorical' AND status = 'type mismatch'
                     AND abs(psi) < 1e-12 AND groups = 5), false),
       'mix checked'
FROM psi_all('sweep_ref', 'sweep_cur') WHERE "column" = 'mix';

INSERT INTO _results
SELECT 'all: exclude drops columns from the sweep',
       coalesce(count(*) = 8
            AND count(*) FILTER (WHERE "column" IN ('id', 'only_ref')) = 0, false),
       'rows=' || count(*)::VARCHAR
FROM psi_all('sweep_ref', 'sweep_cur', exclude := ['id', 'only_ref']);

INSERT INTO _results
SELECT 'all: NaN counted in top bin like psi()',
       coalesce(
           (SELECT cur_rows FROM psi_all('nan_sweep_ref', 'nan_sweep_cur')) = 101
       AND abs((SELECT psi FROM psi_all('nan_sweep_ref', 'nan_sweep_cur'))
             - (SELECT psi FROM psi('nan_sweep_ref', 'nan_sweep_cur', 'x'))) < 1e-9, false),
       'nan checked';

INSERT INTO _results
SELECT 'all: drifting null rate scored like psi_cat',
       coalesce(abs(
           (SELECT psi FROM psi_all('cat_ref_nulls', 'cat_ref'))
         - (SELECT psi FROM psi_cat('cat_ref_nulls', 'cat_ref', 'seg'))) < 1e-12
       AND (SELECT psi FROM psi_all('cat_ref_nulls', 'cat_ref')) > 0, false),
       'null drift checked';

INSERT INTO _results
SELECT 'all: empty side is insufficient data',
       coalesce(count(*) = 1
            AND bool_and(psi IS NULL AND interpretation = 'insufficient data'
                     AND status = 'ok'), false),
       'rows=' || count(*)::VARCHAR
FROM psi_all('cont_empty', 'cont_ref');

INSERT INTO _results
SELECT 'all: both empty is insufficient data',
       coalesce(count(*) = 1
            AND bool_and(psi IS NULL AND interpretation = 'insufficient data'
                     AND ref_rows = 0 AND cur_rows = 0), false),
       'rows=' || count(*)::VARCHAR
FROM psi_all('cat_empty', 'cat_empty');

INSERT INTO _results
SELECT 'all: bins=1 single-bin identity',
       coalesce(bool_and(abs(psi) < 1e-12 AND groups = 1), false),
       'bins=1 checked'
FROM psi_all('cont_ref', 'cont_ref', bins := 1);

-- cat_ref has only seg, cont_ref has only score: zero shared columns is
-- not an error -- you get one-sided status rows for everything.
INSERT INTO _results
SELECT 'all: no shared columns gives status rows only',
       coalesce(count(*) = 2
            AND bool_and(psi IS NULL AND groups IS NULL
                     AND status IN ('ref only', 'cur only')), false),
       'rows=' || count(*)::VARCHAR
FROM psi_all('cat_ref', 'cont_ref');

CREATE SCHEMA IF NOT EXISTS sweep_s1;
CREATE OR REPLACE TABLE sweep_s1.qual AS SELECT range::DOUBLE AS x FROM range(50);
INSERT INTO _results
SELECT 'all: schema-qualified table names work',
       coalesce(bool_and(abs(psi) < 1e-12 AND status = 'ok'), false),
       'qualified checked'
FROM psi_all('sweep_s1.qual', 'sweep_s1.qual');
```

- [ ] **Step 2: Run the suite**

Run: `duckdb -c ".read test_psi.sql"`
Expected: `64 assertions, 0 failed`, exit code 0. If any `all:` assertion fails, the bug is in Task 2's macro — fix `psi_all` (not the test) and re-run.

- [ ] **Step 3: Verify psi_all error paths manually**

```sh
duckdb -c ".read psi_macros.sql" \
       -c "CREATE TABLE r (x DOUBLE); CREATE TABLE c (x DOUBLE); INSERT INTO r VALUES (1); INSERT INTO c VALUES (2); SELECT * FROM psi_all('r', 'c', bins := -1);"
```
Expected: `Invalid Input Error: bins must be >= 1` (non-zero exit).

```sh
duckdb -c ".read psi_macros.sql" \
       -c "CREATE SCHEMA s1; CREATE TABLE dup (a INT); CREATE TABLE s1.dup (a INT); CREATE TABLE plain (a INT); INSERT INTO dup VALUES (1); INSERT INTO plain VALUES (1); SELECT * FROM psi_all('dup', 'plain');"
```
Expected: `Invalid Input Error: psi_all: table name 'dup' matches more than one table; qualify as schema.table` — this is the case where `query_table` alone would silently pick `main.dup`.

- [ ] **Step 4: Commit**

```bash
git add test_psi.sql
git commit -m "test: edge and status coverage for psi_all"
```

---

### Task 4: README

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the shipped behavior of `psi_all` (Tasks 1–3).
- Produces: user-facing documentation; nothing downstream.

- [ ] **Step 1: Update the README**

Apply these edits to `README.md`:

**(a)** Replace the intro paragraph line:

```markdown
PSI as four DuckDB table macros. No extensions, no UDFs — load one SQL file
and compare any two tables.
```

with:

```markdown
PSI as five DuckDB table macros. No extensions, no UDFs — load one SQL file
and compare any two tables, or sweep every column of both at once.
```

**(b)** In **Requirements**, after the sentence about `approx_quantile`/`histogram`, append:

```markdown
`psi_all` additionally uses `UNPIVOT` over `COLUMNS(*)` and the
`duckdb_columns()` catalog function.
```

**(c)** In **Usage**, after the categorical example block, insert:

```markdown
Whole tables — sweep every shared column in one call, biggest drift first:

```sql
SELECT * FROM psi_all('features_q1', 'features_q2');
SELECT * FROM psi_all('features_q1', 'features_q2', bins := 20, exclude := ['customer_id']);
-- ┌─────────┬─────────────┬────────┬────────┬────────────────┬────────┬──────────┬──────────┐
-- │ column  │    kind     │ status │  psi   │ interpretation │ groups │ ref_rows │ cur_rows │
-- one row per column; kind is 'continuous' or 'categorical'; status flags
-- schema drift ('ref only' / 'cur only' / 'type mismatch')
```

Columns are analyzed by their declared type: numeric and temporal types
(DATE/TIMESTAMP/TIMESTAMPTZ, compared on the epoch axis) get quantile-binned
continuous PSI; everything else is categorical. Drill into a drifting column
with `psi_detail` / `psi_cat_detail`.
```

**(d)** In **Parameters**, extend the table with:

```markdown
| `exclude` | `[]` | `psi_all` only: list of column names (exact, case-sensitive) to skip — IDs, keys, and other columns whose PSI is noise |
```

and directly below the table add this line:

```markdown
In `psi_all`, `bins` applies uniformly to every continuous column and `eps`
to every column.
```

**(e)** In **Semantics and edge cases**, append these bullets:

```markdown
- **Sweep dispatch** (`psi_all`): kind comes from the *declared* catalog
  type, per table side. Numeric and DATE/TIMESTAMP/TIMESTAMPTZ columns are
  continuous (temporal values compared as epoch seconds); everything else is
  categorical. A column that is continuous in one table but not the other is
  analyzed as categorical and flagged `status = 'type mismatch'`.
- **Sweep statuses**: columns present in only one table still get a row
  (`psi = NULL`, `status = 'ref only'` / `'cur only'`) so schema drift is
  visible; a missing column never aborts the sweep.
- **Sweep agreement**: `psi_all`'s categorical rows equal `psi_cat` exactly;
  continuous rows can differ from a per-column `psi()` call within
  approx-quantile sketch noise (cut points are already not bit-exact).
  For a single column, `psi()`/`psi_cat()` are also the faster path.
- **Sweep table names**: bare names and `'schema.table'` are matched
  case-insensitively in the catalog; a bare name matching tables in more
  than one schema raises an error instead of guessing.
```

- [ ] **Step 2: Run the full suite one final time**

Run: `duckdb -c ".read test_psi.sql"`
Expected: `64 assertions, 0 failed`, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README for psi_all multi-column sweep"
```
