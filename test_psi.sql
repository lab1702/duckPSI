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

CREATE OR REPLACE TABLE cat_mod_ref AS       -- moderate-shift pair
    SELECT 'A' AS seg FROM range(50)
    UNION ALL SELECT 'B' FROM range(50);

CREATE OR REPLACE TABLE cat_mod_cur AS
    SELECT 'A' AS seg FROM range(70)
    UNION ALL SELECT 'B' FROM range(30);

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
