# Billing Sidecar

A lightweight sidecar container that runs alongside each OpenClaw user pod, reads session JSONL files in real-time, and writes usage events to the shared PostgreSQL database.

## Architecture

```
┌─ User Pod (openclaw-<user_id>) ──────────────┐
│                                                │
│  openclaw         billing-sidecar             │
│  (main container)  (reads session files)      │
│       │                  │                     │
│       └── shared volume ─┘                     │
│           /home/openclaw/.openclaw (readonly)  │
└────────────────────┬───────────────────────────┘
                     │
                     ▼
          PostgreSQL (openclaw-provisioning/postgres)
          └── usage_events table
```

## How It Works

1. Sidecar tails `*.jsonl` files under `/home/openclaw/.openclaw/agents`
2. Filters for `type: "message"` records with `message.usage.cost`
3. Extracts token counts and cost from OpenClaw's own cost calculation
4. Batch inserts into `usage_events` with idempotent upserts (`ON CONFLICT DO NOTHING`)
5. Persists file offsets to `/tmp/sidecar-offsets.json` for restart resilience

## Deploy

```bash
cd eksctl-deployment/scripts
./06-deploy-billing-service.sh
```

This script:
1. Builds and pushes the sidecar Docker image to ECR
2. Runs the DB migration (upgrades `usage_events` table)
3. Updates the provisioning service to inject the sidecar into new instances
4. Verifies the billing endpoint

## Configuration

Environment variables for the sidecar container:

| Variable | Default | Description |
|----------|---------|-------------|
| `TENANT_ID` | (required) | User/tenant identifier |
| `DATABASE_URL` | (required) | PostgreSQL connection string |
| `OPENCLAW_SESSIONS_DIR` | `/home/openclaw/.openclaw/agents` | Path to session JSONL files |
| `POLL_INTERVAL` | `5` | Seconds between file scans |
| `BATCH_SIZE` | `50` | Max events per batch insert |

## Query Usage Data

```bash
# Via provisioning service API (requires auth)
curl -H "Cookie: session=..." https://<cloudfront>/billing/usage
curl -H "Cookie: session=..." https://<cloudfront>/billing/hourly?hours=24

# Direct SQL
kubectl exec -n openclaw-provisioning <postgres-pod> -- \
  psql -U openclaw -d openclaw -c "
    SELECT tenant_id, model, COUNT(*) as calls, SUM(cost_usd) as total_cost
    FROM usage_events
    WHERE timestamp >= NOW() - INTERVAL '24 hours'
    GROUP BY tenant_id, model
    ORDER BY total_cost DESC;
  "
```

## Troubleshooting

**Sidecar not appearing in pods:**
```bash
# Check if billing sidecar is enabled
kubectl get deployment openclaw-provisioning -n openclaw-provisioning \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | grep BILLING
```

**No usage data:**
```bash
# Check sidecar logs
kubectl logs -n openclaw-<user_id> openclaw-<user_id>-0 -c billing-sidecar

# Check if session files exist
kubectl exec -n openclaw-<user_id> openclaw-<user_id>-0 -c openclaw -- \
  find /home/openclaw/.openclaw/agents -name "*.jsonl" | head -5
```

**DB connection errors:**
```bash
# Verify postgres is reachable from user namespace
kubectl run -n openclaw-<user_id> --rm -it pg-test --image=busybox -- \
  nc -zv postgres.openclaw-provisioning.svc 5432
```
