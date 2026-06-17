-- ============================================================================
-- PART 2: BUILDING A TRUSTED SEMANTIC LAYER WITH SNOWFLAKE HORIZON CONTEXT
-- From Scattered Definitions to a Single Source of Meaning
-- ============================================================================

-- ============================================================================
-- INTRODUCTION: THE SEMANTIC LAYER PROBLEM NOBODY WANTS TO ADMIT
-- ============================================================================
--
-- Every enterprise has a semantic layer. Most just don't realize it's 
-- distributed across 47 Tableau calculated fields, 23 dbt metrics, 
-- 15 Power BI DAX measures, and an undocumented stored procedure that 
-- "Dave from Finance wrote in 2019 and nobody touches anymore."
--
-- This isn't a tooling failure. It's an architectural gap. Business logic —
-- the rules that define what "active customer" means, how "net revenue" is 
-- calculated, where fiscal quarters begin and end — accretes in whatever tool
-- is closest to the person who needs it. Over time, these definitions diverge.
-- Slowly at first, then catastrophically when an AI agent averages two 
-- contradictory definitions and presents the result to your board.
--
-- Part 1 covered the end-to-end architecture of Horizon Context. This article
-- goes deep on the semantic layer itself: how to design it, build it, govern 
-- it, and make it the authoritative source of business meaning for every 
-- consumer — human, dashboard, or AI agent.
-- ============================================================================


-- ============================================================================
-- 1. WHAT A TRUSTED SEMANTIC LAYER ACTUALLY REQUIRES
-- ============================================================================
--
-- A semantic layer isn't just a view with comments. A *trusted* semantic layer
-- must satisfy five properties:
--
-- ┌──────────────┬─────────────────────────────────────┬──────────────────────────────────────┐
-- │ Property     │ Definition                          │ Without It                           │
-- ├──────────────┼─────────────────────────────────────┼──────────────────────────────────────┤
-- │ Authoritative│ One definition per concept, owned   │ Multiple conflicting definitions     │
-- │ Discoverable │ Consumers find it without searching │ Tribal knowledge, Slack questions     │
-- │ Queryable    │ Definitions execute as SQL          │ Documentation that drifts from reality│
-- │ Governed     │ Changes reviewed, certified, versioned│ Silent drift, broken trust          │
-- │ Active       │ AI/BI consume definitions auto      │ Manual lookups, copy-paste logic     │
-- └──────────────┴─────────────────────────────────────┴──────────────────────────────────────┘
--
-- Snowflake Semantic Views satisfy all five. But building them well requires
-- deliberate design.
-- ============================================================================


-- ============================================================================
-- 2. SEMANTIC VIEW DESIGN PRINCIPLES
-- ============================================================================
--
-- PRINCIPLE 1: Domain Boundaries Over Monoliths
-- ─────────────────────────────────────────────
-- Don't build one semantic view that covers the entire business. 
-- Organize by business domain:
--
--   finance_revenue     → Owner: Finance Analytics
--   sales_pipeline      → Owner: Revenue Operations  
--   product_usage       → Owner: Product Analytics
--   customer_health     → Owner: Customer Success
--   marketing_perf      → Owner: Growth Analytics
--
-- Domain boundaries map to ownership boundaries. The Finance team certifies
-- revenue metrics. Product certifies usage metrics. When ownership is clear,
-- accountability follows.
--
-- PRINCIPLE 2: Metrics Are Contracts, Not Convenience
-- ───────────────────────────────────────────────────
-- Every metric is a contract with consumers. Treat it like a public API:
--   • Breaking changes require deprecation notices and migration paths
--   • Semantic changes (same name, different meaning) are never acceptable
--   • Additions are safe; removals require a sunset period
--
-- PRINCIPLE 3: Relationships Are Explicit, Never Implied
-- ─────────────────────────────────────────────────────
-- AI agents cannot infer join paths from naming conventions. Every 
-- relationship must be explicitly declared.
--
-- PRINCIPLE 4: Time Is Never Simple
-- ─────────────────────────────────
-- Fiscal calendars, timezone handling, and time grain definitions are the
-- source of more metric inconsistencies than any other factor.
--
-- PRINCIPLE 5: Filters Define Valid Contexts
-- ──────────────────────────────────────────
-- Not every metric makes sense with every filter. Declare valid contexts.
-- ============================================================================


-- ============================================================================
-- 3. BUILDING YOUR FIRST PRODUCTION SEMANTIC VIEW
-- ============================================================================

-- Step 1: Understand the underlying data model
-- Before writing any semantic definition, map the physical data model.

