-- =====================================================================
-- Financial resilience of transportation and climate-policy nonprofits
-- Dialect: SQLite
-- =====================================================================
-- DATA
--   Public IRS Form 990 filings via ProPublica Nonprofit Explorer.
--   7 organizations, anonymized as Org A..Org G (see README).
--
-- TABLES
--   organizations(org_id, fiscal_year_end_month, notes)
--   filings(org_id, fiscal_year, total_revenue, total_expenses,
--           net_income, net_assets, contributions,
--           program_service_revenue, total_assets, total_liabilities)
--
-- CONVENTIONS
--   * fiscal_year = the calendar year in which the fiscal period ENDS.
--   * Primary window: 2016-2023 (every organization has data).
--   * Sensitivity window: 2017-2024 (see query 7).
--   * Some organizations skip a year; growth is only computed when the
--     previous row really is the previous year (see query 2).
--
-- METRICS
--   avg_swing_pct      average SIZE of year-over-year revenue change (ignores
--                      direction). Higher = less predictable revenue.
--   reserve_months     net assets / (annual expenses / 12). Months the
--                      organization could operate on reserves alone.
--   profile            position relative to the PEER AVERAGE on both measures,
--                      so labels are relative to this peer set, not an
--                      outside standard.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. COVERAGE CHECK  (JOIN, GROUP BY, aggregates)
--    Expect 7 rows and 91 organization-years in total.
-- ---------------------------------------------------------------------
SELECT
    o.org_id,
    o.fiscal_year_end_month,
    COUNT(*)            AS years_on_file,
    MIN(f.fiscal_year)  AS first_year,
    MAX(f.fiscal_year)  AS last_year
FROM filings AS f
JOIN organizations AS o ON f.org_id = o.org_id
GROUP BY o.org_id, o.fiscal_year_end_month
ORDER BY o.org_id;


-- ---------------------------------------------------------------------
-- 2. YEAR-OVER-YEAR REVENUE GROWTH  (CTE, window function LAG, CASE)
--    PARTITION BY restarts the window for each organization.
--    The CASE guard leaves growth blank when a year is missing, so we never
--    compare across a gap.
-- ---------------------------------------------------------------------
WITH growth AS (
    SELECT
        f.org_id,
        f.fiscal_year,
        f.total_revenue,
        LAG(f.total_revenue) OVER (PARTITION BY f.org_id ORDER BY f.fiscal_year) AS prev_revenue,
        LAG(f.fiscal_year)   OVER (PARTITION BY f.org_id ORDER BY f.fiscal_year) AS prev_year
    FROM filings AS f
)
SELECT
    org_id,
    fiscal_year,
    total_revenue,
    CASE WHEN prev_year = fiscal_year - 1
         THEN ROUND(100.0 * (total_revenue - prev_revenue) / prev_revenue, 1)
    END AS yoy_pct
FROM growth
WHERE fiscal_year BETWEEN 2016 AND 2023
ORDER BY org_id, fiscal_year;


-- ---------------------------------------------------------------------
-- 3. EACH YEAR VS THE ORGANIZATION'S OWN AVERAGE  (subquery + CTE + CASE)
--    The scalar subquery runs once per row and returns that organization's
--    average revenue.
-- ---------------------------------------------------------------------
WITH revenue_with_avg AS (
    SELECT
        f.org_id,
        f.fiscal_year,
        f.total_revenue,
        (SELECT ROUND(AVG(total_revenue), 0)
         FROM filings
         WHERE org_id = f.org_id) AS org_avg_revenue
    FROM filings AS f
)
SELECT
    org_id,
    fiscal_year,
    total_revenue,
    org_avg_revenue,
    CASE
        WHEN total_revenue > org_avg_revenue THEN 'Above own average'
        ELSE 'At or below own average'
    END AS vs_own_average
FROM revenue_with_avg
ORDER BY org_id, fiscal_year;


