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
       coalesce(bool_and(coalesce(abs(psi_contrib) < 1e-12, false)) AND count(*) = 3, false),
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
       coalesce(count(*) = 3 AND bool_and(coalesce(abs(psi_contrib) < 1e-12, false)), false),
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
-- Tests: psi_detail
------------------------------------------------------------------
INSERT INTO _results
SELECT 'detail: identity zero contribs, 10 bins',
       coalesce(bool_and(coalesce(abs(psi_contrib) < 1e-12, false)) AND count(*) = 10, false),
       'rows=' || count(*)::VARCHAR
FROM psi_detail('cont_ref', 'cont_ref', 'score');

-- Cut points are approximate (T-Digest) quantiles: assert they land near the
-- true quartiles (24.75 / 49.5 / 74.25) within tolerance, and that the edge
-- bins stay open and lo/hi are the shared cut. Exact-equality is not asserted
-- because approx_quantile is intentionally not bit-reproducible.
INSERT INTO _results
SELECT 'detail: bins=4 approx cut points near quartiles',
       coalesce(count(*) = 4
       AND abs(max(CASE WHEN bin = 1 THEN hi END) - 24.75) < 1.0
       AND abs(max(CASE WHEN bin = 2 THEN hi END) - 49.5)  < 1.0
       AND abs(max(CASE WHEN bin = 3 THEN hi END) - 74.25) < 1.0
       AND max(CASE WHEN bin = 1 THEN lo END) IS NULL
       AND max(CASE WHEN bin = 4 THEN hi END) IS NULL
       AND max(CASE WHEN bin = 4 THEN lo END) = max(CASE WHEN bin = 3 THEN hi END), false),
       string_agg(bin_range, ' | ' ORDER BY bin)
FROM psi_detail('cont_ref', 'cont_cur', 'score', bins := 4);

INSERT INTO _results
SELECT 'detail: bins=4 counts 25s vs 15/25/25/35',
       coalesce(bool_and(coalesce(ref_count = 25, false))
       AND list(cur_count ORDER BY bin) = [15, 25, 25, 35], false),
       'cur=' || list(cur_count ORDER BY bin)::VARCHAR
FROM psi_detail('cont_ref', 'cont_cur', 'score', bins := 4);

INSERT INTO _results
SELECT 'detail: known total 0.0847297860',
       coalesce(abs(sum(psi_contrib) - 0.08472978603872036) < 1e-9, false),
       'psi=' || sum(psi_contrib)::VARCHAR
FROM psi_detail('cont_ref', 'cont_cur', 'score', bins := 4);

-- Format is asserted structurally (approx cut values are not bit-reproducible).
INSERT INTO _results
SELECT 'detail: bin_range text format',
       coalesce(max(CASE WHEN bin = 1 THEN bin_range END) LIKE '< %'
       AND max(CASE WHEN bin = 2 THEN bin_range END) LIKE '[%, %)'
       AND max(CASE WHEN bin = 4 THEN bin_range END) LIKE '>= %', false),
       string_agg(bin_range, ' | ' ORDER BY bin)
FROM psi_detail('cont_ref', 'cont_cur', 'score', bins := 4);

-- 49.5 sits exactly on cut 2 → belongs to bin 3 ([49.5, 74.25)), not bin 2.
-- Bins 1, 2, 4 have cur_count = 0 while cur is non-empty: every contribution
-- must still be finite (eps floor), per spec test item 4.
INSERT INTO _results
SELECT 'detail: value equal to cut goes to upper bin',
       coalesce(max(CASE WHEN bin = 3 THEN cur_count END) = 1
       AND max(CASE WHEN bin = 2 THEN cur_count END) = 0
       AND bool_and(coalesce(isfinite(psi_contrib), false)), false),
       'cur=' || list(cur_count ORDER BY bin)::VARCHAR
FROM psi_detail('cont_ref', 'cont_edge', 'score', bins := 4);

-- 95 ties at 1.0 → every decile cut is 1.0 → dedup → 1 cut → 2 bins
INSERT INTO _results
SELECT 'detail: tied values collapse to 2 bins',
       coalesce(count(*) = 2 AND bool_and(coalesce(abs(psi_contrib) < 1e-12, false)), false),
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
       coalesce(count(*) = 4 AND sum(cur_count) = 0 AND bool_and(coalesce(cur_pct IS NULL, false))
       AND sum(ref_count) = 100, false),
       'rows=' || count(*)::VARCHAR
FROM psi_detail('cont_ref', 'cont_empty', 'score', bins := 4);

INSERT INTO _results
SELECT 'detail: empty ref gives single open bin',
       coalesce(count(*) = 1 AND max(bin_range) = '(-inf, inf)'
       AND max(lo) IS NULL AND max(hi) IS NULL, false),
       'rows=' || count(*)::VARCHAR
FROM psi_detail('cont_empty', 'cont_cur', 'score', bins := 4);

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