-- Understand the grain and cardinality of your fact table
SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT customer_id) AS distinct_customers,
    COUNT(DISTINCT product_id) AS distinct_products,
    MIN(recognized_date) AS earliest_date,
    MAX(recognized_date) AS latest_date,
    COUNT(DISTINCT DATE_TRUNC('month', recognized_date)) AS months_of_data
FROM analytics.marts.fct_revenue;

-- Verify join integrity before declaring relationships
-- This MUST return zero before you declare this relationship in a semantic view
SELECT
    COUNT(*) AS orphan_records
FROM analytics.marts.fct_revenue r
LEFT JOIN analytics.marts.dim_customer c ON r.customer_id = c.customer_id
WHERE c.customer_id IS NULL;

-- Verify product dimension join integrity
SELECT
    COUNT(*) AS orphan_records
FROM analytics.marts.fct_revenue r
LEFT JOIN analytics.marts.dim_product p ON r.product_id = p.product_id
WHERE p.product_id IS NULL;


-- ============================================================================
-- Step 2: The Complete Semantic View Definition (YAML Reference)
-- ============================================================================
--
-- name: finance_revenue
-- version: "2.1.0"
-- description: >
--   Authoritative semantic model for all revenue metrics.
--   Covers recognized revenue (ASC 606), bookings, and recurring revenue.
--   
--   IMPORTANT: This model uses RECOGNIZED revenue, not bookings or billings.
--   For bookings metrics, see sales_bookings semantic view.
--   For billings/cash-based metrics, see finance_cash_flow semantic view.
--   
--   Fiscal calendar: Year begins February 1. Q1=Feb-Apr, Q2=May-Jul,
--   Q3=Aug-Oct, Q4=Nov-Jan.
--
-- owner: finance-analytics@company.com
-- certification:
--   status: certified
--   certified_by: VP Finance Analytics
--   certified_date: "2025-11-15"
--   next_review: "2026-02-15"
--
-- tables:
--   - name: fct_revenue
--     base_table: analytics.marts.fct_revenue
--     description: >
--       Grain: One row per revenue recognition event.
--       A single contract may produce multiple recognition events.
--     primary_key: revenue_event_id
--     columns:
--       - name: revenue_event_id
--         description: Surrogate key for the recognition event
--         data_type: VARCHAR
--       - name: customer_id
--         description: FK to dim_customer
--         data_type: VARCHAR
--       - name: product_id
--         description: FK to dim_product
--         data_type: VARCHAR
--       - name: contract_id
--         description: Source contract from billing system
--         data_type: VARCHAR
--       - name: recognized_date
--         description: >
--           Date revenue was recognized per ASC 606 rules.
--           NOT the same as booking date, invoice date, or payment date.
--         data_type: DATE
--       - name: amount_usd
--         description: >
--           Revenue in USD using exchange rate on recognition date.
--           Original currency in amount_local and currency_code.
--         data_type: NUMBER(18,2)
--       - name: revenue_type
--         description: "subscription, professional_services, usage, one_time"
--         data_type: VARCHAR
--       - name: is_recurring
--         description: >
--           TRUE if revenue_type IN ('subscription', 'usage').
--           Basis for ARR/MRR calculations.
--         data_type: BOOLEAN
--
--   - name: dim_customer
--     base_table: analytics.marts.dim_customer
--     description: Customer dimension with current-state attributes (SCD Type 1)
--     primary_key: customer_id
--     columns:
--       - name: customer_id
--         data_type: VARCHAR
--       - name: customer_name
--         data_type: VARCHAR
--       - name: segment
--         description: >
--           Enterprise = ARR >= $100K
--           Mid-Market = $25K <= ARR < $100K
--           SMB = ARR < $25K
--         data_type: VARCHAR
--       - name: region
--         description: "AMER, EMEA, APAC based on HQ billing address"
--         data_type: VARCHAR
--       - name: industry
--         description: NAICS-based industry classification
--         data_type: VARCHAR
--
-- relationships:
--   - name: revenue_to_customer
--     left_table: fct_revenue
--     right_table: dim_customer
--     join_type: many_to_one
--     on:
--       - left_column: customer_id
--         right_column: customer_id
--
--   - name: revenue_to_product
--     left_table: fct_revenue
--     right_table: dim_product
--     join_type: many_to_one
--     on:
--       - left_column: product_id
--         right_column: product_id
--
-- metrics:
--   (See SQL implementations below)
--
-- time_dimensions:
--   - name: recognized_date
--     table: fct_revenue
--     column: recognized_date
--     time_grains: [day, week, month, quarter, year]
--     fiscal_year_start_month: 2
--     week_start_day: monday
-- ============================================================================


