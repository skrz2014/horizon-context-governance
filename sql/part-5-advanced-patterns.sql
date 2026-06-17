-- Part 5 Advanced Patterns: Multi-tenant isolation, real-time metrics, semantic layer API, and cross-cloud federation
-- Co-authored with CoCo
-- ============================================================================
-- PART 5: ADVANCED PATTERNS
-- Multi-Tenant Semantic Layers, Real-Time Metrics, Semantic Layer as API,
-- and Cross-Cloud Federation
-- ============================================================================
--
-- Prerequisites: Parts 2-4B deployed (governance database, metric_catalog, etc.)
--
-- This file creates:
--   Pattern 1: Multi-tenant infrastructure + row access policies
--   Pattern 2: Real-time metrics with Dynamic Tables + freshness tiers
--   Pattern 3: Semantic Layer API (rate limits, request logging, query procedure)
--   Pattern 4: Cross-cloud federation (glossary versioning, spoke resolution)
--   Test Suite: End-to-end validation of all 4 patterns
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;


-- ============================================================================
-- PATTERN 1: MULTI-TENANT SEMANTIC LAYER
-- ============================================================================
-- Shared metric definitions, completely isolated data per tenant.
-- One semantic view per domain (not per customer).
-- Row access policies enforce tenant boundaries.
-- ============================================================================

CREATE DATABASE IF NOT EXISTS multi_tenant;
CREATE SCHEMA IF NOT EXISTS multi_tenant.semantic;
CREATE SCHEMA IF NOT EXISTS multi_tenant.policies;
CREATE SCHEMA IF NOT EXISTS multi_tenant.tenant_mgmt;
CREATE SCHEMA IF NOT EXISTS multi_tenant.streaming;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1A. Tenant Registry
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE TABLE multi_tenant.tenant_mgmt.tenants (
    tenant_id VARCHAR NOT NULL PRIMARY KEY,
    tenant_name VARCHAR NOT NULL,
    tier VARCHAR NOT NULL,              -- free, starter, professional, enterprise
    data_region VARCHAR NOT NULL,       -- us-west-2, eu-west-1, ap-southeast-1
    metrics_enabled ARRAY,             -- Which metrics this tenant can access
    max_query_concurrency INTEGER DEFAULT 10,
    semantic_views_accessible ARRAY,   -- Which views this tenant can query
    created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    is_active BOOLEAN DEFAULT TRUE
);

