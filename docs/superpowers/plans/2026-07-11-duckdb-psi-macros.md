# DuckDB PSI Macros Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship four pure-SQL DuckDB table macros (`psi`, `psi_detail`, `psi_cat`, `psi_cat_detail`) that compute the Population Stability Index between a reference and a current population, with a self-checking SQL test suite and a README.

**Architecture:** One macro file (`psi_macros.sql`) defines detail macros containing all the math, plus thin summary wrappers that aggregate them. Table/column names are passed as strings and resolved via `query_table()` + anchored `COLUMNS()` regex. Continuous binning uses `quantile_cont` cut points from the reference population; categorical uses a full outer join per distinct value. Tests are pure SQL emitting PASS/FAIL rows, ending with an `error()` call if anything failed (non-zero exit).

**Tech Stack:** DuckDB ≥ 1.3 (Python-style lambda syntax), developed against 1.5.4. No extensions, no UDFs, no client-side code.

## Global Constraints

- Pure SQL only: no extensions, no UDFs, nothing outside `psi_macros.sql`.
- All macros use `CREATE OR REPLACE MACRO` (idempotent re-load).
- Use Python-style lambda syntax `lambda x: ...` — the `->` arrow is deprecated in DuckDB 1.5 and must not appear.
- Column selection must use the anchored regex `COLUMNS('^' || col || '$')` — unanchored `COLUMNS(col)` matches substrings (verified: `'score'` also matches `'score2'`).
- Division guards: totals go through `nullif(total, 0)` — bare division by zero yields `inf`/`nan` in DuckDB, never rely on it.
- Epsilon floor: contribution term uses `greatest(pct, eps)`; the **reported** `ref_pct`/`cur_pct` columns stay unclamped. Defaults: `bins := 10`, `eps := 1e-4`.
- Interpretation thresholds: `psi < 0.10` → `'stable'`; `< 0.25` → `'moderate shift'`; else `'significant shift'`; empty ref or cur → `psi = NULL`, `'insufficient data'`.
- Every test assertion's pass expression is wrapped `coalesce(<cond>, false)` — a NULL comparison must count as FAIL, not vanish.
- Tests run from the repo root: `duckdb -c ".read test_psi.sql"` (fallback: `Get-Content test_psi.sql | duckdb` on PowerShell, `duckdb < test_psi.sql` on POSIX).
- Commit after each task with the trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

**Verified DuckDB facts this plan relies on (tested on 1.5.4):** table macros accept default named parameters; a table macro can call another table macro forwarding parameters (`bins := bins`); `quantile_cont(v, <computed list>)` works when the list folds to a constant at bind time; `generate_series(a, b)` in scalar context returns a `BIGINT[]` (empty when `a > b`); `quantile_cont` over zero rows returns NULL; a value equal to a cut point lands in the upper bin with `len(list_filter(cuts, lambda c: v >= c)) + 1`.

---

### Task 1: Test harness + `psi_cat_detail`

**Files:**
- Create: `psi_macros.sql`
- Create: `test_psi.sql`
- Create: `.gitignore`
- Modify: `docs/superpowers/specs/2026-07-11-duckdb-psi-macros-design.md:6` (version floor)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `psi_cat_detail(ref_tbl, cur_tbl, col, eps := 1e-4)` — table macro returning
  `category VARCHAR, ref_count BIGINT, cur_count BIGINT, ref_pct DOUBLE, cur_pct DOUBLE, psi_contrib DOUBLE`,
  one row per distinct category (union of both populations), ordered by category.
  Also produces the test-harness conventions every later task appends to:
  fixtures + `INSERT INTO _results` assertions + the final report/error block stays at the bottom of `test_psi.sql`.

- [ ] **Step 1: Fix the spec's version floor**

In `docs/superpowers/specs/2026-07-11-duckdb-psi-macros-design.md`, change the line
`**Target:** DuckDB ≥ 1.1 (developed and tested against 1.5.4)` to
`**Target:** DuckDB ≥ 1.3 (Python-style lambda syntax; developed and tested against 1.5.4)`.
(The macros use `lambda x:` syntax, which does not exist in 1.1.)

- [ ] **Step 2: Create `.gitignore`**

```gitignore
*.duckdb
*.duckdb.wal
```

- [ ] **Step 3: Write the failing tests**

Create `test_psi.sql` with exactly this content. The harness layout is: load macros → results table → fixtures → assertions → report block. Later tasks insert their fixtures/assertions above the report block.