-- ============================================================================
-- Step 3: Metric SQL Implementations
-- ============================================================================

-- METRIC: total_revenue
-- Definition: Total recognized revenue in USD across all revenue types.
-- Includes: subscription, services, usage, one-time.
-- Excludes: deferred revenue, credits, refunds (netted at source).
SELECT
    DATE_TRUNC('month', recognized_date) AS period_month,
    SUM(amount_usd) AS total_revenue
FROM analytics.marts.fct_revenue
WHERE recognized_date >= DATEADD('month', -12, CURRENT_DATE())
GROUP BY 1
ORDER BY 1;


-- METRIC: recurring_revenue (Monthly)
-- Definition: Revenue from subscription and usage-based products.
-- This is the numerator for MRR and ARR calculations.
SELECT
    DATE_TRUNC('month', recognized_date) AS period_month,
    SUM(CASE WHEN is_recurring = TRUE THEN amount_usd ELSE 0 END) AS recurring_revenue
FROM analytics.marts.fct_revenue
WHERE recognized_date >= DATEADD('month', -12, CURRENT_DATE())
GROUP BY 1
ORDER BY 1;


-- METRIC: mrr (Monthly Recurring Revenue)
-- Definition: Sum of recurring revenue recognized in the most recent 
-- complete calendar month, normalized to monthly.
SELECT
    SUM(CASE 
        WHEN is_recurring = TRUE
        AND recognized_date >= DATE_TRUNC('month', CURRENT_DATE()) - INTERVAL '1 month'
        AND recognized_date < DATE_TRUNC('month', CURRENT_DATE())
        THEN amount_usd ELSE 0 
    END) AS mrr
FROM analytics.marts.fct_revenue;


-- METRIC: arr (Annual Recurring Revenue)
-- Definition: MRR × 12. Point-in-time metric reflecting run rate based on
-- the most recent complete month. Used for investor reporting and board metrics.
SELECT
    SUM(CASE 
        WHEN is_recurring = TRUE
        AND recognized_date >= DATE_TRUNC('month', CURRENT_DATE()) - INTERVAL '1 month'
        AND recognized_date < DATE_TRUNC('month', CURRENT_DATE())
        THEN amount_usd ELSE 0 
    END) * 12 AS arr
FROM analytics.marts.fct_revenue;


-- METRIC: services_revenue
-- Definition: Revenue from professional services engagements.
-- Recognized on percentage-of-completion basis.
SELECT
    DATE_TRUNC('month', recognized_date) AS period_month,
    SUM(CASE WHEN revenue_type = 'professional_services' 
             THEN amount_usd ELSE 0 END) AS services_revenue
FROM analytics.marts.fct_revenue
WHERE recognized_date >= DATEADD('month', -12, CURRENT_DATE())
GROUP BY 1
ORDER BY 1;


-- METRIC: customer_count
-- Definition: Count of distinct customers with recognized revenue in period.
-- A customer with $0 revenue in a period is NOT counted.
SELECT
    DATE_TRUNC('month', recognized_date) AS period_month,
    COUNT(DISTINCT customer_id) AS customer_count
FROM analytics.marts.fct_revenue
WHERE recognized_date >= DATEADD('month', -12, CURRENT_DATE())
GROUP BY 1
ORDER BY 1;


-- METRIC: average_revenue_per_customer
-- Definition: Total revenue / customer count. Also known as ARPC.
SELECT
    DATE_TRUNC('month', recognized_date) AS period_month,
    SUM(amount_usd) / NULLIF(COUNT(DISTINCT customer_id), 0) AS arpc
FROM analytics.marts.fct_revenue
WHERE recognized_date >= DATEADD('month', -12, CURRENT_DATE())
GROUP BY 1
ORDER BY 1;


-- ============================================================================
-- 4. HANDLING SEMANTIC CONFLICTS: WHEN DEFINITIONS DISAGREE
-- ============================================================================
--
-- The "Active Customer" Problem:
-- ┌──────────────────┬──────────────────────────────────────────────────────┐
-- │ Team             │ Definition                                           │
-- ├──────────────────┼──────────────────────────────────────────────────────┤
-- │ Product          │ Logged in within last 30 days                        │
-- │ Sales            │ Has an active contract (not churned)                 │
-- │ Finance          │ Generated revenue in current fiscal quarter          │
-- │ Customer Success │ Health score > 40 AND last engagement < 60 days      │
-- └──────────────────┴──────────────────────────────────────────────────────┘
--
-- All four are valid for their contexts. The right approach:
-- NAMED VARIANTS WITH A CANONICAL DEFAULT.
-- ============================================================================