-- bins := 1 collapses to zero cut points (len(cuts) = 0), i.e. one open bin
-- covering the whole range — exercises that branch with a NON-empty reference.
-- Identical ref/cur means the single bin holds 100% of both, so psi = 0.
INSERT INTO _results
SELECT 'psi: bins=1 single bin identity',
       coalesce(abs(psi) < 1e-12 AND bins_used = 1 AND bins_requested = 1, false),
       'psi=' || psi::VARCHAR
FROM psi('cont_ref', 'cont_ref', 'score', bins := 1);

-- Documents the designed empty-side detail semantics: with cur totally empty,
-- psi_cat_detail still returns one row per reference category (not zero rows).
-- cur_pct is NULL (true proportion undefined, not clamped) while cur_count = 0
-- and psi_contrib is still finite via the eps floor. Only the *summary* macros
-- (psi_cat / psi) collapse this to 'insufficient data'.
INSERT INTO _results
SELECT 'cat_detail: empty cur keeps rows, NULL cur_pct, finite contribs',
       coalesce(count(*) = 3 AND bool_and(coalesce(cur_pct IS NULL, false))
                AND bool_and(coalesce(isfinite(psi_contrib), false)) AND bool_and(coalesce(cur_count = 0, false)), false),
       'rows=' || count(*)::VARCHAR
FROM psi_cat_detail('cat_ref', 'cat_empty', 'seg');

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
                        '_psi_all_cells', '_psi_cols');

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
SELECT 'all-helpers: _psi_all_cells shape and NULL sentinel',
       coalesce(count(*) = 1800     -- 9 columns x 200 rows
            AND count(*) FILTER (WHERE col = 'seg' AND cell.v = '(NULL)') = 50, false),
       'rows=' || count(*)::VARCHAR
FROM (UNPIVOT (SELECT * FROM _psi_all_cells('sweep_ref', 'ref'))
      ON COLUMNS(*) INTO NAME col VALUE cell);

INSERT INTO _results
SELECT 'all-helpers: _psi_cols kinds for mixed table',
       coalesce(count(*) = 9
            AND bool_and(coalesce(CASE WHEN col IN ('id', 'score', 'amount', 'ts', 'd', 'mix', 'only_ref')
                              THEN kind = 'continuous'
                              ELSE kind = 'categorical' END, false)), false),
       string_agg(col || ':' || kind, ', ' ORDER BY col)
FROM _psi_cols('sweep_ref');

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
            AND bool_and(coalesce(CASE WHEN "column" IN ('id', 'score', 'amount', 'ts', 'd')
                              THEN kind = 'continuous' AND status = 'ok'
                              WHEN "column" IN ('seg', 'flag')
                              THEN kind = 'categorical' AND status = 'ok'
                              ELSE true END, false)), false),
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
       AND bool_and(coalesce(CASE WHEN status = 'ok' THEN ref_rows = 200 AND cur_rows = 180 ELSE true END, false)), false),
       'groups/rows checked'
FROM psi_all('sweep_ref', 'sweep_cur');