CREATE OR REPLACE TABLE multi_tenant.tenant_mgmt.tenant_users (
    user_email VARCHAR NOT NULL,
    tenant_id VARCHAR NOT NULL,
    role_within_tenant VARCHAR NOT NULL,  -- admin, analyst, viewer
    granted_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE multi_tenant.tenant_mgmt.tier_metrics (
    tier VARCHAR NOT NULL,
    metric_name VARCHAR NOT NULL,
    is_included BOOLEAN DEFAULT TRUE
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 1B. Multi-Tenant Fact Tables
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE TABLE multi_tenant.semantic.fct_revenue (
    transaction_id VARCHAR DEFAULT UUID_STRING(),
    tenant_id VARCHAR NOT NULL,
    revenue_date DATE NOT NULL,
    product_line VARCHAR,
    region VARCHAR,
    amount_usd NUMBER(12,2),
    customer_id VARCHAR
);

CREATE OR REPLACE TABLE multi_tenant.semantic.fct_usage (
    event_id VARCHAR DEFAULT UUID_STRING(),
    tenant_id VARCHAR NOT NULL,
    event_date DATE NOT NULL,
    user_id VARCHAR,
    feature_name VARCHAR,
    session_duration_seconds INTEGER,
    page_views INTEGER
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 1C. Row Access Policy for Tenant Isolation
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE ROW ACCESS POLICY multi_tenant.policies.tenant_isolation_policy
AS (tenant_id_col VARCHAR) RETURNS BOOLEAN ->
    -- ACCOUNTADMIN and platform roles bypass (for admin/debugging)
    CURRENT_ROLE() IN ('ACCOUNTADMIN', 'SEMANTIC_PLATFORM_ADMIN')
    OR
    -- Tenant users see only their tenant's rows
    EXISTS (
        SELECT 1 FROM multi_tenant.tenant_mgmt.tenant_users tu
        WHERE tu.user_email = CURRENT_USER()
          AND tu.tenant_id = tenant_id_col
    );

-- Apply row access policy to fact tables
ALTER TABLE multi_tenant.semantic.fct_revenue
    ADD ROW ACCESS POLICY multi_tenant.policies.tenant_isolation_policy ON (tenant_id);

ALTER TABLE multi_tenant.semantic.fct_usage
    ADD ROW ACCESS POLICY multi_tenant.policies.tenant_isolation_policy ON (tenant_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- 1D. Tier-Based Metric Access Function
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION multi_tenant.policies.can_access_metric(p_metric_name VARCHAR)
RETURNS BOOLEAN
AS
$$
    SELECT EXISTS (
        SELECT 1 FROM multi_tenant.tenant_mgmt.tenants t
        INNER JOIN multi_tenant.tenant_mgmt.tenant_users tu
            ON t.tenant_id = tu.tenant_id
        WHERE tu.user_email = CURRENT_USER()
          AND t.is_active = TRUE
          AND (ARRAY_CONTAINS(p_metric_name::VARIANT, t.metrics_enabled)
               OR ARRAY_CONTAINS('*'::VARIANT, t.metrics_enabled))
    )
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1E. Seed Tenant Data
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO multi_tenant.tenant_mgmt.tenants
    (tenant_id, tenant_name, tier, data_region, metrics_enabled, semantic_views_accessible)
SELECT 'TNT-001', 'Acme Corp', 'enterprise', 'us-west-2',
    ARRAY_CONSTRUCT('*'), ARRAY_CONSTRUCT('*')
UNION ALL SELECT 'TNT-002', 'Globex Industries', 'professional', 'us-west-2',
    ARRAY_CONSTRUCT('active_users', 'total_sessions', 'feature_adoption_rate', 'session_duration_p50', 'churn_risk_score', 'net_dollar_retention'),
    ARRAY_CONSTRUCT('product_usage', 'cs_health')
UNION ALL SELECT 'TNT-003', 'Initech', 'free', 'eu-west-1',
    ARRAY_CONSTRUCT('active_users', 'total_sessions'),
    ARRAY_CONSTRUCT('product_usage');

-- Map users to tenants (replace SATISH with your username)
INSERT INTO multi_tenant.tenant_mgmt.tenant_users (user_email, tenant_id, role_within_tenant)
SELECT CURRENT_USER(), 'TNT-001', 'admin'
UNION ALL SELECT 'analyst@acme.com', 'TNT-001', 'analyst'
UNION ALL SELECT 'manager@globex.com', 'TNT-002', 'admin'
UNION ALL SELECT 'viewer@globex.com', 'TNT-002', 'viewer'
UNION ALL SELECT 'user@initech.com', 'TNT-003', 'admin';

-- Tier-to-metric mapping
INSERT INTO multi_tenant.tenant_mgmt.tier_metrics (tier, metric_name)
SELECT 'free', 'active_users'
UNION ALL SELECT 'free', 'total_sessions'
UNION ALL SELECT 'starter', 'active_users'
UNION ALL SELECT 'starter', 'total_sessions'
UNION ALL SELECT 'starter', 'feature_adoption_rate'
UNION ALL SELECT 'starter', 'session_duration_p50'
UNION ALL SELECT 'professional', 'active_users'
UNION ALL SELECT 'professional', 'total_sessions'
UNION ALL SELECT 'professional', 'feature_adoption_rate'
UNION ALL SELECT 'professional', 'session_duration_p50'
UNION ALL SELECT 'professional', 'churn_risk_score'
UNION ALL SELECT 'professional', 'net_dollar_retention'
UNION ALL SELECT 'enterprise', '*';

-- Seed revenue data across all 3 tenants
INSERT INTO multi_tenant.semantic.fct_revenue
    (tenant_id, revenue_date, product_line, region, amount_usd, customer_id)
-- Acme Corp (enterprise) - 200 rows
SELECT 'TNT-001', DATEADD('day', -SEQ8(), CURRENT_DATE()),
    CASE MOD(SEQ8(), 3) WHEN 0 THEN 'Platform' WHEN 1 THEN 'Analytics' ELSE 'Support' END,
    CASE MOD(SEQ8(), 4) WHEN 0 THEN 'AMER' WHEN 1 THEN 'EMEA' WHEN 2 THEN 'APAC' ELSE 'LATAM' END,
    UNIFORM(5000, 50000, RANDOM()),
    'CUST-' || LPAD(MOD(SEQ8(), 50)::VARCHAR, 4, '0')
FROM TABLE(GENERATOR(ROWCOUNT => 200))
UNION ALL
-- Globex (professional) - 100 rows
SELECT 'TNT-002', DATEADD('day', -SEQ8(), CURRENT_DATE()),
    CASE MOD(SEQ8(), 2) WHEN 0 THEN 'Platform' ELSE 'Analytics' END,
    CASE MOD(SEQ8(), 2) WHEN 0 THEN 'AMER' ELSE 'EMEA' END,
    UNIFORM(1000, 15000, RANDOM()),
    'CUST-' || LPAD(MOD(SEQ8(), 20)::VARCHAR, 4, '0')
FROM TABLE(GENERATOR(ROWCOUNT => 100))
UNION ALL
-- Initech (free) - 30 rows
SELECT 'TNT-003', DATEADD('day', -SEQ8(), CURRENT_DATE()),
    'Platform', 'EMEA',
    UNIFORM(500, 3000, RANDOM()),
    'CUST-' || LPAD(MOD(SEQ8(), 5)::VARCHAR, 4, '0')
FROM TABLE(GENERATOR(ROWCOUNT => 30));


-- ============================================================================
-- PATTERN 2: REAL-TIME METRICS
-- ============================================================================
-- Tiered freshness SLAs with Dynamic Tables for streaming use cases.
-- Not every metric needs real-time — tier appropriately.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 2A. Freshness Tier Definitions
-- ─────────────────────────────────────────────────────────────────────────────

USE DATABASE governance;

CREATE OR REPLACE TABLE governance.operating_model.freshness_tiers (
    tier_name VARCHAR NOT NULL PRIMARY KEY,
    max_latency_seconds INTEGER NOT NULL,
    source_pattern VARCHAR NOT NULL,
    cost_multiplier NUMBER(3,1) NOT NULL,
    use_case_examples TEXT
);

INSERT INTO governance.operating_model.freshness_tiers
    (tier_name, max_latency_seconds, source_pattern, cost_multiplier, use_case_examples)
SELECT 'batch', 14400, 'scheduled ETL (4h)', 1.0, 'Revenue recognition, monthly reporting, historical analysis'
UNION ALL SELECT 'near_real_time', 900, 'micro-batch (15 min)', 2.5, 'Pipeline monitoring, hourly dashboards, SLA tracking'
UNION ALL SELECT 'streaming', 30, 'Snowpipe Streaming + Dynamic Tables', 5.0, 'Ops monitoring, live dashboards, alerting'
UNION ALL SELECT 'real_time', 5, 'Materialized View on stream', 10.0, 'Fraud detection, live pricing, capacity management';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2B. Streaming Source Table (simulates Snowpipe Streaming ingest)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE TABLE multi_tenant.streaming.page_events (
    event_id VARCHAR DEFAULT UUID_STRING(),
    tenant_id VARCHAR NOT NULL,
    user_id VARCHAR NOT NULL,
    page_name VARCHAR NOT NULL,
    load_time_ms INTEGER NOT NULL,
    event_timestamp TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Seed 1000 recent events (simulating last hour of streaming data)
INSERT INTO multi_tenant.streaming.page_events
    (tenant_id, user_id, page_name, load_time_ms, event_timestamp)
SELECT
    CASE MOD(SEQ8(), 3) WHEN 0 THEN 'TNT-001' WHEN 1 THEN 'TNT-002' ELSE 'TNT-003' END,
    'USER-' || LPAD(MOD(SEQ8(), 100)::VARCHAR, 4, '0'),
    CASE MOD(SEQ8(), 5) WHEN 0 THEN '/dashboard' WHEN 1 THEN '/reports' WHEN 2 THEN '/settings' WHEN 3 THEN '/api-docs' ELSE '/home' END,
    UNIFORM(100, 5000, RANDOM()),
    DATEADD('second', -UNIFORM(0, 3600, RANDOM()), CURRENT_TIMESTAMP())
FROM TABLE(GENERATOR(ROWCOUNT => 1000));

-- ─────────────────────────────────────────────────────────────────────────────
-- 2C. Dynamic Table (aggregates streaming data with 1-minute lag)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE DYNAMIC TABLE multi_tenant.streaming.page_load_metrics
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
AS
SELECT
    DATE_TRUNC('minute', event_timestamp) AS metric_minute,
    tenant_id,
    page_name,
    COUNT(*) AS page_views,
    AVG(load_time_ms) AS avg_load_time_ms,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY load_time_ms) AS p95_load_time_ms,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY load_time_ms) AS p99_load_time_ms,
    COUNT(CASE WHEN load_time_ms > 3000 THEN 1 END) AS slow_loads
FROM multi_tenant.streaming.page_events
WHERE event_timestamp >= DATEADD('hour', -24, CURRENT_TIMESTAMP())
GROUP BY 1, 2, 3;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2D. Freshness-Aware View (adds staleness metadata for agents/consumers)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW multi_tenant.streaming.page_load_with_freshness AS
SELECT
    plm.*,
    DATEDIFF('second', metric_minute, CURRENT_TIMESTAMP()) AS data_age_seconds,
    CASE
        WHEN DATEDIFF('second', metric_minute, CURRENT_TIMESTAMP()) <= 60 THEN 'LIVE'
        WHEN DATEDIFF('second', metric_minute, CURRENT_TIMESTAMP()) <= 300 THEN 'RECENT'
        WHEN DATEDIFF('second', metric_minute, CURRENT_TIMESTAMP()) <= 900 THEN 'DELAYED'
        ELSE 'STALE'
    END AS freshness_status
FROM multi_tenant.streaming.page_load_metrics plm;


-- ============================================================================
-- PATTERN 3: SEMANTIC LAYER AS API
-- ============================================================================
-- Expose governed metrics via a procedure-based API so any system
-- (Tableau, React apps, partner integrations) consumes certified definitions.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 3A. API Infrastructure Tables
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE TABLE multi_tenant.semantic.api_request_log (
    request_id VARCHAR DEFAULT UUID_STRING(),
    endpoint VARCHAR NOT NULL,
    method VARCHAR NOT NULL,
    metric_requested VARCHAR,
    dimensions_requested ARRAY,
    filters_applied VARIANT,
    tenant_id VARCHAR,
    api_key_hash VARCHAR,
    response_status INTEGER,
    response_time_ms INTEGER,
    rows_returned INTEGER,
    served_from VARCHAR,           -- cache, live_query, materialized_view
    data_freshness_seconds INTEGER,
    requested_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE multi_tenant.semantic.api_rate_limits (
    tier VARCHAR NOT NULL,
    max_requests_per_minute INTEGER NOT NULL,
    max_requests_per_hour INTEGER NOT NULL,
    max_concurrent_queries INTEGER NOT NULL,
    max_rows_per_response INTEGER NOT NULL,
    cache_ttl_seconds INTEGER NOT NULL
);

INSERT INTO multi_tenant.semantic.api_rate_limits
    (tier, max_requests_per_minute, max_requests_per_hour, max_concurrent_queries, max_rows_per_response, cache_ttl_seconds)
SELECT 'free', 10, 100, 2, 1000, 300
UNION ALL SELECT 'starter', 30, 500, 5, 10000, 120
UNION ALL SELECT 'professional', 100, 5000, 20, 100000, 60
UNION ALL SELECT 'enterprise', 500, 50000, 100, 1000000, 30;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3B. Metric Query API Procedure
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE PROCEDURE multi_tenant.semantic.query_metric(
    P_METRIC_NAME VARCHAR,
    P_TENANT_ID VARCHAR
)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    v_metric_status VARCHAR;
    v_has_access BOOLEAN;
    v_tier VARCHAR;
    v_rate_limit INTEGER;
BEGIN
    -- Validate metric exists and is certified
    v_metric_status := (
        SELECT certification_status FROM governance.operating_model.metric_catalog
        WHERE metric_name = :P_METRIC_NAME AND certification_status = 'CERTIFIED'
    );
    IF (v_metric_status IS NULL) THEN
        INSERT INTO multi_tenant.semantic.api_request_log
            (endpoint, method, metric_requested, tenant_id, response_status, served_from)
        SELECT '/v1/metrics/' || :P_METRIC_NAME, 'GET', :P_METRIC_NAME, :P_TENANT_ID, 404, 'rejected';
        RETURN OBJECT_CONSTRUCT(
            'error', 'METRIC_NOT_FOUND_OR_NOT_CERTIFIED',
            'message', 'Metric ' || :P_METRIC_NAME || ' is not available. Only certified metrics can be queried via API.',
            'status', 404
        );
    END IF;

    -- Validate tenant access (enterprise = all, others = check metrics_enabled array)
    v_has_access := (
        SELECT EXISTS (
            SELECT 1 FROM multi_tenant.tenant_mgmt.tenants
            WHERE tenant_id = :P_TENANT_ID AND is_active = TRUE
              AND (ARRAY_CONTAINS(:P_METRIC_NAME::VARIANT, metrics_enabled)
                   OR ARRAY_CONTAINS('*'::VARIANT, metrics_enabled))
        )
    );
    IF (NOT v_has_access) THEN
        INSERT INTO multi_tenant.semantic.api_request_log
            (endpoint, method, metric_requested, tenant_id, response_status, served_from)
        SELECT '/v1/metrics/' || :P_METRIC_NAME, 'GET', :P_METRIC_NAME, :P_TENANT_ID, 403, 'rejected';
        RETURN OBJECT_CONSTRUCT(
            'error', 'ACCESS_DENIED',
            'message', 'Your plan does not include access to metric: ' || :P_METRIC_NAME,
            'status', 403,
            'upgrade_url', 'https://yourcompany.com/pricing'
        );
    END IF;

    -- Get tenant tier and rate limit
    v_tier := (SELECT tier FROM multi_tenant.tenant_mgmt.tenants WHERE tenant_id = :P_TENANT_ID);
    v_rate_limit := (SELECT max_requests_per_minute FROM multi_tenant.semantic.api_rate_limits WHERE tier = :v_tier);

    -- Log successful request
    INSERT INTO multi_tenant.semantic.api_request_log
        (endpoint, method, metric_requested, tenant_id, response_status, response_time_ms, served_from)
    SELECT '/v1/metrics/' || :P_METRIC_NAME, 'GET', :P_METRIC_NAME, :P_TENANT_ID, 200, 45, 'live_query';

    RETURN OBJECT_CONSTRUCT(
        'status', 200,
        'metric', :P_METRIC_NAME,
        'tenant_id', :P_TENANT_ID,
        'tier', :v_tier,
        'rate_limit_rpm', :v_rate_limit,
        'certification', 'CERTIFIED',
        'freshness', 'live',
        'note', 'Production implementation returns actual metric data from semantic view.'
    );
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3C. BI Tool Integration Views
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW multi_tenant.semantic.bi_revenue_summary AS
SELECT
    DATE_TRUNC('day', revenue_date) AS date,
    tenant_id,
    product_line,
    region,
    SUM(amount_usd) AS total_revenue,
    COUNT(DISTINCT customer_id) AS customer_count,
    COUNT(*) AS transaction_count,
    'finance_revenue' AS source_semantic_view,
    'CERTIFIED' AS certification_status,
    CURRENT_TIMESTAMP() AS query_timestamp
FROM multi_tenant.semantic.fct_revenue
GROUP BY 1, 2, 3, 4;

-- BI service roles
CREATE ROLE IF NOT EXISTS bi_service_tableau;
CREATE ROLE IF NOT EXISTS bi_service_powerbi;
GRANT USAGE ON DATABASE multi_tenant TO ROLE bi_service_tableau;
GRANT USAGE ON DATABASE multi_tenant TO ROLE bi_service_powerbi;
GRANT USAGE ON SCHEMA multi_tenant.semantic TO ROLE bi_service_tableau;
GRANT USAGE ON SCHEMA multi_tenant.semantic TO ROLE bi_service_powerbi;
GRANT SELECT ON ALL VIEWS IN SCHEMA multi_tenant.semantic TO ROLE bi_service_tableau;
GRANT SELECT ON ALL VIEWS IN SCHEMA multi_tenant.semantic TO ROLE bi_service_powerbi;


-- ============================================================================
-- PATTERN 4: CROSS-CLOUD FEDERATION
-- ============================================================================
-- Hub-and-spoke model: definitions replicate from hub to regional spokes.
-- Data stays local. Aggregates flow back for global reporting.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 4A. Glossary Versioning (hub publishes, spokes consume)
-- ─────────────────────────────────────────────────────────────────────────────

USE DATABASE governance;

CREATE OR REPLACE TABLE governance.operating_model.glossary_versions (
    version_id INTEGER AUTOINCREMENT,
    term VARCHAR NOT NULL,
    canonical_definition TEXT NOT NULL,
    disambiguation_rules TEXT,
    effective_date TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    supersedes_version INTEGER,
    published_by VARCHAR NOT NULL,
    change_reason TEXT
);

INSERT INTO governance.operating_model.glossary_versions
    (term, canonical_definition, disambiguation_rules, published_by, change_reason)
SELECT 'revenue', 'Total recognized revenue per ASC 606. All product lines. USD.',
 'Default ASC 606. "Run rate" -> ARR. "Bookings" -> redirect to Sales.',
 'GOVERNANCE_COUNCIL', 'Initial publication'
UNION ALL SELECT 'active_users', 'Unique users with at least 1 meaningful action per day.',
 'Default to DAU. "Monthly" -> MAU. Exclude bot accounts.',
 'GOVERNANCE_COUNCIL', 'Initial publication'
UNION ALL SELECT 'churn', 'Zero activity 90+ days AND contract not renewed at term end.',
 'Always logo churn unless stated. "At risk" = score > 0.7, not churned yet.',
 'GOVERNANCE_COUNCIL', 'Initial publication';

-- ─────────────────────────────────────────────────────────────────────────────
-- 4B. Spoke Metric Resolution (reads from local replica in production)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE PROCEDURE governance.operating_model.spoke_resolve_metric(P_METRIC_NAME VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    v_metric_def VARIANT;
BEGIN
    -- In production: reads from governance_replica (local replica of hub)
    -- Here we read from hub directly to simulate
    v_metric_def := (
        SELECT OBJECT_CONSTRUCT(
            'metric_name', metric_name,
            'domain', domain,
            'business_definition', business_definition,
            'semantic_view_fqn', semantic_view_fqn,
            'certification_status', certification_status,
            'certification_date', certification_date::VARCHAR,
            'data_quality_score', data_quality_score
        )
        FROM governance.operating_model.metric_catalog
        WHERE metric_name = :P_METRIC_NAME
          AND certification_status = 'CERTIFIED'
    );

    IF (v_metric_def IS NULL) THEN
        RETURN OBJECT_CONSTRUCT(
            'status', 'NOT_FOUND',
            'metric', :P_METRIC_NAME,
            'source', 'hub_direct'
        );
    END IF;

    RETURN OBJECT_CONSTRUCT(
        'status', 'RESOLVED',
        'source', 'hub_direct',
        'replica_lag_seconds', 0,
        'metric', :v_metric_def
    );
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4C. Glossary Sync Validation
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE PROCEDURE governance.operating_model.validate_glossary_sync(
    P_LOCAL_VERSION INTEGER
)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    v_hub_version INTEGER;
BEGIN
    v_hub_version := (SELECT MAX(version_id) FROM governance.operating_model.glossary_versions);

    IF (:v_hub_version > :P_LOCAL_VERSION) THEN
        RETURN OBJECT_CONSTRUCT(
            'status', 'OUT_OF_SYNC',
            'hub_version', :v_hub_version,
            'local_version', :P_LOCAL_VERSION,
            'versions_behind', :v_hub_version - :P_LOCAL_VERSION,
            'action', 'Run glossary sync procedure to update local definitions'
        );
    END IF;

    RETURN OBJECT_CONSTRUCT(
        'status', 'IN_SYNC',
        'version', :v_hub_version
    );
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4D. Federation Health View
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW governance.operating_model.federation_health AS
SELECT
    'HUB' AS node,
    'governance' AS database_name,
    (SELECT COUNT(*) FROM governance.operating_model.metric_catalog WHERE certification_status = 'CERTIFIED') AS certified_metrics,
    (SELECT COUNT(*) FROM governance.operating_model.domain_registry WHERE is_active = TRUE) AS active_domains,
    (SELECT COUNT(*) FROM governance.operating_model.business_glossary) AS glossary_terms,
    (SELECT MAX(version_id) FROM governance.operating_model.glossary_versions) AS glossary_version,
    0 AS replication_lag_seconds,
    'PRIMARY' AS replication_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4E. GDPR-Compliant Cross-Region Aggregate View
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW multi_tenant.semantic.gdpr_safe_aggregates AS
SELECT
    DATE_TRUNC('month', revenue_date) AS period,
    tenant_id,
    region,
    product_line,
    SUM(amount_usd) AS total_revenue,
    COUNT(DISTINCT customer_id) AS customer_count,
    AVG(amount_usd) AS avg_transaction_value,
    'AGGREGATE' AS data_classification,
    'multi_tenant.semantic.fct_revenue' AS source_table
FROM multi_tenant.semantic.fct_revenue
GROUP BY 1, 2, 3, 4
HAVING customer_count >= 5;  -- k-anonymity: min 5 customers per group


-- ============================================================================
-- PATTERN 5: TENANT ISOLATION TEST ROLE
-- ============================================================================
-- Creates a restricted role to prove row access policies work.
-- ============================================================================

CREATE ROLE IF NOT EXISTS test_tenant_user;
GRANT USAGE ON DATABASE multi_tenant TO ROLE test_tenant_user;
GRANT USAGE ON SCHEMA multi_tenant.semantic TO ROLE test_tenant_user;
GRANT USAGE ON SCHEMA multi_tenant.tenant_mgmt TO ROLE test_tenant_user;
GRANT USAGE ON SCHEMA multi_tenant.streaming TO ROLE test_tenant_user;
GRANT SELECT ON ALL TABLES IN SCHEMA multi_tenant.semantic TO ROLE test_tenant_user;
GRANT SELECT ON ALL TABLES IN SCHEMA multi_tenant.tenant_mgmt TO ROLE test_tenant_user;
GRANT SELECT ON ALL TABLES IN SCHEMA multi_tenant.streaming TO ROLE test_tenant_user;
GRANT SELECT ON ALL VIEWS IN SCHEMA multi_tenant.semantic TO ROLE test_tenant_user;
GRANT SELECT ON ALL VIEWS IN SCHEMA multi_tenant.streaming TO ROLE test_tenant_user;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE test_tenant_user;
GRANT ROLE test_tenant_user TO USER SATISH;


-- ============================================================================
-- END-TO-END TEST SUITE
-- ============================================================================
-- Run these queries to validate all 4 patterns are working correctly.
-- ============================================================================

-- ─── TEST 1: Multi-Tenant Isolation (ACCOUNTADMIN sees all) ─────────────────
SELECT '1A: ACCOUNTADMIN sees all tenants' AS test,
    COUNT(*) AS total_rows,
    COUNT(DISTINCT tenant_id) AS tenant_count
FROM multi_tenant.semantic.fct_revenue;

-- ─── TEST 2: Multi-Tenant Isolation (restricted role sees only TNT-001) ─────
-- NOTE: Run this manually after switching role:
--   USE ROLE test_tenant_user;
--   SELECT tenant_id, COUNT(*) FROM multi_tenant.semantic.fct_revenue GROUP BY 1;
--   USE ROLE ACCOUNTADMIN;

-- ─── TEST 3: Tier-Based Metric Access ───────────────────────────────────────
SELECT '3: Tier access check' AS test,
    multi_tenant.policies.can_access_metric('active_users') AS can_access_active_users;

-- ─── TEST 4: Dynamic Table Freshness ────────────────────────────────────────
SELECT '4: Freshness distribution' AS test,
    freshness_status, COUNT(*) AS records,
    MIN(data_age_seconds) AS min_age_sec,
    MAX(data_age_seconds) AS max_age_sec
FROM multi_tenant.streaming.page_load_with_freshness
GROUP BY freshness_status
ORDER BY min_age_sec;

-- ─── TEST 5: API - Enterprise tenant, certified metric (expect 200) ─────────
CALL multi_tenant.semantic.query_metric('customer_acquisition_cost', 'TNT-001');

-- ─── TEST 6: API - Free tenant, premium metric (expect 403) ─────────────────
CALL multi_tenant.semantic.query_metric('customer_acquisition_cost', 'TNT-003');

-- ─── TEST 7: API - Any tenant, uncertified metric (expect 404) ──────────────
CALL multi_tenant.semantic.query_metric('nonexistent_metric', 'TNT-001');

-- ─── TEST 8: API Request Log ────────────────────────────────────────────────
SELECT '8: API request log' AS test,
    response_status, COUNT(*) AS request_count
FROM multi_tenant.semantic.api_request_log
GROUP BY response_status
ORDER BY response_status;

-- ─── TEST 9: Cross-Cloud Spoke Resolution ───────────────────────────────────
CALL governance.operating_model.spoke_resolve_metric('customer_acquisition_cost');

-- ─── TEST 10: Glossary Sync Validation (simulate spoke at version 1) ────────
CALL governance.operating_model.validate_glossary_sync(1);

-- ─── TEST 11: Glossary Sync Validation (simulate spoke fully synced) ────────
CALL governance.operating_model.validate_glossary_sync(3);

-- ─── TEST 12: Federation Health ─────────────────────────────────────────────
SELECT * FROM governance.operating_model.federation_health;

-- ─── TEST 13: GDPR Safe Aggregates (k-anonymity enforced) ───────────────────
SELECT '13: GDPR safe aggregates' AS test,
    COUNT(*) AS aggregate_rows,
    MIN(customer_count) AS min_k_anonymity
FROM multi_tenant.semantic.gdpr_safe_aggregates;

-- ─── TEST 14: BI Summary View ───────────────────────────────────────────────
SELECT '14: BI revenue summary' AS test,
    tenant_id, COUNT(*) AS days_of_data, SUM(total_revenue) AS total
FROM multi_tenant.semantic.bi_revenue_summary
GROUP BY tenant_id
ORDER BY total DESC;

-- ─── TEST 15: Full Inventory Summary ────────────────────────────────────────
SELECT 'Tenants' AS category, COUNT(*)::VARCHAR AS value FROM multi_tenant.tenant_mgmt.tenants
UNION ALL SELECT 'Tenant Users', COUNT(*)::VARCHAR FROM multi_tenant.tenant_mgmt.tenant_users
UNION ALL SELECT 'Revenue Rows', COUNT(*)::VARCHAR FROM multi_tenant.semantic.fct_revenue
UNION ALL SELECT 'Streaming Events', COUNT(*)::VARCHAR FROM multi_tenant.streaming.page_events
UNION ALL SELECT 'Dynamic Table Records', COUNT(*)::VARCHAR FROM multi_tenant.streaming.page_load_metrics
UNION ALL SELECT 'API Rate Limit Tiers', COUNT(*)::VARCHAR FROM multi_tenant.semantic.api_rate_limits
UNION ALL SELECT 'Freshness Tiers', COUNT(*)::VARCHAR FROM governance.operating_model.freshness_tiers
UNION ALL SELECT 'Glossary Versions', COUNT(*)::VARCHAR FROM governance.operating_model.glossary_versions
UNION ALL SELECT 'Row Access Policies', '2 (fct_revenue + fct_usage)'
UNION ALL SELECT 'BI Service Roles', '2 (Tableau + PowerBI)'
ORDER BY category;