-- CANONICAL: active_customers (used for investor reporting / board metrics)
-- Customers with login in 30 days AND active contract AND non-internal
SELECT
    COUNT(DISTINCT CASE
        WHEN DATEDIFF('day', last_login_date, CURRENT_DATE()) <= 30
        AND contract_status = 'active'
        AND account_type != 'internal'
        THEN customer_id
    END) AS active_customers_canonical
FROM analytics.marts.dim_customer;


-- VARIANT: active_customers_product
-- Platform login in trailing 30 days. Includes trial users.
-- Use for: product engagement analysis, feature adoption
SELECT
    COUNT(DISTINCT CASE
        WHEN DATEDIFF('day', last_login_date, CURRENT_DATE()) <= 30
        THEN customer_id
    END) AS active_customers_product
FROM analytics.marts.dim_customer;


-- VARIANT: active_customers_finance
-- Customers with recognized revenue in current fiscal quarter.
-- Use for: revenue-per-customer, unit economics
SELECT
    COUNT(DISTINCT customer_id) AS active_customers_finance
FROM analytics.marts.fct_revenue
WHERE recognized_date >= DATE_TRUNC('quarter', CURRENT_DATE());


-- ============================================================================
-- AI RESOLUTION LOGIC:
-- When user asks "How many active customers?" the agent:
--   1. Checks user context (Finance meeting → finance variant)
--   2. If ambiguous → uses canonical definition
--   3. If still unclear → asks: "Which definition?"
--   4. ALWAYS discloses which variant was used in the response
-- ============================================================================


-- ============================================================================
-- 5. SEMANTIC VIEW PATTERNS FOR COMPLEX METRICS
-- ============================================================================

-- PATTERN: Period-Over-Period Comparisons
-- ──────────────────────────────────────
-- "How does this quarter compare to last quarter?"

-- Revenue quarter-over-quarter growth
WITH quarterly_revenue AS (
    SELECT
        DATE_TRUNC('quarter', recognized_date) AS fiscal_quarter,
        SUM(amount_usd) AS quarterly_revenue
    FROM analytics.marts.fct_revenue
    WHERE recognized_date >= DATEADD('quarter', -8, CURRENT_DATE())
    GROUP BY 1
)
SELECT
    fiscal_quarter,
    quarterly_revenue,
    LAG(quarterly_revenue) OVER (ORDER BY fiscal_quarter) AS prior_quarter_revenue,
    ROUND(
        (quarterly_revenue - LAG(quarterly_revenue) OVER (ORDER BY fiscal_quarter))
        / NULLIF(LAG(quarterly_revenue) OVER (ORDER BY fiscal_quarter), 0) * 100, 
    2) AS qoq_growth_pct
FROM quarterly_revenue
ORDER BY fiscal_quarter;


-- PATTERN: Cohort-Based Metrics (Net Revenue Retention)
-- ─────────────────────────────────────────────────────
-- NRR tracks dollar retention from a cohort of customers over 12 months.
-- Target: >110% Enterprise, >100% Mid-Market, >95% SMB.

WITH customer_cohort AS (
    -- Identify customers that existed 12 months ago and their revenue
    SELECT
        r.customer_id,
        c.segment,
        SUM(CASE 
            WHEN r.recognized_date >= DATEADD('month', -13, DATE_TRUNC('month', CURRENT_DATE()))
            AND r.recognized_date < DATEADD('month', -12, DATE_TRUNC('month', CURRENT_DATE()))
            THEN r.amount_usd ELSE 0 
        END) AS revenue_12_months_ago,
        SUM(CASE 
            WHEN r.recognized_date >= DATEADD('month', -1, DATE_TRUNC('month', CURRENT_DATE()))
            AND r.recognized_date < DATE_TRUNC('month', CURRENT_DATE())
            THEN r.amount_usd ELSE 0 
        END) AS revenue_current_month
    FROM analytics.marts.fct_revenue r
    JOIN analytics.marts.dim_customer c ON r.customer_id = c.customer_id
    WHERE r.is_recurring = TRUE
    GROUP BY 1, 2
    HAVING revenue_12_months_ago > 0  -- Only include customers in the cohort
)
SELECT
    segment,
    SUM(revenue_current_month) AS current_revenue_from_cohort,
    SUM(revenue_12_months_ago) AS original_cohort_revenue,
    ROUND(SUM(revenue_current_month) / NULLIF(SUM(revenue_12_months_ago), 0) * 100, 1) AS nrr_pct
FROM customer_cohort
GROUP BY 1
ORDER BY 1;


-- PATTERN: Threshold-Based Metrics (At-Risk Customers)
-- ────────────────────────────────────────────────────
-- Health score < 40 = at risk. Components:
--   Usage trend (30%), Support tickets (20%), NPS (20%), Contract timeline (30%)