```sql
-- test_psi.sql — self-checking test suite for psi_macros.sql
-- Run from the repo root:  duckdb -c ".read test_psi.sql"
-- Exits non-zero (via error()) if any assertion fails.

.read psi_macros.sql

CREATE OR REPLACE TABLE _results (name VARCHAR, pass BOOLEAN, detail VARCHAR);

------------------------------------------------------------------
-- Fixtures: categorical
------------------------------------------------------------------
CREATE OR REPLACE TABLE cat_ref AS
    SELECT 'A' AS seg FROM range(50)
    UNION ALL SELECT 'B' FROM range(30)
    UNION ALL SELECT 'C' FROM range(20);

CREATE OR REPLACE TABLE cat_cur AS
    SELECT 'A' AS seg FROM range(40)
    UNION ALL SELECT 'B' FROM range(40)
    UNION ALL SELECT 'C' FROM range(20);

CREATE OR REPLACE TABLE cat_ab_ref AS       -- for the missing-category path
    SELECT 'A' AS seg FROM range(90)
    UNION ALL SELECT 'B' FROM range(10);

CREATE OR REPLACE TABLE cat_a_cur AS
    SELECT 'A' AS seg FROM range(100);

CREATE OR REPLACE TABLE cat_ref_nulls AS
    SELECT seg FROM cat_ref
    UNION ALL SELECT NULL FROM range(10);

CREATE OR REPLACE TABLE cat_int_ref AS      -- non-VARCHAR categorical column
    SELECT range % 3 AS grp FROM range(90);

CREATE OR REPLACE TABLE cat_empty (seg VARCHAR);

------------------------------------------------------------------
-- Tests: psi_cat_detail
------------------------------------------------------------------
INSERT INTO _results
SELECT 'cat_detail: macro exists',
       coalesce(count(*) >= 1, false),
       'found ' || count(*)::VARCHAR
FROM duckdb_functions() WHERE function_name = 'psi_cat_detail';

INSERT INTO _results
SELECT 'cat_detail: identity has zero contribs',
       coalesce(bool_and(abs(psi_contrib) < 1e-12) AND count(*) = 3, false),
       'rows=' || count(*)::VARCHAR
FROM psi_cat_detail('cat_ref', 'cat_ref', 'seg');

-- Hand-computed: A: (0.4-0.5)*ln(0.4/0.5) = 0.022314355131420976
--                B: (0.4-0.3)*ln(0.4/0.3) = 0.028768207245178085
--                C: 0. Total = 0.051082562376599064
INSERT INTO _results
SELECT 'cat_detail: known total 0.0510825624',
       coalesce(abs(sum(psi_contrib) - 0.051082562376599064) < 1e-9, false),
       'psi=' || sum(psi_contrib)::VARCHAR
FROM psi_cat_detail('cat_ref', 'cat_cur', 'seg');

INSERT INTO _results
SELECT 'cat_detail: per-category contribs',
       coalesce(
           abs(max(CASE WHEN category = 'A' THEN psi_contrib END) - 0.022314355131420976) < 1e-9
       AND abs(max(CASE WHEN category = 'B' THEN psi_contrib END) - 0.028768207245178085) < 1e-9
       AND abs(max(CASE WHEN category = 'C' THEN psi_contrib END)) < 1e-12, false),
       string_agg(category || '=' || psi_contrib::VARCHAR, ', ' ORDER BY category)
FROM psi_cat_detail('cat_ref', 'cat_cur', 'seg');

-- Missing category: true cur_pct stays 0 (unclamped), contribution finite via eps
INSERT INTO _results
SELECT 'cat_detail: missing category eps floor',
       coalesce(
           max(CASE WHEN category = 'B' THEN cur_count END) = 0
       AND max(CASE WHEN category = 'B' THEN cur_pct END) = 0.0
       AND isfinite(max(CASE WHEN category = 'B' THEN psi_contrib END)), false),
       'B contrib=' || max(CASE WHEN category = 'B' THEN psi_contrib END)::VARCHAR
FROM psi_cat_detail('cat_ab_ref', 'cat_a_cur', 'seg');

INSERT INTO _results
SELECT 'cat_detail: NULL becomes (NULL) category',
       coalesce(max(CASE WHEN category = '(NULL)' THEN ref_count END) = 10, false),
       'rows=' || count(*)::VARCHAR
FROM psi_cat_detail('cat_ref_nulls', 'cat_ref_nulls', 'seg');

INSERT INTO _results
SELECT 'cat_detail: integer column works',
       coalesce(count(*) = 3 AND bool_and(abs(psi_contrib) < 1e-12), false),
       'rows=' || count(*)::VARCHAR
FROM psi_cat_detail('cat_int_ref', 'cat_int_ref', 'grp');

INSERT INTO _results
SELECT 'cat_detail: both empty gives zero rows',
       coalesce(count(*) = 0, true),
       'rows=' || count(*)::VARCHAR
FROM psi_cat_detail('cat_empty', 'cat_empty', 'seg');

------------------------------------------------------------------
-- Report (KEEP LAST — later tasks insert their tests above this)
------------------------------------------------------------------
SELECT name, CASE WHEN pass THEN 'PASS' ELSE 'FAIL' END AS status, detail
FROM _results ORDER BY name;

SELECT count(*)::VARCHAR || ' assertions, ' ||
       count(*) FILTER (WHERE NOT coalesce(pass, false))::VARCHAR || ' failed' AS summary
FROM _results;

SELECT error('TESTS FAILED: ' || string_agg(name, ', '))
FROM _results
WHERE NOT coalesce(pass, false)
HAVING count(*) > 0;
```

Note the one deliberate oddity: the `both empty gives zero rows` assertion uses `coalesce(count(*) = 0, true)` — `count(*)` never returns NULL so either coalesce default is fine; `true` is used to make it obvious this assertion cannot be NULL-poisoned.

