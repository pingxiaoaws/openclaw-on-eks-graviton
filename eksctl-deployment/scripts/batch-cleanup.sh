#!/bin/bash
# Batch cleanup all OpenClaw user instances and registered users
#
# Usage:
#   ./batch-cleanup.sh              # interactive confirmation
#   ./batch-cleanup.sh -y           # skip confirmation
#   ./batch-cleanup.sh -y --dry-run # preview only, no deletion

set -euo pipefail

DRY_RUN=false
AUTO_YES=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -y|--yes)    AUTO_YES=true; shift ;;
    --dry-run)   DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: $(basename "$0") [-y|--yes] [--dry-run]"
      echo "  -y        Skip confirmation prompt"
      echo "  --dry-run Preview what would be deleted without actually deleting"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Discover all openclaw user namespaces ─────────────────────────────────────
echo "Scanning for OpenClaw user namespaces..."
NAMESPACES=$(kubectl get ns -l openclaw.rocks/user-id -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

if [ -z "$NAMESPACES" ]; then
  # Fallback: match by naming convention
  NAMESPACES=$(kubectl get ns --no-headers -o custom-columns=':metadata.name' 2>/dev/null \
    | grep '^openclaw-[a-f0-9]' || true)
fi

HAS_NAMESPACES=true
if [ -z "$NAMESPACES" ]; then
  HAS_NAMESPACES=false
  echo "No OpenClaw user namespaces found."
fi

NS_COUNT=0
DELETED=0
FAILED=0

if [ "$HAS_NAMESPACES" = true ]; then
  NS_COUNT=$(echo "$NAMESPACES" | wc -w | tr -d ' ')

  echo ""
  echo "Found $NS_COUNT OpenClaw user namespace(s):"
  for ns in $NAMESPACES; do
    echo "  - $ns"
  done
fi

# ── Check registered users in database ─────────────────────────────────────
echo ""
echo "Checking registered users in database..."
POSTGRES_NS="openclaw-provisioning"
POSTGRES_POD=$(kubectl get pods -n "$POSTGRES_NS" -l app=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
DB_USER_COUNT=0

if [ -n "$POSTGRES_POD" ]; then
  DB_USER_COUNT=$(kubectl exec -n "$POSTGRES_NS" "$POSTGRES_POD" -- \
    psql -U openclaw -d openclaw -t -A -c "SELECT COUNT(*) FROM users;" 2>/dev/null || echo "0")
  DB_USER_COUNT=$(echo "$DB_USER_COUNT" | tr -d '[:space:]')
  echo "Found $DB_USER_COUNT registered user(s) in database."
else
  echo "  ⚠️  Could not find postgres pod, will skip database cleanup."
fi

echo ""

if [ "$DRY_RUN" = true ]; then
  [ "$HAS_NAMESPACES" = true ] && echo "[DRY RUN] Would delete $NS_COUNT namespace(s)."
  [ "$DB_USER_COUNT" -gt 0 ] 2>/dev/null && echo "[DRY RUN] Would clear $DB_USER_COUNT registered user(s) and related data."
  echo "[DRY RUN] No changes made."
  exit 0
fi

# ── Confirm ───────────────────────────────────────────────────────────────────
if [ "$AUTO_YES" != true ]; then
  echo "This will:"
  [ "$HAS_NAMESPACES" = true ] && echo "  • Delete $NS_COUNT OpenClaw user namespace(s)"
  echo "  • Remove Pod Identity Associations"
  [ "$DB_USER_COUNT" -gt 0 ] 2>/dev/null && echo "  • Clear $DB_USER_COUNT registered user(s) and usage data from database"
  echo ""
  read -p "Proceed? [y/N] " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# ── Delete namespaces ──────────────────────────────────────────────────────────
if [ "$HAS_NAMESPACES" = true ]; then
  echo ""
  echo "Deleting namespaces..."
  for ns in $NAMESPACES; do
    echo -n "  Deleting $ns ... "
    if kubectl delete ns "$ns" --wait=false 2>/dev/null; then
      echo "✅"
      DELETED=$((DELETED + 1))
    else
      echo "❌"
      FAILED=$((FAILED + 1))
    fi
  done
fi

# ── Clean up Pod Identity Associations ────────────────────────────────────────
echo ""
echo "Cleaning up Pod Identity Associations..."

CLUSTER_ARN=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null || true)
if [[ "$CLUSTER_ARN" == arn:aws*:eks:* ]]; then
  CLUSTER_NAME=$(echo "$CLUSTER_ARN" | cut -d'/' -f2)
  AWS_REGION=$(echo "$CLUSTER_ARN" | cut -d':' -f4)
else
  CLUSTER_NAME=$(kubectl config current-context 2>/dev/null | cut -d'@' -f2 | cut -d'.' -f1 || true)
  AWS_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
fi

if [ -n "$CLUSTER_NAME" ]; then
  PIA_COUNT=0
  for ns in $NAMESPACES; do
    ASSOC_IDS=$(aws eks list-pod-identity-associations \
      --cluster-name "$CLUSTER_NAME" \
      --namespace "$ns" \
      --region "$AWS_REGION" \
      --query 'associations[].associationId' \
      --output text 2>/dev/null || true)

    for aid in $ASSOC_IDS; do
      [ -z "$aid" ] || [ "$aid" = "None" ] && continue
      aws eks delete-pod-identity-association \
        --cluster-name "$CLUSTER_NAME" \
        --association-id "$aid" \
        --region "$AWS_REGION" 2>/dev/null && PIA_COUNT=$((PIA_COUNT + 1)) || true
    done
  done
  echo "  Removed $PIA_COUNT Pod Identity Association(s)"
else
  echo "  ⚠️  Could not determine cluster name, skipping PIA cleanup"
fi

# ── Clear registered users from database ─────────────────────────────────────
echo ""
echo "Clearing registered users and usage data from database..."
DB_CLEARED=false

if [ -n "$POSTGRES_POD" ]; then
  DB_OUTPUT=$(kubectl exec -n "$POSTGRES_NS" "$POSTGRES_POD" -- \
    sh -c "psql -U openclaw -d openclaw -t -A <<'SQL'
DELETE FROM daily_usage;
DELETE FROM hourly_usage;
DELETE FROM usage_events;
DELETE FROM sessions;
DELETE FROM users;
SELECT 'OK';
SQL" 2>&1) || true

  if echo "$DB_OUTPUT" | grep -q "OK"; then
    DB_CLEARED=true
    echo "  ✅ Cleared all users, sessions, and usage data"
  else
    echo "  ❌ Database cleanup failed:"
    echo "     $DB_OUTPUT"
  fi
else
  echo "  ⚠️  Postgres pod not found, skipping database cleanup"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "======================================"
echo "  Cleanup Complete"
echo "======================================"
[ "$HAS_NAMESPACES" = true ] && echo "  ✅ Deleted:  $DELETED namespace(s)"
[ "$FAILED" -gt 0 ] && echo "  ❌ Failed:   $FAILED namespace(s)"
echo "  🗄️  Database: $([ "$DB_CLEARED" = true ] && echo "cleared" || echo "skipped/failed")"
echo "======================================"
echo ""
[ "$HAS_NAMESPACES" = true ] && echo "Note: Namespaces delete asynchronously. Run 'kubectl get ns | grep openclaw-' to check progress."