SELECT
    CASE
        WHEN health_score < 20 THEN 'Critical'
        WHEN health_score >= 20 AND health_score < 40 THEN 'At Risk'
        WHEN health_score >= 40 AND health_score < 70 THEN 'Healthy'
        WHEN health_score >= 70 THEN 'Thriving'
    END AS health_tier,
    COUNT(DISTINCT customer_id) AS customer_count,
    ROUND(COUNT(DISTINCT customer_id) * 100.0 / SUM(COUNT(DISTINCT customer_id)) OVER (), 1) AS pct_of_total
FROM analytics.marts.dim_customer
WHERE contract_status = 'active'
GROUP BY 1
ORDER BY MIN(health_score);


-- ============================================================================
-- 6. CROSS-DOMAIN SEMANTIC RELATIONSHIPS
-- ============================================================================
--
-- Real business questions rarely stay within one domain.
-- "What's the revenue impact of our at-risk customers?" spans Finance + CS.
--
-- Resolution path:
--   1. 'arr' → resolves to finance_revenue semantic view
--   2. 'health_score' → resolves to customer_health semantic view
--   3. Join path: both share dim_customer.customer_id
--   4. Generated query combines both domains through shared dimension
-- ============================================================================

-- Cross-domain query: ARR at risk from unhealthy customers
SELECT
    CASE
        WHEN c.health_score < 20 THEN 'Critical'
        WHEN c.health_score >= 20 AND c.health_score < 40 THEN 'At Risk'
        WHEN c.health_score >= 40 AND c.health_score < 70 THEN 'Healthy'
        ELSE 'Thriving'
    END AS health_tier,
    COUNT(DISTINCT r.customer_id) AS customer_count,
    SUM(CASE 
        WHEN r.is_recurring 
        AND r.recognized_date >= DATE_TRUNC('month', CURRENT_DATE()) - INTERVAL '1 month'
        AND r.recognized_date < DATE_TRUNC('month', CURRENT_DATE())
        THEN r.amount_usd ELSE 0 
    END) * 12 AS arr_by_health_tier
FROM analytics.marts.fct_revenue r
JOIN analytics.marts.dim_customer c ON r.customer_id = c.customer_id
WHERE c.contract_status = 'active'
GROUP BY 1
ORDER BY MIN(c.health_score);


-- ============================================================================
-- 7. SEMANTIC VIEW VERSIONING STRATEGY
-- ============================================================================
--
-- Apply semantic versioning (MAJOR.MINOR.PATCH):
--
-- ┌─────────────────────────────┬──────────────┬───────────────────────────────────┐
-- │ Change Type                 │ Version Bump │ Example                           │
-- ├─────────────────────────────┼──────────────┼───────────────────────────────────┤
-- │ New metric added            │ MINOR        │ Adding expansion_revenue          │
-- │ Description clarified       │ PATCH        │ Fixing typo in description        │
-- │ Metric definition changed   │ MAJOR        │ Changing churn window 90→60 days  │
-- │ Metric deprecated           │ MAJOR        │ Removing legacy_arr               │
-- │ New filter added            │ MINOR        │ Adding acquisition_channel filter  │
-- │ Relationship modified       │ MAJOR        │ Changing join type inner→left      │
-- └─────────────────────────────┴──────────────┴───────────────────────────────────┘
--
-- DEPRECATION WORKFLOW:
-- 1. Mark metric as deprecated with reason and replacement
-- 2. 30-day warning period (AI agents show deprecation notice)
-- 3. Remove in next MAJOR version after sunset period
-- ============================================================================

-- Find all consumers of a metric before making changes
SELECT
    consumer_type,
    consumer_name,
    last_query_date,
    query_count_30d
FROM governance.monitoring.semantic_view_consumers
WHERE semantic_view_name = 'finance_revenue'
    AND metric_name = 'gross_revenue'
    AND last_query_date >= DATEADD('day', -90, CURRENT_DATE())
ORDER BY query_count_30d DESC;


-- ============================================================================
-- 8. TESTING SEMANTIC VIEWS
-- ============================================================================