Also create `psi_macros.sql` containing only a header comment for now (so `.read` succeeds and the failure is the *missing macro*, not a missing file):

```sql
-- psi_macros.sql — Population Stability Index (PSI) as pure DuckDB SQL table macros.
-- Requires DuckDB >= 1.3 (Python-style lambdas). Load with:  .read psi_macros.sql
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `duckdb -c ".read test_psi.sql"`
Expected: an error like `Table Function with name psi_cat_detail does not exist` (the first `FROM psi_cat_detail(...)` fails to bind — this is the red state). If `duckdb -c ".read ..."` itself does not process dot-commands, switch the runner to `Get-Content test_psi.sql | duckdb` and use that form everywhere from now on.

- [ ] **Step 5: Implement `psi_cat_detail`**

Append to `psi_macros.sql`:

```sql
-- ==================================================================
-- psi_cat_detail(ref_tbl, cur_tbl, col, eps := 1e-4)
-- Categorical PSI detail: one row per distinct value across BOTH
-- populations (full outer join). NULL is its own '(NULL)' category.
-- ref_pct / cur_pct are true proportions; only psi_contrib uses the
-- eps-floored values.
-- ==================================================================
CREATE OR REPLACE MACRO psi_cat_detail(ref_tbl, cur_tbl, col, eps := 1e-4) AS TABLE
WITH
ref_vals AS (
    SELECT coalesce(v::VARCHAR, '(NULL)') AS v
    FROM (SELECT COLUMNS('^' || col || '$') AS v FROM query_table(ref_tbl))
),
cur_vals AS (
    SELECT coalesce(v::VARCHAR, '(NULL)') AS v
    FROM (SELECT COLUMNS('^' || col || '$') AS v FROM query_table(cur_tbl))
),
ref_counts AS (SELECT v, count(*) AS cnt FROM ref_vals GROUP BY v),
cur_counts AS (SELECT v, count(*) AS cnt FROM cur_vals GROUP BY v),
totals AS (
    SELECT (SELECT count(*) FROM ref_vals) AS ref_total,
           (SELECT count(*) FROM cur_vals) AS cur_total
),
merged AS (
    SELECT coalesce(r.v, u.v) AS category,
           coalesce(r.cnt, 0)::BIGINT AS ref_count,
           coalesce(u.cnt, 0)::BIGINT AS cur_count
    FROM ref_counts r
    FULL OUTER JOIN cur_counts u ON r.v = u.v
),
pcts AS (
    SELECT m.category, m.ref_count, m.cur_count,
           m.ref_count / nullif(t.ref_total, 0)::DOUBLE AS ref_pct,
           m.cur_count / nullif(t.cur_total, 0)::DOUBLE AS cur_pct
    FROM merged m CROSS JOIN totals t
)
SELECT category, ref_count, cur_count, ref_pct, cur_pct,
       (greatest(cur_pct, eps) - greatest(ref_pct, eps))
         * ln(greatest(cur_pct, eps) / greatest(ref_pct, eps)) AS psi_contrib
FROM pcts
ORDER BY category;
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `duckdb -c ".read test_psi.sql"`
Expected: the results table shows all 8 `cat_detail:` rows with status PASS, summary says `8 assertions, 0 failed`, exit code 0.

- [ ] **Step 7: Verify the harness failure path actually fails loudly**

Temporarily append `INSERT INTO _results VALUES ('canary', false, 'x');` right before the report block, run the suite, confirm output contains `TESTS FAILED: canary` and the process exit code is non-zero (`$LASTEXITCODE -ne 0` in PowerShell). Then **remove the canary line** and re-run to confirm green. This proves the `error()`/`HAVING` report block works — every later task depends on it.

- [ ] **Step 8: Commit**

```bash
git add psi_macros.sql test_psi.sql .gitignore docs/
git commit -m "feat: add psi_cat_detail macro and self-checking test harness"
```

---

### Task 2: `psi_cat` summary macro

**Files:**
- Modify: `psi_macros.sql` (append)
- Modify: `test_psi.sql` (fixtures + assertions above the report block)

**Interfaces:**
- Consumes: `psi_cat_detail(ref_tbl, cur_tbl, col, eps := eps)` from Task 1 — columns
  `category, ref_count, cur_count, ref_pct, cur_pct, psi_contrib`.
- Produces: `psi_cat(ref_tbl, cur_tbl, col, eps := 1e-4)` — table macro returning exactly one row:
  `psi DOUBLE, interpretation VARCHAR, categories INT, ref_rows BIGINT, cur_rows BIGINT`.
  Also produces `psi_interpret(p)` — a scalar macro mapping a total PSI value to its label
  (`NULL → 'insufficient data'`, `< 0.10 → 'stable'`, `< 0.25 → 'moderate shift'`,
  else `'significant shift'`). The thresholds live ONLY here; Task 4 reuses this macro.

- [ ] **Step 1: Write the failing tests**

Add these fixtures to the categorical fixtures section of `test_psi.sql`:

```sql
CREATE OR REPLACE TABLE cat_mod_ref AS       -- moderate-shift pair
    SELECT 'A' AS seg FROM range(50)
    UNION ALL SELECT 'B' FROM range(50);

CREATE OR REPLACE TABLE cat_mod_cur AS
    SELECT 'A' AS seg FROM range(70)
    UNION ALL SELECT 'B' FROM range(30);
```

