-- Billing sidecar DB migration
-- Drops and recreates usage_events with proper schema for sidecar billing.
-- Safe because the old UsageCollector (kubectl exec) was unreliable and has minimal data.

DROP TABLE IF EXISTS usage_events CASCADE;

CREATE TABLE usage_events (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     TEXT          NOT NULL,
    message_id    TEXT          NOT NULL,
    session_id    TEXT,
    timestamp     TIMESTAMPTZ   NOT NULL,
    provider      TEXT          NOT NULL,
    model         TEXT          NOT NULL,
    input_tokens  INT           NOT NULL DEFAULT 0,
    output_tokens INT           NOT NULL DEFAULT 0,
    cache_read    INT           NOT NULL DEFAULT 0,
    cache_write   INT           NOT NULL DEFAULT 0,
    total_tokens  INT           NOT NULL DEFAULT 0,
    cost_usd      NUMERIC(12,6) NOT NULL DEFAULT 0,
    created_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    UNIQUE (tenant_id, message_id)
);

CREATE INDEX idx_usage_tenant_ts ON usage_events (tenant_id, timestamp);
CREATE INDEX idx_usage_model_ts ON usage_events (model, timestamp);