-- UNIT TEST: ARR matches Finance system of record
WITH semantic_arr AS (
    SELECT
        SUM(CASE WHEN is_recurring = TRUE
                 AND recognized_date >= DATE_TRUNC('month', CURRENT_DATE()) - INTERVAL '1 month'
                 AND recognized_date < DATE_TRUNC('month', CURRENT_DATE())
                 THEN amount_usd ELSE 0 END) * 12 AS arr_value
    FROM analytics.marts.fct_revenue
),
finance_reported AS (
    SELECT arr_reported
    FROM finance.reporting.monthly_metrics
    WHERE metric_month = DATE_TRUNC('month', CURRENT_DATE()) - INTERVAL '1 month'
)
SELECT
    s.arr_value AS semantic_arr,
    f.arr_reported AS finance_arr,
    ABS(s.arr_value - f.arr_reported) AS variance,
    CASE
        WHEN ABS(s.arr_value - f.arr_reported) <= 1.00 THEN 'PASS'
        ELSE 'FAIL: Investigate variance'
    END AS validation_result
FROM semantic_arr s
CROSS JOIN finance_reported f;


-- INTEGRATION TEST: No orphan records in declared relationships
SELECT
    'revenue → customer' AS relationship,
    COUNT(*) AS orphan_count,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' 
         ELSE 'FAIL: ' || COUNT(*) || ' orphans found' 
    END AS test_result
FROM analytics.marts.fct_revenue r
LEFT JOIN analytics.marts.dim_customer c ON r.customer_id = c.customer_id
WHERE c.customer_id IS NULL
    AND r.recognized_date >= DATEADD('year', -1, CURRENT_DATE())

UNION ALL

SELECT
    'revenue → product',
    COUNT(*),
    CASE WHEN COUNT(*) = 0 THEN 'PASS' 
         ELSE 'FAIL: ' || COUNT(*) || ' orphans found' 
    END
FROM analytics.marts.fct_revenue r
LEFT JOIN analytics.marts.dim_product p ON r.product_id = p.product_id
WHERE p.product_id IS NULL
    AND r.recognized_date >= DATEADD('year', -1, CURRENT_DATE());


-- REGRESSION TEST: Metrics haven't drifted from certified snapshot
WITH current_values AS (
    SELECT
        DATE_TRUNC('month', recognized_date) AS month,
        SUM(amount_usd) AS total_revenue,
        SUM(CASE WHEN is_recurring THEN amount_usd ELSE 0 END) AS recurring_revenue
    FROM analytics.marts.fct_revenue
    WHERE recognized_date >= '2025-01-01'
        AND recognized_date < '2025-07-01'
    GROUP BY 1
),
certified_snapshot AS (
    SELECT month, total_revenue, recurring_revenue
    FROM governance.testing.metric_snapshots
    WHERE semantic_view = 'finance_revenue'
        AND snapshot_date = (
            SELECT MAX(snapshot_date)
            FROM governance.testing.metric_snapshots
            WHERE semantic_view = 'finance_revenue'
        )
)
SELECT
    c.month,
    CASE
        WHEN ABS(c.total_revenue - s.total_revenue) > 0.01
        THEN 'FAIL: total_revenue drifted'
        ELSE 'PASS'
    END AS total_revenue_check,
    CASE
        WHEN ABS(c.recurring_revenue - s.recurring_revenue) > 0.01
        THEN 'FAIL: recurring_revenue drifted'
        ELSE 'PASS'
    END AS recurring_revenue_check
FROM current_values c
JOIN certified_snapshot s ON c.month = s.month
ORDER BY c.month;


-- ============================================================================
-- 9. MIGRATING EXISTING DEFINITIONS INTO SEMANTIC VIEWS
-- ============================================================================
--
-- MIGRATION PRIORITY:
-- Migrate first → High query frequency + High inconsistency risk
--   Revenue, ARR, Churn Rate, Active Users
-- Migrate second → High inconsistency risk, moderate frequency
--   COGS, Gross Margin, NRR
-- Migrate third → High frequency, low risk
--   Page Views, API Calls
-- Migrate last → Low frequency, low risk
--   Storage Used, Internal Metrics
--
-- FROM TABLEAU CALCULATED FIELDS:
-- ────────────────────────────────
-- Before (Tableau):
--   IF DATEDIFF('day', [Last Login Date], TODAY()) <= 30
--   AND [Contract Status] = "Active"
--   AND [Account Type] <> "Internal"
--   THEN "Active" ELSE "Inactive" END
--
-- After (Semantic View metric expression):
--   COUNT(DISTINCT CASE
--     WHEN DATEDIFF('day', last_login_date, CURRENT_DATE()) <= 30
--     AND contract_status = 'active'
--     AND account_type != 'internal'
--     THEN customer_id END)
--
-- FROM dbt METRICS:
-- ─────────────────
-- Before (dbt YAML):
--   calculation_method: count_distinct
--   expression: user_id
--   filters: activity_type != 'bot'
--
-- After (Semantic View metric):
--   COUNT(DISTINCT CASE WHEN activity_type != 'bot' THEN user_id END)
--
-- FROM POWER BI DAX:
-- ──────────────────
-- Before (DAX):
--   CALCULATE(SUM(Revenue[Amount]),
--     Revenue[Type] IN {"Subscription","Usage"},
--     Revenue[Status] = "Recognized")
--   - CALCULATE(SUM(Credits[Amount]), Credits[Type] = "Refund")
--
-- After (Semantic View):
--   SUM(CASE WHEN revenue_type IN ('subscription','usage')
--            AND recognition_status = 'recognized'
--            THEN amount_usd ELSE 0 END)
--   - SUM(CASE WHEN credit_type = 'refund' THEN credit_amount_usd ELSE 0 END)
-- ============================================================================