Add these assertions above the report block:

```sql
------------------------------------------------------------------
-- Tests: psi_cat
------------------------------------------------------------------
INSERT INTO _results
SELECT 'cat: identity is stable zero',
       coalesce(abs(psi) < 1e-12 AND interpretation = 'stable'
                AND categories = 3 AND ref_rows = 100 AND cur_rows = 100, false),
       'psi=' || psi::VARCHAR || ' label=' || interpretation
FROM psi_cat('cat_ref', 'cat_ref', 'seg');

INSERT INTO _results
SELECT 'cat: known value 0.0510825624 stable',
       coalesce(abs(psi - 0.051082562376599064) < 1e-9 AND interpretation = 'stable', false),
       'psi=' || psi::VARCHAR
FROM psi_cat('cat_ref', 'cat_cur', 'seg');

-- (0.7-0.5)*ln(1.4) + (0.3-0.5)*ln(0.6) = 0.169459572077441
INSERT INTO _results
SELECT 'cat: moderate shift label',
       coalesce(abs(psi - 0.169459572077441) < 1e-9 AND interpretation = 'moderate shift', false),
       'psi=' || psi::VARCHAR || ' label=' || interpretation
FROM psi_cat('cat_mod_ref', 'cat_mod_cur', 'seg');

-- A: 0.1*ln(1/0.9) ; B: (1e-4 - 0.1)*ln(1e-4/0.1). Total = 0.700620803936098
INSERT INTO _results
SELECT 'cat: eps default gives 0.7006208039 significant',
       coalesce(abs(psi - 0.700620803936098) < 1e-9 AND interpretation = 'significant shift', false),
       'psi=' || psi::VARCHAR
FROM psi_cat('cat_ab_ref', 'cat_a_cur', 'seg');

-- Same pair, eps := 0.01: B: (0.01-0.1)*ln(0.1) → total 0.217768709935247
INSERT INTO _results
SELECT 'cat: custom eps changes result',
       coalesce(abs(psi - 0.217768709935247) < 1e-9 AND interpretation = 'moderate shift', false),
       'psi=' || psi::VARCHAR
FROM psi_cat('cat_ab_ref', 'cat_a_cur', 'seg', eps := 0.01);

INSERT INTO _results
SELECT 'cat: empty cur is insufficient data',
       coalesce(psi IS NULL AND interpretation = 'insufficient data', false),
       'label=' || interpretation
FROM psi_cat('cat_ref', 'cat_empty', 'seg');

INSERT INTO _results
SELECT 'cat: empty ref is insufficient data',
       coalesce(psi IS NULL AND interpretation = 'insufficient data', false),
       'label=' || interpretation
FROM psi_cat('cat_empty', 'cat_ref', 'seg');

INSERT INTO _results
SELECT 'cat: both empty is insufficient data',
       coalesce(psi IS NULL AND interpretation = 'insufficient data' AND categories = 0, false),
       'label=' || interpretation
FROM psi_cat('cat_empty', 'cat_empty', 'seg');
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `duckdb -c ".read test_psi.sql"`
Expected: error `Table Function with name psi_cat does not exist` (red state).

- [ ] **Step 3: Implement `psi_cat`**

Append to `psi_macros.sql`:

```sql
-- ==================================================================
-- psi_interpret(p)
-- Shared interpretation label for a total PSI value. The thresholds
-- exist only here; psi() and psi_cat() both call this.
-- ==================================================================
CREATE OR REPLACE MACRO psi_interpret(p) AS
    CASE WHEN p IS NULL THEN 'insufficient data'
         WHEN p < 0.10  THEN 'stable'
         WHEN p < 0.25  THEN 'moderate shift'
         ELSE 'significant shift' END;

-- ==================================================================
-- psi_cat(ref_tbl, cur_tbl, col, eps := 1e-4)
-- Categorical PSI summary: single row aggregating psi_cat_detail.
-- ==================================================================
CREATE OR REPLACE MACRO psi_cat(ref_tbl, cur_tbl, col, eps := 1e-4) AS TABLE
SELECT
    CASE WHEN coalesce(sum(ref_count), 0) = 0 OR coalesce(sum(cur_count), 0) = 0
         THEN NULL
         ELSE sum(psi_contrib) END AS psi,
    psi_interpret(psi) AS interpretation,
    count(*)::INT AS categories,
    coalesce(sum(ref_count), 0)::BIGINT AS ref_rows,
    coalesce(sum(cur_count), 0)::BIGINT AS cur_rows