-- ---------------------------------------------------------------------
-- 4. REVENUE VOLATILITY RANKING  (chained CTEs, GROUP BY, RANK window)
--    Rank 1 = most volatile. Note: for fast-growing organizations part of
--    the "swing" is growth, not instability (see README limitations).
-- ---------------------------------------------------------------------
WITH growth AS (
    SELECT
        f.org_id,
        f.fiscal_year,
        f.total_revenue,
        LAG(f.total_revenue) OVER (PARTITION BY f.org_id ORDER BY f.fiscal_year) AS prev_revenue,
        LAG(f.fiscal_year)   OVER (PARTITION BY f.org_id ORDER BY f.fiscal_year) AS prev_year
    FROM filings AS f
),
yoy AS (
    SELECT
        org_id,
        fiscal_year,
        CASE WHEN prev_year = fiscal_year - 1
             THEN 100.0 * (total_revenue - prev_revenue) / prev_revenue
        END AS yoy_pct
    FROM growth
    WHERE fiscal_year BETWEEN 2016 AND 2023
)
SELECT
    org_id,
    COUNT(yoy_pct)                  AS years_measured,
    ROUND(AVG(ABS(yoy_pct)), 1)     AS avg_swing_pct,
    ROUND(MIN(yoy_pct), 1)          AS worst_year_pct,
    ROUND(MAX(yoy_pct), 1)          AS best_year_pct,
    RANK() OVER (ORDER BY AVG(ABS(yoy_pct)) DESC) AS volatility_rank
FROM yoy
GROUP BY org_id
ORDER BY volatility_rank;


