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
-- grouping directly on the casted expression keeps each input single-
-- referenced, so DuckDB streams the base scans instead of materializing
-- a per-row VARCHAR copy of each table
ref_counts AS (
    SELECT coalesce(v::VARCHAR, '(NULL)') AS v, count(*) AS cnt
    FROM (SELECT COLUMNS('^' || col || '$') AS v FROM query_table(ref_tbl))
    GROUP BY 1
),
cur_counts AS (
    SELECT coalesce(v::VARCHAR, '(NULL)') AS v, count(*) AS cnt
    FROM (SELECT COLUMNS('^' || col || '$') AS v FROM query_table(cur_tbl))
    GROUP BY 1
),
merged AS (
    SELECT coalesce(r.v, u.v) AS category,
           coalesce(r.cnt, 0)::BIGINT AS ref_count,
           coalesce(u.cnt, 0)::BIGINT AS cur_count
    FROM ref_counts r
    FULL OUTER JOIN cur_counts u ON r.v = u.v
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
    SELECT CASE WHEN bins < 1 THEN error('bins must be >= 1')
                ELSE coalesce(
                    list_sort(list_distinct(
                        quantile_cont(v, list_transform(generate_series(1, bins - 1),
                                                        lambda i: i / bins::DOUBLE))
                    )),
                    [])
           END AS cuts
    FROM ref_vals
),
totals AS (
    SELECT (SELECT count(*) FROM ref_vals) AS ref_total,
           (SELECT count(*) FROM cur_vals) AS cur_total
),
bin_scaffold AS (
    SELECT unnest(generate_series(1, len(cuts) + 1)) AS bin FROM cut_points
),
-- bin = index of the first cut greater than v (NULL when none -> last
-- bin); equivalent to counting cuts <= v, so a value exactly on a cut
-- stays in the upper bin. list_position early-exits at the first match,
-- unlike a full list_filter pass.
ref_counts AS (
    SELECT coalesce(list_position(list_transform(c.cuts, lambda x: r.v < x), true),
                    len(c.cuts) + 1) AS bin,
           count(*) AS cnt
    FROM ref_vals r CROSS JOIN cut_points c
    GROUP BY 1
),
cur_counts AS (
    SELECT coalesce(list_position(list_transform(c.cuts, lambda x: u.v < x), true),
                    len(c.cuts) + 1) AS bin,
           count(*) AS cnt
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