FROM psi_cat_detail(ref_tbl, cur_tbl, col, eps := eps);
```

(`psi_interpret(psi)` references the `psi` alias defined in the same SELECT — DuckDB
supports lateral column-alias reuse; verified on 1.5.4. `sum(psi_contrib)` cannot be
NULL when both totals are positive, so the NULL branch fires exactly for the
insufficient-data case.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `duckdb -c ".read test_psi.sql"`
Expected: 16 assertions, 0 failed, exit code 0.

- [ ] **Step 5: Commit**

```bash
git add psi_macros.sql test_psi.sql
git commit -m "feat: add psi_cat summary macro"
```

---

### Task 3: `psi_detail` continuous macro

**Files:**
- Modify: `psi_macros.sql` (append)
- Modify: `test_psi.sql` (fixtures + assertions above the report block)

**Interfaces:**
- Consumes: nothing from prior tasks (independent math; same file conventions).
- Produces: `psi_detail(ref_tbl, cur_tbl, col, bins := 10, eps := 1e-4)` — table macro returning one
  row per bin: `bin INT, bin_range VARCHAR, lo DOUBLE, hi DOUBLE, ref_count BIGINT, cur_count BIGINT,
  ref_pct DOUBLE, cur_pct DOUBLE, psi_contrib DOUBLE`, ordered by bin. `lo` is NULL for bin 1,
  `hi` is NULL for the last bin. Bins are half-open `[lo, hi)`; a value equal to a cut point goes to
  the upper bin. Cut points are `quantile_cont` of the reference at `i/bins`, deduplicated — so the
  row count (`bins_used`) can be lower than `bins`. NULLs excluded from both populations.

- [ ] **Step 1: Write the failing tests**

Add a continuous fixtures section to `test_psi.sql` (below the categorical fixtures):

```sql
------------------------------------------------------------------
-- Fixtures: continuous
------------------------------------------------------------------
CREATE OR REPLACE TABLE cont_ref  AS SELECT range::DOUBLE AS score FROM range(100);        -- 0..99
CREATE OR REPLACE TABLE cont_cur  AS SELECT range::DOUBLE + 10 AS score FROM range(100);   -- 10..109
CREATE OR REPLACE TABLE cont_cur20 AS SELECT range::DOUBLE + 20 AS score FROM range(100);  -- 20..119

CREATE OR REPLACE TABLE cont_edge AS SELECT 49.5::DOUBLE AS score;   -- exactly on a bins=4 cut

CREATE OR REPLACE TABLE cont_tied AS                                 -- 95% ties collapse cuts
    SELECT 1.0::DOUBLE AS score FROM range(95)
    UNION ALL SELECT unnest([2.0, 3.0, 4.0, 5.0, 6.0]);

CREATE OR REPLACE TABLE cont_ref_nulls AS
    SELECT score FROM cont_ref
    UNION ALL SELECT NULL::DOUBLE FROM range(10);

CREATE OR REPLACE TABLE cont_empty (score DOUBLE);
```

With `bins := 4` on `cont_ref` (0..99), `quantile_cont` gives cuts exactly `[24.75, 49.5, 74.25]`
(`q*(n-1)` interpolation — all exactly representable doubles), so ref counts are 25/25/25/25 and
`cont_cur` (10..109) counts are 15/25/25/35. Hand-computed total PSI:
`(0.15-0.25)*ln(0.15/0.25) + (0.35-0.25)*ln(0.35/0.25) = 0.08472978603872036`.

Add these assertions above the report block:

```sql
------------------------------------------------------------------
-- Tests: psi_detail
------------------------------------------------------------------
INSERT INTO _results
SELECT 'detail: identity zero contribs, 10 bins',
       coalesce(bool_and(abs(psi_contrib) < 1e-12) AND count(*) = 10, false),
       'rows=' || count(*)::VARCHAR
FROM psi_detail('cont_ref', 'cont_ref', 'score');

INSERT INTO _results
SELECT 'detail: bins=4 exact cut points',
       coalesce(count(*) = 4
       AND max(CASE WHEN bin = 1 THEN hi END) = 24.75
       AND max(CASE WHEN bin = 2 THEN hi END) = 49.5
       AND max(CASE WHEN bin = 3 THEN hi END) = 74.25
       AND max(CASE WHEN bin = 1 THEN lo END) IS NULL
       AND max(CASE WHEN bin = 4 THEN hi END) IS NULL
       AND max(CASE WHEN bin = 4 THEN lo END) = 74.25, false),
       string_agg(bin_range, ' | ' ORDER BY bin)
FROM psi_detail('cont_ref', 'cont_cur', 'score', bins := 4);

INSERT INTO _results
SELECT 'detail: bins=4 counts 25s vs 15/25/25/35',
       coalesce(bool_and(ref_count = 25)
       AND list(cur_count ORDER BY bin) = [15, 25, 25, 35], false),
       'cur=' || list(cur_count ORDER BY bin)::VARCHAR
FROM psi_detail('cont_ref', 'cont_cur', 'score', bins := 4);

INSERT INTO _results
SELECT 'detail: known total 0.0847297860',
       coalesce(abs(sum(psi_contrib) - 0.08472978603872036) < 1e-9, false),
       'psi=' || sum(psi_contrib)::VARCHAR
FROM psi_detail('cont_ref', 'cont_cur', 'score', bins := 4);

INSERT INTO _results
SELECT 'detail: bin_range text format',
       coalesce(max(CASE WHEN bin = 1 THEN bin_range END) = '< 24.75'
       AND max(CASE WHEN bin = 2 THEN bin_range END) = '[24.75, 49.5)'
       AND max(CASE WHEN bin = 4 THEN bin_range END) = '>= 74.25', false),
       string_agg(bin_range, ' | ' ORDER BY bin)
