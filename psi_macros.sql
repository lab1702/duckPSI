-- psi_macros.sql — Population Stability Index (PSI) as pure DuckDB SQL table macros.
-- Requires DuckDB >= 1.3 (Python-style lambdas). Load with:  .read psi_macros.sql

-- ==================================================================
-- psi_cat_detail(ref_tbl, cur_tbl, col, eps := 1e-4)
-- Categorical PSI detail: one row per distinct value across BOTH
-- populations (full outer join). NULL is its own '(NULL)' category.
-- ref_pct / cur_pct are true proportions; only psi_contrib uses the
-- eps-floored values.
-- ==================================================================
CREATE OR REPLACE MACRO psi_cat_detail(ref_tbl, cur_tbl, col, eps := 1e-4) AS TABLE
WITH
-- The two query_table scans MUST stay the first CTEs in this chain:
-- query_table resolves CTE names in scope (even when the argument is
-- schema-qualified), so a scan placed after an internal CTE would
-- silently read a like-named CTE instead of the user's table. At the
-- head, the only CTE name visible to the cur-side scan is
-- _psi_cat_ref_counts; the guard below turns that one residual
-- collision into an error instead of a silent mis-resolution. The
-- ref-side scan sees no CTEs at all, so any ref name resolves from the
-- catalog.
-- Grouping directly on the casted expression keeps each input single-
-- referenced, so DuckDB streams the base scans instead of materializing
-- a per-row VARCHAR copy of each table.
_psi_cat_ref_counts AS (
    SELECT coalesce(v::VARCHAR, '(NULL)') AS v, count(*) AS cnt
    FROM (SELECT COLUMNS('^' || col || '$') AS v FROM query_table(ref_tbl))
    GROUP BY 1
),
_psi_cat_cur_counts AS (
    SELECT coalesce(v::VARCHAR, '(NULL)') AS v, count(*) AS cnt
    FROM (SELECT COLUMNS('^' || col || '$') AS v FROM query_table(
        CASE WHEN string_split(lower(cur_tbl), '.')[-1] = '_psi_cat_ref_counts'
             THEN error('psi_cat_detail: the table name ''_psi_cat_ref_counts'' is reserved by psi_cat_detail; rename that table to compare it')
             ELSE cur_tbl END))
    GROUP BY 1
),
merged AS (
    SELECT coalesce(r.v, u.v) AS category,
           coalesce(r.cnt, 0)::BIGINT AS ref_count,
           coalesce(u.cnt, 0)::BIGINT AS cur_count
    FROM _psi_cat_ref_counts r
    FULL OUTER JOIN _psi_cat_cur_counts u ON r.v = u.v
),
pcts AS (
    -- the window sums equal count(*) of each input: the full outer join
    -- preserves every per-category count from both sides
    SELECT category, ref_count, cur_count,
           ref_count / nullif(sum(ref_count) OVER (), 0)::DOUBLE AS ref_pct,
           cur_count / nullif(sum(cur_count) OVER (), 0)::DOUBLE AS cur_pct
    FROM merged
)
SELECT category, ref_count, cur_count, ref_pct, cur_pct,
       (greatest(cur_pct, eps) - greatest(ref_pct, eps))
         * ln(greatest(cur_pct, eps) / greatest(ref_pct, eps)) AS psi_contrib
FROM pcts
ORDER BY category;

