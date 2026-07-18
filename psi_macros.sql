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