FROM psi_detail('cont_ref', 'cont_cur', 'score', bins := 4);

-- 49.5 sits exactly on cut 2 → belongs to bin 3 ([49.5, 74.25)), not bin 2.
-- Bins 1, 2, 4 have cur_count = 0 while cur is non-empty: every contribution
-- must still be finite (eps floor), per spec test item 4.
INSERT INTO _results
SELECT 'detail: value equal to cut goes to upper bin',
       coalesce(max(CASE WHEN bin = 3 THEN cur_count END) = 1
       AND max(CASE WHEN bin = 2 THEN cur_count END) = 0
       AND bool_and(isfinite(psi_contrib)), false),
       'cur=' || list(cur_count ORDER BY bin)::VARCHAR
FROM psi_detail('cont_ref', 'cont_edge', 'score', bins := 4);

-- 95 ties at 1.0 → every decile cut is 1.0 → dedup → 1 cut → 2 bins
INSERT INTO _results
SELECT 'detail: tied values collapse to 2 bins',
       coalesce(count(*) = 2 AND bool_and(abs(psi_contrib) < 1e-12), false),
       'rows=' || count(*)::VARCHAR
FROM psi_detail('cont_tied', 'cont_tied', 'score');

INSERT INTO _results
SELECT 'detail: NULLs excluded from reference',
       coalesce(abs(
           (SELECT sum(psi_contrib) FROM psi_detail('cont_ref_nulls', 'cont_cur', 'score', bins := 4))
         - (SELECT sum(psi_contrib) FROM psi_detail('cont_ref',       'cont_cur', 'score', bins := 4))
       ) < 1e-12, false),
       'diff computed';

INSERT INTO _results
SELECT 'detail: empty cur keeps scaffold, NULL cur_pct',
       coalesce(count(*) = 4 AND sum(cur_count) = 0 AND bool_and(cur_pct IS NULL)
       AND sum(ref_count) = 100, false),
       'rows=' || count(*)::VARCHAR
FROM psi_detail('cont_ref', 'cont_empty', 'score', bins := 4);

INSERT INTO _results
SELECT 'detail: empty ref gives single open bin',
       coalesce(count(*) = 1 AND max(bin_range) = '(-inf, inf)'
       AND max(lo) IS NULL AND max(hi) IS NULL, false),
       'rows=' || count(*)::VARCHAR
FROM psi_detail('cont_empty', 'cont_cur', 'score', bins := 4);
```

Note the `NULLs excluded` assertion selects from subqueries, not a bare `FROM` — it compares two macro invocations. It still emits exactly one `_results` row.

- [ ] **Step 2: Run tests to verify they fail**

Run: `duckdb -c ".read test_psi.sql"`
Expected: error `Table Function with name psi_detail does not exist` (red state).

- [ ] **Step 3: Implement `psi_detail`**

Append to `psi_macros.sql`:

```sql
-- ==================================================================
-- psi_detail(ref_tbl, cur_tbl, col, bins := 10, eps := 1e-4)
-- Continuous PSI detail. Cut points are quantile_cont of the
-- REFERENCE population at i/bins (i = 1 .. bins-1), deduplicated —
-- heavily tied data can therefore yield fewer bins than requested.
-- Bins are half-open [lo, hi); bin 1 is (-inf, cut1) and the last
-- bin is [cut_last, +inf), so out-of-range current values land in
-- the edge bins. NULLs are excluded from both populations.
-- ==================================================================
CREATE OR REPLACE MACRO psi_detail(ref_tbl, cur_tbl, col, bins := 10, eps := 1e-4) AS TABLE
WITH
ref_vals AS (
    SELECT v::DOUBLE AS v
    FROM (SELECT COLUMNS('^' || col || '$') AS v FROM query_table(ref_tbl))
    WHERE v IS NOT NULL
),
cur_vals AS (
    SELECT v::DOUBLE AS v
    FROM (SELECT COLUMNS('^' || col || '$') AS v FROM query_table(cur_tbl))
    WHERE v IS NOT NULL
),
cut_points AS (
    SELECT coalesce(
               list_sort(list_distinct(
                   quantile_cont(v, list_transform(generate_series(1, bins - 1),
                                                   lambda i: i / bins::DOUBLE))
               )),
               []) AS cuts
    FROM ref_vals
),
totals AS (
    SELECT (SELECT count(*) FROM ref_vals) AS ref_total,
           (SELECT count(*) FROM cur_vals) AS cur_total
),
bin_scaffold AS (
    SELECT unnest(generate_series(1, len(cuts) + 1)) AS bin FROM cut_points
),
ref_counts AS (
    SELECT len(list_filter(c.cuts, lambda x: r.v >= x)) + 1 AS bin, count(*) AS cnt
    FROM ref_vals r CROSS JOIN cut_points c
    GROUP BY 1
),
cur_counts AS (
    SELECT len(list_filter(c.cuts, lambda x: u.v >= x)) + 1 AS bin, count(*) AS cnt
    FROM cur_vals u CROSS JOIN cut_points c
    GROUP BY 1
),
merged AS (
    SELECT b.bin,
           coalesce(r.cnt, 0)::BIGINT AS ref_count,
           coalesce(u.cnt, 0)::BIGINT AS cur_count,
           c.cuts,
           t.ref_total,
           t.cur_total
    FROM bin_scaffold b
    CROSS JOIN cut_points c
    CROSS JOIN totals t
    LEFT JOIN ref_counts r USING (bin)
    LEFT JOIN cur_counts u USING (bin)
),
pcts AS (
    SELECT bin, cuts, ref_count, cur_count,
           ref_count / nullif(ref_total, 0)::DOUBLE AS ref_pct,
           cur_count / nullif(cur_total, 0)::DOUBLE AS cur_pct
    FROM merged
)
SELECT
    bin::INT AS bin,
    CASE WHEN len(cuts) = 0       THEN '(-inf, inf)'
         WHEN bin = 1             THEN '< ' || cuts[1]::VARCHAR
         WHEN bin = len(cuts) + 1 THEN '>= ' || cuts[len(cuts)]::VARCHAR
         ELSE '[' || cuts[bin - 1]::VARCHAR || ', ' || cuts[bin]::VARCHAR || ')'
    END AS bin_range,
    CASE WHEN bin = 1 THEN NULL ELSE cuts[bin - 1] END AS lo,
    CASE WHEN bin = len(cuts) + 1 THEN NULL ELSE cuts[bin] END AS hi,
    ref_count,
    cur_count,
    ref_pct,
    cur_pct,
    (greatest(cur_pct, eps) - greatest(ref_pct, eps))
      * ln(greatest(cur_pct, eps) / greatest(ref_pct, eps)) AS psi_contrib