-- ============================================================================
-- 10. PERFORMANCE CONSIDERATIONS
-- ============================================================================
--
-- MATERIALIZATION TIERS:
-- ┌─────────────────┬────────────┬──────────────────────────────┬─────────────────────────┐
-- │ Tier            │ Freshness  │ Implementation               │ Examples                │
-- ├─────────────────┼────────────┼──────────────────────────────┼─────────────────────────┤
-- │ Real-time       │ Sub-second │ Live query over base tables  │ Active users, pipeline  │
-- │ Near-real-time  │ < 1 hour   │ Dynamic table, 1hr lag       │ Today's revenue         │
-- │ Daily           │ End of day │ Dynamic table, daily refresh │ ARR, churn rate, NRR    │
-- │ Periodic        │ Weekly+    │ Materialized aggregates      │ LTV, payback, cohorts   │
-- └─────────────────┴────────────┴──────────────────────────────┴─────────────────────────┘
-- ============================================================================

-- Dynamic table for daily-refresh revenue metrics
CREATE OR REPLACE DYNAMIC TABLE analytics.semantic.daily_revenue_metrics
    TARGET_LAG = '1 day'
    WAREHOUSE = compute_wh
AS
SELECT
    DATE_TRUNC('month', r.recognized_date) AS metric_month,
    c.segment,
    c.region,
    SUM(r.amount_usd) AS total_revenue,
    SUM(CASE WHEN r.is_recurring THEN r.amount_usd ELSE 0 END) AS recurring_revenue,
    COUNT(DISTINCT r.customer_id) AS customer_count
FROM analytics.marts.fct_revenue r
JOIN analytics.marts.dim_customer c ON r.customer_id = c.customer_id
WHERE r.recognized_date >= DATEADD('month', -24, CURRENT_DATE())
GROUP BY 1, 2, 3;


-- Optimize underlying tables for common access patterns
ALTER TABLE analytics.marts.fct_revenue
    CLUSTER BY (recognized_date, customer_id);

-- Search optimization for equality predicates used by AI agents
ALTER TABLE analytics.marts.dim_customer
    ADD SEARCH OPTIMIZATION ON EQUALITY(segment, region, industry);


-- ============================================================================
-- 11. THE CERTIFICATION LIFECYCLE
-- ============================================================================
--
-- STATES:
--   [Draft] → Submit → [In Review] → Approve → [Certified]
--                          ↑                        │
--                          └── Scheduled Review ────┘
--                                                   │
--   [Certified] → Replace → [Deprecated] → Sunset → [Removed]
--
-- CERTIFICATION CRITERIA:
--   1. Business definition is clear (non-technical stakeholder understands)
--   2. Technical implementation validated (matches source-of-record)
--   3. Owner is assigned (named person/team)
--   4. Tests pass (unit, integration, regression)
--   5. Consumers identified (dashboards, agents, applications)
--   6. Review schedule set (next review within 90 days)
-- ============================================================================

-- Create certification tracking infrastructure
CREATE TABLE IF NOT EXISTS governance.semantic.metric_certifications (
    metric_name VARCHAR NOT NULL,
    semantic_view VARCHAR NOT NULL,
    domain VARCHAR NOT NULL,
    business_definition TEXT,
    certified_by VARCHAR,
    certification_date TIMESTAMP_NTZ,
    next_review_date DATE,
    status VARCHAR DEFAULT 'draft',
    deprecation_reason TEXT,
    replacement_metric VARCHAR,
    CONSTRAINT pk_certifications PRIMARY KEY (metric_name, semantic_view)
);

-- Create audit trail for certification events
CREATE TABLE IF NOT EXISTS governance.semantic.certification_audit (
    audit_id VARCHAR DEFAULT UUID_STRING(),
    metric_name VARCHAR NOT NULL,
    semantic_view VARCHAR NOT NULL,
    action VARCHAR NOT NULL,
    performed_by VARCHAR NOT NULL,
    action_date TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    previous_definition TEXT,
    new_definition TEXT,
    reason TEXT
);