-- ==================================================================
-- psi_detail(ref_tbl, cur_tbl, col, bins := 10, eps := 1e-4)
-- Continuous PSI detail. Cut points are APPROXIMATE quantiles
-- (approx_quantile / T-Digest) of the REFERENCE population at i/bins
-- (i = 1 .. bins-1), deduplicated — heavily tied data can therefore
-- yield fewer bins than requested. Approximate quantiles keep memory
-- bounded (they do not materialize the reference), so this scales to
-- reference data larger than RAM; the cut points are not bit-exact
-- reproducible. Bins are half-open [lo, hi); bin 1 is (-inf, cut1) and
-- the last bin is [cut_last, +inf), so out-of-range current values land
-- in the edge bins. NULLs are excluded from both populations.
-- ==================================================================
CREATE OR REPLACE MACRO psi_detail(ref_tbl, cur_tbl, col, bins := 10, eps := 1e-4) AS TABLE
WITH
-- The two query_table scans MUST stay the first CTEs in this chain, and
-- no other part of this macro may call query_table: query_table resolves
-- CTE names in scope (even when the argument is schema-qualified), so a
-- scan placed after an internal CTE would silently read a like-named CTE
-- instead of the user's table. At the head, the only CTE name visible to
-- the cur-side scan is _psi_ref_vals; the guard below turns that one
-- residual collision into an error instead of a silent mis-resolution.
-- The ref-side scan sees no CTEs at all, so any ref name resolves from
-- the catalog.
_psi_ref_vals AS (
    SELECT v::DOUBLE AS v
    FROM (SELECT COLUMNS('^' || col || '$') AS v FROM query_table(ref_tbl))
    WHERE v IS NOT NULL
),
_psi_cur_vals AS (
    SELECT v::DOUBLE AS v
    FROM (SELECT COLUMNS('^' || col || '$') AS v FROM query_table(
        CASE WHEN string_split(lower(cur_tbl), '.')[-1] = '_psi_ref_vals'
             THEN error('psi_detail: the table name ''_psi_ref_vals'' is reserved by psi_detail; rename that table to compare it')
             ELSE cur_tbl END))
    WHERE v IS NOT NULL
),
-- Cut points are APPROXIMATE quantiles (T-Digest) of the reference at i/bins.
-- approx_quantile is a bounded-memory, single-pass streaming sketch: unlike the
-- exact quantile_cont it never materializes the whole reference column, so it
-- scales to reference data larger than RAM (quantile_cont holds every value in
-- RAM and ignores memory_limit) and is roughly 20x faster. The quantile
-- fractions must be FLOAT[]; the returned cut values are DOUBLE. neg_cuts (the
-- negated, reversed cut list) drives the histogram binning below.
cut_points AS (
    SELECT cuts, list_reverse(list_transform(cuts, lambda x: -x)) AS neg_cuts
    FROM (
        SELECT CASE WHEN bins < 1 THEN error('bins must be >= 1')
                    ELSE coalesce(
                        list_sort(list_distinct(
                            approx_quantile(v, list_transform(generate_series(1, bins - 1),
                                                              lambda i: (i / bins::DOUBLE)::FLOAT))
                        )),
                        [])
               END AS cuts
        FROM _psi_ref_vals
    )
),
bin_scaffold AS (
    SELECT unnest(generate_series(1, len(cuts) + 1)) AS bin FROM cut_points
),
-- Binning uses the native histogram() aggregate: one streaming C++ pass per
-- population with no per-row list allocation. histogram(x, bounds) is
-- UPPER-inclusive (x is placed in the smallest bound >= x, so x on a bound goes
-- to the lower bin) -- the opposite of our half-open [lo, hi) rule. Binning -v
-- against the negated, reversed cuts flips that back: -v <= -c <=> v >= c, so a
-- value exactly on a cut lands in the UPPER bin. The histogram map keys are the
-- (negated) bounds used, plus 'inf' for values above every bound == v below
-- every cut == bin 1; a key -c otherwise maps to the bin whose lower edge is c,
-- i.e. bin = list_position(cuts, -key) + 1. histogram over empty input returns a
-- NULL map -> no rows -> every scaffold bin defaults to 0.
-- (DuckDB total-orders NaN as its maximum value, so -NaN is the minimum and
-- histogram places it in the lowest negated bound == the top bin, matching the
-- documented "NaN lands in the top bin" behavior.)
ref_hist AS (
    SELECT histogram(-r.v, c.neg_cuts) AS h
    FROM _psi_ref_vals r CROSS JOIN cut_points c
),
cur_hist AS (
    SELECT histogram(-u.v, c.neg_cuts) AS h
    FROM _psi_cur_vals u CROSS JOIN cut_points c
),
ref_counts AS (
    SELECT CASE WHEN isinf(k) THEN 1 ELSE list_position(c.cuts, -k) + 1 END AS bin,
           cnt
    FROM (SELECT unnest(map_keys(h)) AS k, unnest(map_values(h)) AS cnt FROM ref_hist)
    CROSS JOIN cut_points c
),
cur_counts AS (
    SELECT CASE WHEN isinf(k) THEN 1 ELSE list_position(c.cuts, -k) + 1 END AS bin,
           cnt
    FROM (SELECT unnest(map_keys(h)) AS k, unnest(map_values(h)) AS cnt FROM cur_hist)
    CROSS JOIN cut_points c
),
merged AS (
    -- the window sums equal count(*) of each input: every non-NULL value lands
    -- in exactly one scaffold bin. Deriving totals here (instead of counting the
    -- inputs again) keeps each population scanned once for binning.
    SELECT b.bin,
           coalesce(r.cnt, 0)::BIGINT AS ref_count,
           coalesce(u.cnt, 0)::BIGINT AS cur_count,
           c.cuts,
           sum(coalesce(r.cnt, 0)) OVER () AS ref_total,
           sum(coalesce(u.cnt, 0)) OVER () AS cur_total
    FROM bin_scaffold b
    CROSS JOIN cut_points c
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

-- Column catalog for a table or view: (col, kind). Accepts a bare name,
-- 'schema.table', or 'database.schema.table', matched case-insensitively
-- (mirroring query_table resolution). Errors if a name matches more than
-- one table across schemas or databases (rather than guessing which one
-- query_table will bind) or matches nothing.
CREATE OR REPLACE MACRO _psi_cols(tbl) AS TABLE
WITH matches AS (
    SELECT database_name, schema_name, table_name, column_name, data_type
    FROM duckdb_columns()
    WHERE NOT "internal"
      AND CASE WHEN len(string_split(tbl, '.')) = 3
               THEN lower(database_name || '.' || schema_name || '.' || table_name) = lower(tbl)
               WHEN contains(tbl, '.')
               THEN lower(schema_name || '.' || table_name) = lower(tbl)
               ELSE lower(table_name) = lower(tbl) END
),
guard AS (
    SELECT CASE
        WHEN count(DISTINCT database_name || '.' || schema_name || '.' || table_name) > 1
          THEN error('psi_all: table name ''' || tbl || ''' matches more than one table; qualify as schema.table or database.schema.table')
        WHEN count(*) = 0
          THEN error('psi_all: table ''' || tbl || ''' not found')
        ELSE true END AS ok
    FROM matches
)
SELECT m.column_name AS col, _psi_kind(m.data_type) AS kind
FROM matches m CROSS JOIN guard g
WHERE g.ok;

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
-- The long-form scans MUST be the first CTEs in this chain, and no other
-- part of this macro may call query_table: query_table resolves CTE names
-- in scope (even when the argument is schema-qualified), so a
-- query_table(cur_tbl) placed after e.g. the cat_ref CTE would silently
-- read that CTE instead of a user table named 'cat_ref'. Hoisted to the
-- head, the only CTE name visible to any query_table call is
-- _psi_all_ref_long (visible from the second body); the guard below turns
-- that one residual collision into an error instead of a silent
-- mis-resolution. The ref-side scan sees no CTEs at all, so any ref name
-- resolves from the catalog.
_psi_all_ref_long AS (
    SELECT col, v FROM _psi_all_long(ref_tbl)
),
_psi_all_cur_long AS (
    SELECT col, v FROM _psi_all_long(
        CASE WHEN string_split(lower(cur_tbl), '.')[-1] = '_psi_all_ref_long'
             THEN error('psi_all: the table name ''_psi_all_ref_long'' is reserved by psi_all; rename the table')
             ELSE cur_tbl END)
),
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
    WHERE CASE WHEN bins < 1 THEN error('bins must be >= 1') ELSE true END
      AND NOT list_contains(exclude::VARCHAR[], coalesce(r.col, c.col))
),
-- ---- categorical branch: psi_cat_detail's math, partitioned by col ----
cat_ref AS (
    SELECT l.col, l.v AS category, count(*) AS cnt
    FROM _psi_all_ref_long l JOIN cols k ON l.col = k.col
    WHERE k.kind = 'categorical'
    GROUP BY 1, 2
),
cat_cur AS (
    SELECT l.col, l.v AS category, count(*) AS cnt
    FROM _psi_all_cur_long l JOIN cols k ON l.col = k.col
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
        FROM _psi_all_ref_long l JOIN cols k ON l.col = k.col
        WHERE k.kind = 'continuous'
    ) WHERE vd IS NOT NULL
),
cont_cur_vals AS (
    SELECT col, vd FROM (
        SELECT l.col, _psi_to_double(l.v) AS vd
        FROM _psi_all_cur_long l JOIN cols k ON l.col = k.col
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
-- every continuous column gets rows even when one side is empty. (bins
-- is validated in the cols CTE: any sweep with at least one non-excluded
-- column errors on bins < 1; excluding every column yields an empty
-- result instead of an error.)
cont_scaffold AS (
    SELECT k.col,
           unnest(generate_series(1, coalesce(len(c.cuts), 0) + 1)) AS bin
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
       -- misleading (it reflects only the present side); NULL groups means
       -- exactly that. A two-sided categorical column with both tables
       -- empty has no summary row at all (its GROUP BY sees zero long-form
       -- rows), so coalesce to 0 observed categories -- matching psi_cat,
       -- while the continuous branch keeps its catalog scaffold row
       -- (groups = 1, matching psi bins_used).
       CASE WHEN k.status IN ('ref only', 'cur only') THEN NULL
            ELSE coalesce(s.groups, 0) END AS groups,
       coalesce(s.ref_rows, 0) AS ref_rows,
       coalesce(s.cur_rows, 0) AS cur_rows
FROM cols k LEFT JOIN summaries s ON k.col = s.col
ORDER BY s.psi DESC NULLS LAST, k.col;