FROM pcts
ORDER BY bin;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `duckdb -c ".read test_psi.sql"`
Expected: 26 assertions, 0 failed, exit code 0. If the `empty cur` assertion fails on `cur_pct IS NULL` because `greatest(NULL, eps)` semantics differ, that assertion is about the *reported* column — check that `cur_pct` (unclamped, `cur_count / nullif(0,0)`) is NULL; `psi_contrib` may be NULL or a value, the assertion deliberately doesn't test it (the summary macro guards degenerate inputs by row counts, not by NULL propagation).

- [ ] **Step 5: Commit**

```bash
git add psi_macros.sql test_psi.sql
git commit -m "feat: add psi_detail continuous macro"
```

---

### Task 4: `psi` summary macro

**Files:**
- Modify: `psi_macros.sql` (append)
- Modify: `test_psi.sql` (assertions above the report block; no new fixtures)

**Interfaces:**
- Consumes: `psi_detail(ref_tbl, cur_tbl, col, bins := bins, eps := eps)` from Task 3, and the
  scalar macro `psi_interpret(p)` from Task 2 (maps a PSI value to its label; NULL → 'insufficient data').
- Produces: `psi(ref_tbl, cur_tbl, col, bins := 10, eps := 1e-4)` — table macro returning exactly one row:
  `psi DOUBLE, interpretation VARCHAR, bins_requested INT, bins_used INT, ref_rows BIGINT, cur_rows BIGINT`.

- [ ] **Step 1: Write the failing tests**

Add above the report block:

```sql
------------------------------------------------------------------
-- Tests: psi (continuous summary)
------------------------------------------------------------------
INSERT INTO _results
SELECT 'psi: identity is stable zero',
       coalesce(abs(psi) < 1e-12 AND interpretation = 'stable'
                AND bins_requested = 10 AND bins_used = 10
                AND ref_rows = 100 AND cur_rows = 100, false),
       'psi=' || psi::VARCHAR || ' label=' || interpretation
FROM psi('cont_ref', 'cont_ref', 'score');

INSERT INTO _results
SELECT 'psi: known value 0.0847297860 stable',
       coalesce(abs(psi - 0.08472978603872036) < 1e-9 AND interpretation = 'stable'
                AND bins_requested = 4 AND bins_used = 4, false),
       'psi=' || psi::VARCHAR
FROM psi('cont_ref', 'cont_cur', 'score', bins := 4);

INSERT INTO _results
SELECT 'psi: bigger shift bigger psi',
       coalesce(
           (SELECT psi FROM psi('cont_ref', 'cont_cur20', 'score', bins := 4))
         > (SELECT psi FROM psi('cont_ref', 'cont_cur',   'score', bins := 4)), false),
       'monotonicity';

-- eps := 0.2 clamps cur bin1 0.15→0.2: (-0.05)*ln(0.8) + 0.1*ln(1.4) = 0.044804401227831775
INSERT INTO _results
SELECT 'psi: eps forwarded to detail',
       coalesce(abs(psi - 0.044804401227831775) < 1e-9, false),
       'psi=' || psi::VARCHAR
FROM psi('cont_ref', 'cont_cur', 'score', bins := 4, eps := 0.2);

INSERT INTO _results
SELECT 'psi: tied values report bins_used',
       coalesce(abs(psi) < 1e-12 AND bins_requested = 10 AND bins_used = 2, false),
       'bins_used=' || bins_used::VARCHAR
FROM psi('cont_tied', 'cont_tied', 'score');

INSERT INTO _results
SELECT 'psi: NULLs excluded from ref_rows',
       coalesce(ref_rows = 100 AND cur_rows = 100, false),
       'ref_rows=' || ref_rows::VARCHAR
FROM psi('cont_ref_nulls', 'cont_cur', 'score', bins := 4);

INSERT INTO _results
SELECT 'psi: empty cur is insufficient data',
       coalesce(psi IS NULL AND interpretation = 'insufficient data', false),
       'label=' || interpretation
FROM psi('cont_ref', 'cont_empty', 'score');

INSERT INTO _results
SELECT 'psi: empty ref is insufficient data',
       coalesce(psi IS NULL AND interpretation = 'insufficient data', false),
       'label=' || interpretation
FROM psi('cont_empty', 'cont_cur', 'score');
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `duckdb -c ".read test_psi.sql"`
Expected: error `Table Function with name psi does not exist` (red state).

- [ ] **Step 3: Implement `psi`**

Append to `psi_macros.sql`:

```sql
-- ==================================================================
-- psi(ref_tbl, cur_tbl, col, bins := 10, eps := 1e-4)
-- Continuous PSI summary: single row aggregating psi_detail.
-- bins_used < bins_requested when tied data collapses cut points.
-- ==================================================================
CREATE OR REPLACE MACRO psi(ref_tbl, cur_tbl, col, bins := 10, eps := 1e-4) AS TABLE
SELECT
    CASE WHEN coalesce(sum(ref_count), 0) = 0 OR coalesce(sum(cur_count), 0) = 0
         THEN NULL
         ELSE sum(psi_contrib) END AS psi,
    psi_interpret(psi) AS interpretation,
    bins::INT AS bins_requested,
    count(*)::INT AS bins_used,
    coalesce(sum(ref_count), 0)::BIGINT AS ref_rows,
    coalesce(sum(cur_count), 0)::BIGINT AS cur_rows