-- ---------------------------------------------------------------------
-- 5. RESILIENCE SCORECARD  (CTE, conditional aggregation)
--    Multi-year averages, not a single-year snapshot: a single year can
--    mislead (an organization's worst year can make it look thinnest).
-- ---------------------------------------------------------------------
WITH yearly AS (
    SELECT
        f.org_id,
        f.fiscal_year,
        f.net_income,
        100.0 * f.net_income / f.total_revenue     AS margin_pct,
        100.0 * f.contributions / f.total_revenue  AS contrib_share_pct,
        f.net_assets / (f.total_expenses / 12.0)   AS reserve_months
    FROM filings AS f
    WHERE f.fiscal_year BETWEEN 2016 AND 2023
)
SELECT
    org_id,
    SUM(CASE WHEN net_income < 0 THEN 1 ELSE 0 END) AS deficit_years,
    ROUND(AVG(margin_pct), 1)         AS avg_margin_pct,
    ROUND(AVG(contrib_share_pct), 1)  AS avg_contrib_share_pct,
    ROUND(AVG(reserve_months), 1)     AS avg_reserve_months,
    ROUND(MIN(reserve_months), 1)     AS min_reserve_months
FROM yearly
GROUP BY org_id
ORDER BY avg_reserve_months DESC;


-- ---------------------------------------------------------------------
-- 6. HEADLINE: SWINGS VS BUFFER PROFILE, PRIMARY WINDOW 2016-2023
--    AVG(...) OVER () attaches the peer-group average to every row without
--    collapsing the rows, so each organization is compared with the group.
-- ---------------------------------------------------------------------
WITH growth AS (
    SELECT
        f.org_id, f.fiscal_year, f.total_revenue,
        LAG(f.total_revenue) OVER (PARTITION BY f.org_id ORDER BY f.fiscal_year) AS prev_revenue,
        LAG(f.fiscal_year)   OVER (PARTITION BY f.org_id ORDER BY f.fiscal_year) AS prev_year
    FROM filings AS f
),
volatility AS (
    SELECT
        org_id,
        AVG(ABS(100.0 * (total_revenue - prev_revenue) / prev_revenue)) AS avg_swing_pct
    FROM growth
    WHERE fiscal_year BETWEEN 2016 AND 2023
      AND prev_year = fiscal_year - 1
    GROUP BY org_id
),
buffer AS (
    SELECT
        org_id,
        AVG(net_assets / (total_expenses / 12.0)) AS avg_reserve_months
    FROM filings
    WHERE fiscal_year BETWEEN 2016 AND 2023
    GROUP BY org_id
),
combined AS (
    SELECT
        o.org_id,
        ROUND(v.avg_swing_pct, 1)       AS avg_swing_pct,
        ROUND(b.avg_reserve_months, 1)  AS avg_reserve_months,
        AVG(v.avg_swing_pct)      OVER () AS peer_avg_swing,
        AVG(b.avg_reserve_months) OVER () AS peer_avg_reserve
    FROM organizations AS o
    JOIN volatility AS v ON o.org_id = v.org_id
    JOIN buffer     AS b ON o.org_id = b.org_id
)
SELECT
    org_id,
    avg_swing_pct,
    avg_reserve_months,
    CASE
        WHEN avg_swing_pct >  peer_avg_swing AND avg_reserve_months <  peer_avg_reserve THEN 'High swings, thin buffer'
        WHEN avg_swing_pct >  peer_avg_swing AND avg_reserve_months >= peer_avg_reserve THEN 'High swings, strong buffer'
        WHEN avg_swing_pct <= peer_avg_swing AND avg_reserve_months <  peer_avg_reserve THEN 'Steady, thin buffer'
        ELSE 'Steady, strong buffer'
    END AS profile
FROM combined
ORDER BY profile, org_id;


-- ---------------------------------------------------------------------
-- 7. SENSITIVITY CHECK: THE SAME QUERY ON 2017-2024
--    Identical to query 6 except the window. Compare the two profile
--    columns: an organization whose label changes is borderline.
-- ---------------------------------------------------------------------
WITH growth AS (
    SELECT
        f.org_id, f.fiscal_year, f.total_revenue,
        LAG(f.total_revenue) OVER (PARTITION BY f.org_id ORDER BY f.fiscal_year) AS prev_revenue,
        LAG(f.fiscal_year)   OVER (PARTITION BY f.org_id ORDER BY f.fiscal_year) AS prev_year
    FROM filings AS f
),
volatility AS (
    SELECT
        org_id,
        AVG(ABS(100.0 * (total_revenue - prev_revenue) / prev_revenue)) AS avg_swing_pct
    FROM growth
    WHERE fiscal_year BETWEEN 2017 AND 2024
      AND prev_year = fiscal_year - 1
    GROUP BY org_id
),
buffer AS (
    SELECT
        org_id,
        AVG(net_assets / (total_expenses / 12.0)) AS avg_reserve_months
    FROM filings
    WHERE fiscal_year BETWEEN 2017 AND 2024
    GROUP BY org_id
),
combined AS (
    SELECT
        o.org_id,
        ROUND(v.avg_swing_pct, 1)       AS avg_swing_pct,
        ROUND(b.avg_reserve_months, 1)  AS avg_reserve_months,
        AVG(v.avg_swing_pct)      OVER () AS peer_avg_swing,
        AVG(b.avg_reserve_months) OVER () AS peer_avg_reserve
    FROM organizations AS o
    JOIN volatility AS v ON o.org_id = v.org_id
    JOIN buffer     AS b ON o.org_id = b.org_id
)
SELECT
    org_id,
    avg_swing_pct,
    avg_reserve_months,
    CASE
        WHEN avg_swing_pct >  peer_avg_swing AND avg_reserve_months <  peer_avg_reserve THEN 'High swings, thin buffer'
        WHEN avg_swing_pct >  peer_avg_swing AND avg_reserve_months >= peer_avg_reserve THEN 'High swings, strong buffer'
        WHEN avg_swing_pct <= peer_avg_swing AND avg_reserve_months <  peer_avg_reserve THEN 'Steady, thin buffer'
        ELSE 'Steady, strong buffer'
    END AS profile
FROM combined
ORDER BY profile, org_id;