INSERT INTO _results
SELECT 'all: sorted by psi desc, nulls last',
       coalesce(
           (SELECT "column" FROM psi_all('sweep_ref', 'sweep_cur') LIMIT 1) = 'ts'
       AND (SELECT bool_and(coalesce(psi IS NULL, false))
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

------------------------------------------------------------------
-- Tests: psi_all (statuses, exclude, edges)
------------------------------------------------------------------
CREATE OR REPLACE TABLE nan_sweep_ref AS SELECT (range % 10) / 10.0 AS x FROM range(100);
CREATE OR REPLACE TABLE nan_sweep_cur AS
    SELECT (range % 10) / 10.0 AS x FROM range(100)
    UNION ALL SELECT 'nan'::DOUBLE;

INSERT INTO _results
SELECT 'all: identity sweep is all zero and ok',
       coalesce(count(*) = 9 AND bool_and(coalesce(status = 'ok', false)) AND bool_and(coalesce(abs(psi) < 1e-12, false)), false),
       'rows=' || count(*)::VARCHAR
FROM psi_all('sweep_ref', 'sweep_ref');

INSERT INTO _results
SELECT 'all: ref-only column flagged, not scored',
       coalesce(bool_and(coalesce(status = 'ref only' AND psi IS NULL
                     AND interpretation = 'insufficient data'
                     AND groups IS NULL AND ref_rows = 200 AND cur_rows = 0, false)), false),
       'only_ref checked'
FROM psi_all('sweep_ref', 'sweep_cur') WHERE "column" = 'only_ref';

INSERT INTO _results
SELECT 'all: cur-only column flagged, not scored',
       coalesce(bool_and(coalesce(status = 'cur only' AND psi IS NULL
                     AND interpretation = 'insufficient data'
                     AND groups IS NULL AND ref_rows = 0 AND cur_rows = 180, false)), false),
       'only_cur checked'
FROM psi_all('sweep_ref', 'sweep_cur') WHERE "column" = 'only_cur';

-- mix is DOUBLE in ref, VARCHAR in cur, with identical value distributions:
-- analyzed as categorical (5 distinct values), flagged, psi exactly 0.
INSERT INTO _results
SELECT 'all: type mismatch analyzed as categorical and flagged',
       coalesce(bool_and(coalesce(kind = 'categorical' AND status = 'type mismatch'
                     AND abs(psi) < 1e-12 AND groups = 5, false)), false),
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
            AND bool_and(coalesce(psi IS NULL AND interpretation = 'insufficient data'
                     AND status = 'ok', false)), false),
       'rows=' || count(*)::VARCHAR
FROM psi_all('cont_empty', 'cont_ref');

INSERT INTO _results
SELECT 'all: both empty is insufficient data',
       coalesce(count(*) = 1
            AND bool_and(coalesce(psi IS NULL AND interpretation = 'insufficient data'
                     AND groups = 0 AND ref_rows = 0 AND cur_rows = 0, false)), false),
       'rows=' || count(*)::VARCHAR
FROM psi_all('cat_empty', 'cat_empty');

-- groups mirrors the single-column macros in the empty-both corner:
-- categorical = 0 observed categories (psi_cat), continuous = the one
-- open scaffold bin (psi bins_used). NULL groups stays reserved for
-- one-sided columns.
INSERT INTO _results
SELECT 'all: cont both empty keeps scaffold bin',
       coalesce(count(*) = 1
            AND bool_and(coalesce(psi IS NULL AND status = 'ok'
                     AND groups = 1 AND ref_rows = 0 AND cur_rows = 0, false)), false),
       'rows=' || count(*)::VARCHAR
FROM psi_all('cont_empty', 'cont_empty');

INSERT INTO _results
SELECT 'all: bins=1 single-bin identity',
       coalesce(bool_and(coalesce(abs(psi) < 1e-12 AND groups = 1, false)), false),
       'bins=1 checked'
FROM psi_all('cont_ref', 'cont_ref', bins := 1);

-- cat_ref has only seg, cont_ref has only score: zero shared columns is
-- not an error -- you get one-sided status rows for everything.
INSERT INTO _results
SELECT 'all: no shared columns gives status rows only',
       coalesce(count(*) = 2
            AND bool_and(coalesce(psi IS NULL AND groups IS NULL
                     AND status IN ('ref only', 'cur only'), false)), false),
       'rows=' || count(*)::VARCHAR
FROM psi_all('cat_ref', 'cont_ref');

INSERT INTO _results
SELECT 'all: fully qualified table names work',
       coalesce(bool_and(coalesce(abs(psi) < 1e-12 AND status = 'ok', false)), false),
       'db-qualified checked'
FROM psi_all('memory.main.cont_ref', 'memory.main.cont_ref');

INSERT INTO _results
SELECT 'all: views sweep like tables',
       coalesce(bool_and(coalesce(kind = 'continuous' AND status = 'ok' AND abs(psi) < 1e-12, false)), false),
       'view checked'
FROM psi_all('sweep_ref_ts', 'sweep_ref_ts');

CREATE SCHEMA IF NOT EXISTS sweep_s1;
CREATE OR REPLACE TABLE sweep_s1.qual AS SELECT range::DOUBLE AS x FROM range(50);
INSERT INTO _results
SELECT 'all: schema-qualified table names work',
       coalesce(bool_and(coalesce(abs(psi) < 1e-12 AND status = 'ok', false)), false),
       'qualified checked'
FROM psi_all('sweep_s1.qual', 'sweep_s1.qual');
-- Tests: user tables named like internal CTEs (query_table shadowing)
-- query_table resolves in-scope CTE names first — even when the
-- argument is schema-qualified — so these fixtures deliberately reuse
-- the macros' internal CTE names and must still resolve from the
-- catalog, not from a macro's own WITH chain.
------------------------------------------------------------------
CREATE OR REPLACE TABLE ref_counts AS        -- internal CTE name in psi_cat_detail
    SELECT 'A' AS seg FROM range(60)
    UNION ALL SELECT 'B' FROM range(40);

CREATE OR REPLACE TABLE ref_vals AS          -- internal CTE name in psi_detail
    SELECT range::DOUBLE + 10 AS score FROM range(100);   -- same data as cont_cur

CREATE OR REPLACE TABLE cut_points AS        -- internal CTE name in psi_detail
    SELECT range::DOUBLE AS score FROM range(100);        -- same data as cont_ref

INSERT INTO _results
SELECT 'collide: cat_detail cur table named ref_counts',
       coalesce(count(*) = 3
       AND max(CASE WHEN category = 'A' THEN cur_count END) = 60
       AND max(CASE WHEN category = 'B' THEN cur_count END) = 40
       AND max(CASE WHEN category = 'C' THEN cur_count END) = 0, false),
       'cur=' || list(cur_count ORDER BY category)::VARCHAR
FROM psi_cat_detail('cat_ref', 'ref_counts', 'seg');

INSERT INTO _results
SELECT 'collide: cat_detail qualified main.ref_counts as cur',
       coalesce(count(*) = 3
       AND max(CASE WHEN category = 'A' THEN cur_count END) = 60, false),
       'rows=' || count(*)::VARCHAR
FROM psi_cat_detail('cat_ref', 'main.ref_counts', 'seg');

INSERT INTO _results
SELECT 'collide: cat_detail ref table named ref_counts',
       coalesce(count(*) = 3
       AND max(CASE WHEN category = 'A' THEN ref_count END) = 60
       AND max(CASE WHEN category = 'B' THEN ref_count END) = 40
       AND max(CASE WHEN category = 'C' THEN ref_count END) = 0, false),
       'ref=' || list(ref_count ORDER BY category)::VARCHAR
FROM psi_cat_detail('ref_counts', 'cat_cur', 'seg');

INSERT INTO _results
SELECT 'collide: cat summary sweeps ref_counts',
       coalesce(ref_rows = 100 AND cur_rows = 100 AND categories = 3
                AND isfinite(psi), false),
       'psi=' || psi::VARCHAR
FROM psi_cat('cat_ref', 'ref_counts', 'seg');

INSERT INTO _results
SELECT 'collide: detail cur table named ref_vals',
       coalesce(bool_and(coalesce(ref_count = 25, false))
       AND list(cur_count ORDER BY bin) = [15, 25, 25, 35], false),
       'cur=' || list(cur_count ORDER BY bin)::VARCHAR
FROM psi_detail('cont_ref', 'ref_vals', 'score', bins := 4);

-- ref_vals holds the same data as cont_cur, so this is an identity pair
INSERT INTO _results
SELECT 'collide: detail ref table named ref_vals',
       coalesce(count(*) = 4 AND bool_and(coalesce(abs(psi_contrib) < 1e-12, false)), false),
       'rows=' || count(*)::VARCHAR
FROM psi_detail('ref_vals', 'cont_cur', 'score', bins := 4);

INSERT INTO _results
SELECT 'collide: psi summary known value with cur named ref_vals',
       coalesce(abs(psi - 0.08472978603872036) < 1e-9 AND cur_rows = 100, false),
       'psi=' || psi::VARCHAR
FROM psi('cont_ref', 'ref_vals', 'score', bins := 4);

-- cut_points holds the same data as cont_ref: known value one way,
-- identity zero the other
INSERT INTO _results
SELECT 'collide: table named cut_points as ref and cur',
       coalesce(
           (SELECT abs(psi - 0.08472978603872036) < 1e-9
            FROM psi('cut_points', 'ref_vals', 'score', bins := 4))
       AND (SELECT abs(psi) < 1e-12
            FROM psi('cont_ref', 'cut_points', 'score', bins := 4)), false),
       'both directions';

------------------------------------------------------------------
-- Tests: continuous sweep values preserve their native type semantics
------------------------------------------------------------------
CREATE OR REPLACE TABLE sweep_float_ref AS
    SELECT 0.7::FLOAT AS x FROM range(100);
CREATE OR REPLACE TABLE sweep_float_cur AS
    SELECT x::DOUBLE AS x FROM sweep_float_ref;
CREATE OR REPLACE TABLE sweep_float_cat AS
    SELECT x::VARCHAR AS x FROM sweep_float_ref;

INSERT INTO _results
SELECT 'all: FLOAT promotion to DOUBLE preserves zero drift',
       coalesce(
           (SELECT psi = 0 AND ref_rows = 100 AND cur_rows = 100
            FROM psi_all('sweep_float_ref', 'sweep_float_cur'))
       AND (SELECT psi = 0 FROM psi_all('sweep_float_cur', 'sweep_float_ref'))
       AND (SELECT psi = 0 FROM psi('sweep_float_ref', 'sweep_float_cur', 'x')), false),
       'both directions';

INSERT INTO _results
SELECT 'all: FLOAT categorical mismatch preserves VARCHAR categories',
       coalesce(
           (SELECT psi = 0 AND status = 'type mismatch' AND groups = 1
            FROM psi_all('sweep_float_ref', 'sweep_float_cat'))
       AND (SELECT psi = 0 FROM psi_cat('sweep_float_ref', 'sweep_float_cat', 'x')), false),
       'categorical spelling preserved';

SET TimeZone = 'America/New_York';
CREATE OR REPLACE TABLE sweep_dst_ref AS
    SELECT TIMESTAMP '2024-03-10 03:30:00' AS x FROM range(100);
CREATE OR REPLACE TABLE sweep_dst_cur AS
    SELECT TIMESTAMP '2024-03-10 02:30:00' AS x FROM range(100);
CREATE OR REPLACE VIEW sweep_dst_epoch_ref AS SELECT epoch(x) AS x FROM sweep_dst_ref;
CREATE OR REPLACE VIEW sweep_dst_epoch_cur AS SELECT epoch(x) AS x FROM sweep_dst_cur;

INSERT INTO _results
SELECT 'all: timezone-free timestamps retain drift across DST gap',
       coalesce(
           (SELECT psi > 18 FROM psi_all('sweep_dst_ref', 'sweep_dst_cur'))
       AND abs((SELECT psi FROM psi_all('sweep_dst_ref', 'sweep_dst_cur'))
             - (SELECT psi FROM psi('sweep_dst_epoch_ref', 'sweep_dst_epoch_cur', 'x'))) < 1e-12,
           false),
       'compared with native epoch views';

INSERT INTO _results
SELECT 'all-helpers: native temporal epochs preserve timezone semantics',
       coalesce(
           _psi_to_double(DATE '2024-03-10') = epoch(DATE '2024-03-10')
       AND _psi_to_double(TIMESTAMP '2024-03-10 02:30:00')
             = epoch(TIMESTAMP '2024-03-10 02:30:00')
       AND _psi_to_double(TIMESTAMPTZ '2024-11-03 01:30:00-04')
             = epoch(TIMESTAMPTZ '2024-11-03 01:30:00-04')
       AND _psi_to_double(TIMESTAMPTZ '2024-11-03 01:30:00-05')
             = epoch(TIMESTAMPTZ '2024-11-03 01:30:00-05'), false),
       'DATE, TIMESTAMP, and both repeated-hour offsets';
RESET TimeZone;

------------------------------------------------------------------
-- Tests: quoted identifiers, temporal ranges, and NULL assertions
------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS "sweep.quoted";
CREATE OR REPLACE TABLE "sweep.quoted"."feature.v1" AS SELECT 1::DOUBLE AS x;
CREATE OR REPLACE TABLE "sweep.quoted"."a""b" AS SELECT 2::DOUBLE AS x;
CREATE OR REPLACE TABLE "a._psi_ref_vals" AS SELECT 1::DOUBLE AS x;

INSERT INTO _results
SELECT 'all: quoted table and schema names preserve embedded dots',
       coalesce(count(*) = 1 AND bool_and(coalesce(psi = 0 AND ref_rows = 1 AND cur_rows = 1, false)), false),
       'fully qualified quoted identifier'
FROM psi_all('"memory"."sweep.quoted"."feature.v1"', '"sweep.quoted"."feature.v1"');

INSERT INTO _results
SELECT 'all-helpers: escaped identifier quotes match the catalog',
       coalesce(count(*) = 1 AND bool_and(coalesce(col = 'x' AND kind = 'continuous', false)), false),
       'embedded double quote'
FROM _psi_cols('"sweep.quoted"."a""b"');

INSERT INTO _results
SELECT 'collide: quoted dotted table suffix is not a reserved name',
       coalesce(psi = 0 AND ref_rows = 1 AND cur_rows = 1, false),
       'quoted dot is part of the table name'
FROM psi('"a._psi_ref_vals"', '"a._psi_ref_vals"', 'x');

CREATE OR REPLACE TABLE sweep_inf_ref AS
    SELECT d, d::TIMESTAMP AS t, d::TIMESTAMPTZ AS z FROM (
        SELECT DATE '2024-01-01' AS d FROM range(50)
        UNION ALL SELECT DATE '2024-01-10' FROM range(50));
CREATE OR REPLACE TABLE sweep_inf_cur AS
    SELECT * FROM sweep_inf_ref
    UNION ALL SELECT DATE 'infinity', TIMESTAMP 'infinity', TIMESTAMPTZ 'infinity' FROM range(100);

INSERT INTO _results
SELECT 'all: temporal infinities contribute drift and row counts',
       coalesce(count(*) = 3 AND bool_and(coalesce(
           ref_rows = 100 AND cur_rows = 200
           AND abs(psi - 0.2746530721670274) < 1e-12, false)), false),
       'DATE, TIMESTAMP, and TIMESTAMPTZ'
FROM psi_all('sweep_inf_ref', 'sweep_inf_cur', bins := 2);

CREATE OR REPLACE TABLE sweep_wide_date AS SELECT DATE '1000000-01-01' AS d;
INSERT INTO _results
SELECT 'all: wide-range non-NULL DATE is retained',
       coalesce(psi = 0 AND ref_rows = 1 AND cur_rows = 1, false),
       'date beyond TIMESTAMP range'
FROM psi_all('sweep_wide_date', 'sweep_wide_date');

INSERT INTO _results
SELECT 'all-helpers: both temporal infinity signs become numeric infinity',
       coalesce(_psi_to_double(DATE 'infinity') = 'inf'::DOUBLE
            AND _psi_to_double(DATE '-infinity') = '-inf'::DOUBLE
            AND _psi_to_double(TIMESTAMP '-infinity') = '-inf'::DOUBLE
            AND _psi_to_double(TIMESTAMPTZ '-infinity') = '-inf'::DOUBLE, false),
       'non-NULL infinities retained';

INSERT INTO _results
SELECT 'harness: a NULL row predicate fails an aggregate assertion',
       coalesce(NOT bool_and(coalesce(abs(psi) < 1e-12, false)), false),
       'one NULL among eight zero values'
FROM (SELECT CASE WHEN i = 1 THEN NULL::DOUBLE ELSE 0::DOUBLE END AS psi FROM range(9) t(i));

------------------------------------------------------------------
-- Tests: each categorical column retains its own collation
------------------------------------------------------------------
CREATE OR REPLACE TABLE sweep_coll_ref (
    plain VARCHAR, ci VARCHAR COLLATE nocase, accent VARCHAR COLLATE noaccent,
    both_rules VARCHAR COLLATE nocase.noaccent);
CREATE OR REPLACE TABLE sweep_coll_cur (
    plain VARCHAR, ci VARCHAR COLLATE nocase, accent VARCHAR COLLATE noaccent,
    both_rules VARCHAR COLLATE nocase.noaccent);
INSERT INTO sweep_coll_ref VALUES ('A', 'A', 'á', 'Á');
INSERT INTO sweep_coll_cur VALUES ('a', 'a', 'a', 'a');

INSERT INTO _results
SELECT 'all: mixed column collations preserve categorical equality',
       coalesce(count(*) = 4 AND bool_and(coalesce(
           CASE WHEN "column" = 'plain' THEN psi > 18 AND groups = 2
                ELSE psi = 0 AND groups = 1 END
           AND ref_rows = 1 AND cur_rows = 1, false)), false),
       'binary, nocase, noaccent, and combined collations'
FROM psi_all('sweep_coll_ref', 'sweep_coll_cur');

INSERT INTO _results
SELECT 'all: excluded collated columns cannot change another column',
       coalesce(count(*) = 1 AND bool_and(coalesce(
           abs(psi - (SELECT psi FROM psi_cat('sweep_coll_ref', 'sweep_coll_cur', 'plain'))) < 1e-12,
           false)), false),
       'plain comparison agrees with psi_cat'
FROM psi_all('sweep_coll_ref', 'sweep_coll_cur', exclude := ['ci', 'accent', 'both_rules']);

CREATE OR REPLACE TABLE sweep_case_ref (Score INT);
CREATE OR REPLACE TABLE sweep_case_cur (score INT);
INSERT INTO sweep_case_ref VALUES (1);
INSERT INTO sweep_case_cur VALUES (2), (3);
INSERT INTO _results
SELECT 'all: column case differences retain one-sided row counts',
       coalesce(count(*) = 2 AND bool_and(coalesce(
           CASE WHEN "column" = 'Score' THEN status = 'ref only' AND ref_rows = 1 AND cur_rows = 0
                WHEN "column" = 'score' THEN status = 'cur only' AND ref_rows = 0 AND cur_rows = 2
                ELSE false END, false)), false),
       'original names survive the combined reshape'
FROM psi_all('sweep_case_ref', 'sweep_case_cur');

------------------------------------------------------------------
-- Tests: different category collations and exact identifier matching
------------------------------------------------------------------
CREATE OR REPLACE TABLE cat_coll_ref(v VARCHAR COLLATE nocase);
CREATE OR REPLACE TABLE cat_coll_cur(v VARCHAR);
INSERT INTO cat_coll_ref VALUES ('a'), ('A'), ('b'), ('b');
INSERT INTO cat_coll_cur SELECT * FROM cat_coll_ref;
INSERT INTO _results
SELECT 'cat: different input collations cannot multiply row counts',
       coalesce(psi = 0 AND categories = 2 AND ref_rows = 4 AND cur_rows = 4, false),
       'shared case-insensitive equality'
FROM psi_cat('cat_coll_ref', 'cat_coll_cur', 'v');
INSERT INTO _results
SELECT 'cat: different input collations agree with sweep in reverse',
       coalesce(psi = 0 AND ref_rows = 4 AND cur_rows = 4
            AND psi = (SELECT psi FROM psi_all('cat_coll_cur', 'cat_coll_ref')), false),
       'both source orders'
FROM psi_cat('cat_coll_cur', 'cat_coll_ref', 'v');

CREATE OR REPLACE TABLE cat_coll_accent(v VARCHAR COLLATE noaccent);
INSERT INTO cat_coll_accent SELECT * FROM cat_coll_ref;
INSERT INTO _results
SELECT 'cat: raw values survive distinct explicit input collations',
       coalesce(psi = 0 AND ref_rows = 4 AND cur_rows = 4
            AND psi = (SELECT psi FROM psi_all('cat_coll_ref', 'cat_coll_accent')), false),
       'nocase reference and noaccent current'
FROM psi_cat('cat_coll_ref', 'cat_coll_accent', 'v');

SET default_collation = 'noaccent';
CREATE OR REPLACE TABLE sweep_accent_ref(a INT, á INT);
CREATE OR REPLACE TABLE sweep_accent_cur(a INT, á INT);
INSERT INTO sweep_accent_ref VALUES (1, 100);
INSERT INTO sweep_accent_cur VALUES (100, 1);
INSERT INTO _results
SELECT 'all: default collation cannot merge different column names',
       coalesce(count(*) = 2 AND bool_and(coalesce(
           ref_rows = 1 AND cur_rows = 1 AND groups = 2 AND status = 'ok', false))
           AND max(CASE WHEN encode("column") = encode('á') THEN psi END) > 18, false),
       'accented identifiers stay distinct'
FROM psi_all('sweep_accent_ref', 'sweep_accent_cur', bins := 2);
INSERT INTO _results
SELECT 'all: exclusions compare exact column names under noaccent',
       coalesce(count(*) = 1 AND bool_and(coalesce(encode("column") = encode('á'), false)), false),
       'excluding a retains á'
FROM psi_all('sweep_accent_ref', 'sweep_accent_cur', exclude := ['a']);
RESET default_collation;

CREATE OR REPLACE TABLE "Ä"(v INTEGER);
CREATE OR REPLACE TABLE "ä"(v INTEGER);
INSERT INTO "Ä" VALUES (1);
INSERT INTO "ä" VALUES (2), (3);
INSERT INTO _results
SELECT 'all: non-ASCII identifier case stays distinct',
       coalesce(count(*) = 1 AND bool_and(coalesce(psi = 0 AND ref_rows = 1 AND cur_rows = 1, false)), false),
       'fully qualified uppercase umlaut'
FROM psi_all('memory.main.Ä', 'memory.main.Ä');
INSERT INTO _results
SELECT 'all: ASCII identifier case still resolves case-insensitively',
       coalesce(count(*) = 1 AND bool_and(coalesce(psi = 0 AND ref_rows = 2 AND cur_rows = 2, false)), false),
       'uppercase ASCII database and schema, lowercase umlaut'
FROM psi_all('MEMORY.MAIN.ä', 'memory.main.ä');

------------------------------------------------------------------
-- Tests: small positive epsilon does not overflow the log ratio
------------------------------------------------------------------
CREATE OR REPLACE TABLE tiny_eps_ref AS SELECT 1::DOUBLE AS x;
CREATE OR REPLACE TABLE tiny_eps_cur AS SELECT 0::DOUBLE AS x;
INSERT INTO _results
SELECT 'cat: subnormal epsilon keeps PSI finite',
       coalesce(isfinite(psi) AND abs(psi - 1473.6544817819479) < 1e-9, false),
       'log difference avoids ratio overflow'
FROM psi_cat('tiny_eps_ref', 'tiny_eps_cur', 'x', eps := 1e-320);
INSERT INTO _results
SELECT 'psi: subnormal epsilon keeps PSI finite',
       coalesce(isfinite(psi) AND abs(psi - 1473.6544817819479) < 1e-9, false),
       'log difference avoids ratio overflow'
FROM psi('tiny_eps_ref', 'tiny_eps_cur', 'x', eps := 1e-320);
INSERT INTO _results
SELECT 'all: subnormal epsilon keeps PSI finite',
       coalesce(isfinite(psi) AND abs(psi - 1473.6544817819479) < 1e-9, false),
       'log difference avoids ratio overflow'
FROM psi_all('tiny_eps_ref', 'tiny_eps_cur', eps := 1e-320);

------------------------------------------------------------------
-- Tests: schema-qualified scans ignore enclosing CTEs with the same name
------------------------------------------------------------------
CREATE OR REPLACE TABLE caller_ref AS SELECT range::DOUBLE AS v FROM range(100);
CREATE OR REPLACE TABLE caller_cur AS SELECT * FROM caller_ref;
INSERT INTO _results
WITH caller_ref AS (SELECT 1000::DOUBLE AS v), caller_cur AS (SELECT -1000::DOUBLE AS v)
SELECT 'psi: schema-qualified inputs bypass caller CTEs',
       coalesce(psi = 0 AND ref_rows = 100 AND cur_rows = 100, false),
       'both physical tables are identical'
FROM psi('main.caller_ref', 'main.caller_cur', 'v');
INSERT INTO _results
WITH caller_ref AS (SELECT 1000::DOUBLE AS v), caller_cur AS (SELECT -1000::DOUBLE AS v)
SELECT 'cat: schema-qualified inputs bypass caller CTEs',
       coalesce(psi = 0 AND categories = 100 AND ref_rows = 100 AND cur_rows = 100, false),
       'both physical tables are identical'
FROM psi_cat('main.caller_ref', 'main.caller_cur', 'v');
INSERT INTO _results
WITH caller_ref AS (SELECT 1 AS other), caller_cur AS (SELECT 2 AS other)
SELECT 'all: schema-qualified inputs bypass caller CTE schemas',
       coalesce(count(*) = 1 AND bool_and(coalesce(
           psi = 0 AND ref_rows = 100 AND cur_rows = 100 AND "column" = 'v', false)), false),
       'catalog and scanned schema agree'
FROM psi_all('main.caller_ref', 'main.caller_cur');
INSERT INTO _results
SELECT 'all: embedded identifier quotes scan correctly',
       coalesce(psi = 0 AND ref_rows = 1 AND cur_rows = 1, false),
       'native binding preserves escaped double quotes'
FROM psi_all('"sweep.quoted"."a""b"', '"sweep.quoted"."a""b"');

CREATE OR REPLACE TABLE scan_temp AS SELECT 1::DOUBLE AS v;
CREATE OR REPLACE TEMP TABLE scan_temp AS SELECT 2::DOUBLE AS v FROM range(2);
INSERT INTO _results
WITH scan_temp AS (SELECT 1000::DOUBLE AS v)
SELECT 'psi: qualified scan preserves temporary table precedence',
       coalesce(psi = 0 AND ref_rows = 2 AND cur_rows = 2, false),
       'main resolves the temp table, not the CTE or persistent table'
FROM psi('main.scan_temp', 'temp.main.scan_temp', 'v');

------------------------------------------------------------------
-- Tests: nonfinite-only references cannot estimate quantile cuts
------------------------------------------------------------------
CREATE OR REPLACE TABLE nonfinite_ref AS
    SELECT 'NaN'::DOUBLE AS x FROM range(3);
CREATE OR REPLACE TABLE nonfinite_cur AS SELECT 0::DOUBLE AS x;
INSERT INTO _results
SELECT 'psi: NaN-only reference reports insufficient data with counts',
       coalesce(psi IS NULL AND interpretation = 'insufficient data'
            AND ref_rows = 3 AND cur_rows = 1, false),
       'no finite observations for quantiles'
FROM psi('nonfinite_ref', 'nonfinite_cur', 'x');
INSERT INTO _results
SELECT 'detail: undefined quantiles have NULL contributions',
       coalesce(count(*) = 1 AND bool_and(coalesce(
           psi_contrib IS NULL AND ref_count = 3 AND cur_count = 1, false)), false),
       'counts remain visible'
FROM psi_detail('nonfinite_ref', 'nonfinite_cur', 'x');
INSERT INTO _results
SELECT 'all: NaN-only reference reports insufficient data with counts',
       coalesce(psi IS NULL AND interpretation = 'insufficient data'
            AND ref_rows = 3 AND cur_rows = 1, false),
       'sweep agrees with single-column summary'
FROM psi_all('nonfinite_ref', 'nonfinite_cur');
INSERT INTO _results
SELECT 'psi: explicit single bin requires no finite reference values',
       coalesce((SELECT psi = 0 FROM psi('nonfinite_ref', 'nonfinite_cur', 'x', bins := 1))
            AND (SELECT psi = 0 FROM psi_all('nonfinite_ref', 'nonfinite_cur', bins := 1)), false),
       'explicit one-bin behavior retained';
CREATE OR REPLACE TABLE infinite_ref AS
    SELECT 'inf'::DOUBLE AS x UNION ALL SELECT '-inf'::DOUBLE;
INSERT INTO _results
SELECT 'psi: infinity-only reference reports insufficient data',
       coalesce(psi IS NULL AND interpretation = 'insufficient data'
            AND ref_rows = 2 AND cur_rows = 1, false),
       'both numeric infinity signs'
FROM psi('infinite_ref', 'nonfinite_cur', 'x');
CREATE OR REPLACE TABLE infinite_date_ref AS
    SELECT DATE 'infinity' AS d UNION ALL SELECT DATE '-infinity';
CREATE OR REPLACE TABLE infinite_date_cur AS SELECT DATE '2024-01-01' AS d;
INSERT INTO _results
SELECT 'all: temporal infinity-only reference reports insufficient data',
       coalesce(psi IS NULL AND interpretation = 'insufficient data'
            AND ref_rows = 2 AND cur_rows = 1, false),
       'temporal infinities retained in counts'
FROM psi_all('infinite_date_ref', 'infinite_date_cur');

------------------------------------------------------------------
-- Tests: decimal collections use categorical dispatch
------------------------------------------------------------------
CREATE OR REPLACE TABLE decimal_collection_ref (
    items DECIMAL(10,2)[], fixed_items DECIMAL(10,2)[1], nested DECIMAL(10,2)[][]);
CREATE OR REPLACE TABLE decimal_collection_cur AS SELECT * FROM decimal_collection_ref;
INSERT INTO decimal_collection_ref VALUES ([1.00], [1.00], [[1.00]]);
INSERT INTO decimal_collection_cur VALUES ([2.00], [2.00], [[2.00]]);
INSERT INTO _results
SELECT 'all: decimal lists and arrays retain categorical counts and drift',
       coalesce(count(*) = 3 AND bool_and(coalesce(
           kind = 'categorical' AND status = 'ok' AND groups = 2
           AND ref_rows = 1 AND cur_rows = 1
           AND abs(psi - 18.418838675877968) < 1e-12, false)), false),
       'variable, fixed, and nested decimal collections'
FROM psi_all('decimal_collection_ref', 'decimal_collection_cur');
INSERT INTO _results
SELECT 'all: decimal collection agrees with categorical summary',
       coalesce(psi = (SELECT psi FROM psi_cat(
           'decimal_collection_ref', 'decimal_collection_cur', 'items')), false),
       'single-column agreement'
FROM psi_all('decimal_collection_ref', 'decimal_collection_cur') WHERE "column" = 'items';
INSERT INTO _results
SELECT 'all-helpers: only scalar decimals are continuous',
       coalesce(_psi_kind('DECIMAL(38,0)') = 'continuous'
           AND _psi_kind('DECIMAL(10,2)[]') = 'categorical'
           AND _psi_kind('DECIMAL(10,2)[1]') = 'categorical'
           AND _psi_kind('DECIMAL(10,2)[][]') = 'categorical', false),
       'anchored scalar type matching';

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