FROM psi_detail(ref_tbl, cur_tbl, col, bins := bins, eps := eps);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `duckdb -c ".read test_psi.sql"`
Expected: 34 assertions, 0 failed, exit code 0.

- [ ] **Step 5: Commit**

```bash
git add psi_macros.sql test_psi.sql
git commit -m "feat: add psi continuous summary macro"
```

---

### Task 5: README + independent cross-check

**Files:**
- Create: `README.md`
- Test: independent cross-check script (scratchpad only, NOT committed — spec says it is a
  dev-time verification, not part of the shipped suite)

**Interfaces:**
- Consumes: all four macros exactly as produced by Tasks 1–4.
- Produces: user-facing documentation; verified agreement with an independent implementation.

- [ ] **Step 1: Cross-check against an independent implementation**

Check whether Python + numpy is available: `python -c "import numpy; print(numpy.__version__)"`.

If available, write this to the scratchpad directory as `psi_crosscheck.py` and run it:

```python
import numpy as np, math, subprocess, json

ref = np.arange(100, dtype=float)          # 0..99
cur = np.arange(100, dtype=float) + 10     # 10..109
bins = 4
cuts = np.quantile(ref, [i / bins for i in range(1, bins)], method="linear")
cuts = np.unique(cuts)
edges = np.concatenate(([-np.inf], cuts, [np.inf]))
# right-open bins, value == cut goes to the upper bin  ->  side='right' on searchsorted
ref_cnt = np.histogram(ref, edges)[0]
cur_cnt = np.histogram(cur, edges)[0]
eps = 1e-4
rp = np.maximum(ref_cnt / ref_cnt.sum(), eps)
cp = np.maximum(cur_cnt / cur_cnt.sum(), eps)
psi_py = float(((cp - rp) * np.log(cp / rp)).sum())

out = subprocess.run(
    ["duckdb", "-json", "-c",
     '.read psi_macros.sql\n'
     "CREATE TABLE cont_ref AS SELECT range::DOUBLE AS score FROM range(100);"
     "CREATE TABLE cont_cur AS SELECT range::DOUBLE + 10 AS score FROM range(100);"
     "SELECT psi FROM psi('cont_ref','cont_cur','score', bins := 4);"],
    capture_output=True, text=True, cwd=".")
psi_db = json.loads(out.stdout)[0]["psi"]
print("python:", psi_py, "duckdb:", psi_db, "diff:", abs(psi_py - psi_db))
assert abs(psi_py - psi_db) < 1e-9, "MISMATCH"
print("CROSS-CHECK PASS")
```

Caveat: `np.histogram` treats interior bins as right-open `[a, b)` already, matching the macro; if
the assert fails, first check the histogram edge convention before suspecting the SQL.

Run it from the repo root. Expected output ends with `CROSS-CHECK PASS`.
If Python or numpy is unavailable, skip and record "cross-check skipped: no numpy" in the task notes.

- [ ] **Step 2: Write `README.md`**

````markdown
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
| `bins` | `10` | Number of quantile bins (continuous macros only) |
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

## Tests

```sh
duckdb -c ".read test_psi.sql"
```

Prints one PASS/FAIL row per assertion and exits non-zero on any failure.
````

(If Step 1's cross-check was skipped, drop no content — the README does not reference it.)

- [ ] **Step 3: Run the full suite one final time**

Run: `duckdb -c ".read test_psi.sql"`
Expected: 34 assertions, 0 failed.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: add README with usage and semantics"
```