-- Record a certification event
INSERT INTO governance.semantic.certification_audit
    (metric_name, semantic_view, action, performed_by, reason)
VALUES
    ('total_revenue', 'finance_revenue', 'certified',
     'jane.smith@company.com',
     'Q4 review complete. Validated against GL. Variance < $1.');

-- Query certification health dashboard
SELECT
    semantic_view,
    metric_name,
    status,
    certified_by,
    certification_date,
    next_review_date,
    CASE
        WHEN next_review_date < CURRENT_DATE() THEN 'OVERDUE'
        WHEN next_review_date < DATEADD('day', 14, CURRENT_DATE()) THEN 'DUE SOON'
        ELSE 'CURRENT'
    END AS review_urgency
FROM governance.semantic.metric_certifications
WHERE status = 'certified'
ORDER BY next_review_date ASC;


-- ============================================================================
-- 12. SEMANTIC LAYER HEALTH SCORECARD
-- ============================================================================

-- Overall semantic layer health
SELECT
    'Certified Metrics' AS kpi,
    COUNT(CASE WHEN status = 'certified' THEN 1 END) AS certified_count,
    COUNT(*) AS total_count,
    ROUND(COUNT(CASE WHEN status = 'certified' THEN 1 END) * 100.0 
        / NULLIF(COUNT(*), 0), 1) AS pct
FROM governance.semantic.metric_certifications

UNION ALL

SELECT
    'Reviews Current',
    COUNT(CASE WHEN next_review_date >= CURRENT_DATE() AND status = 'certified' THEN 1 END),
    COUNT(CASE WHEN status = 'certified' THEN 1 END),
    ROUND(COUNT(CASE WHEN next_review_date >= CURRENT_DATE() AND status = 'certified' THEN 1 END) * 100.0
        / NULLIF(COUNT(CASE WHEN status = 'certified' THEN 1 END), 0), 1)
FROM governance.semantic.metric_certifications

UNION ALL

SELECT
    'Deprecated (Pending Removal)',
    COUNT(CASE WHEN status = 'deprecated' THEN 1 END),
    COUNT(*),
    ROUND(COUNT(CASE WHEN status = 'deprecated' THEN 1 END) * 100.0
        / NULLIF(COUNT(*), 0), 1)
FROM governance.semantic.metric_certifications;


-- ============================================================================
-- 13. BUILDING A CORTEX AGENT ON THE SEMANTIC LAYER
-- ============================================================================

-- Create a Finance domain AI agent grounded in certified semantic views
CREATE OR REPLACE CORTEX AGENT analytics.agents.finance_agent
    COMMENT = 'Finance AI assistant grounded in certified semantic views'
    SEMANTIC_VIEWS = (
        analytics.semantic.finance_revenue,
        analytics.semantic.finance_costs
    )
    TOOLS = (ANALYST)
    INSTRUCTIONS = '
        You are a Finance AI assistant. Rules:
        1. ONLY use certified metrics from the provided semantic views.
        2. Always state which metric definition you used.
        3. If ambiguous (e.g. "revenue" without qualifier), use total_revenue 
           and disclose this choice.
        4. Include data freshness timestamp in every answer.
        5. NEVER compute metrics not defined in semantic views.
        6. If asked about predictions/forecasts, decline and refer to FP&A.
        7. For questions about individual compensation, decline.
    ';


-- ============================================================================
-- 14. THE THREE LAWS OF A TRUSTED SEMANTIC LAYER
-- ============================================================================
--
-- LAW 1: If it's not in a semantic view, it doesn't exist for AI.
-- ─────────────────────────────────────────────────────────────────
-- AI agents should never derive metric calculations from raw table inspection.
-- If a metric isn't formally defined, the agent says "I don't have a certified 
-- definition for that" rather than improvising.
--
-- LAW 2: Ownership without accountability is documentation.
-- ─────────────────────────────────────────────────────────
-- Every metric needs not just an owner in YAML, but a certification cadence,
-- a review process, and consequences for drift. An uncertified metric is worse 
-- than no metric — it creates false confidence.
--
-- LAW 3: The semantic layer is alive or it's dead.
-- ─────────────────────────────────────────────────
-- A semantic layer built once and never updated diverges from reality within 
-- one quarter. Build operational processes (CI/CD, testing, certification 
-- reviews, drift detection) from day one.
--
-- ============================================================================
-- NEXT: Part 3 — Activating AI Agents on the Semantic Layer
-- Cortex Agents, prompt engineering, confidence calibration,
-- multi-domain resolution, and human-in-the-loop escalation.
-- ============================================================================
