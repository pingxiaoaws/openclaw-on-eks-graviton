#!/bin/bash
# Batch provision OpenClaw instances via Karpenter
#
# Usage:
#   ./batch-provision.sh -n 10 -u https://xxxx.cloudfront.net
#   ./batch-provision.sh -n 5 -u http://localhost:8080 -p workshop -N my-nodepool
#
# The script will:
#   1. Register N users (user01..userNN)
#   2. Login each user to obtain a session cookie
#   3. Call /provision with use_karpenter=true
#   4. Write credentials to a temp CSV file

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
COUNT=10
BASE_URL=""
PASSWORD_PREFIX="Workshop2026!"
NODEPOOL_NAME="standard-arm64"
CONCURRENT=5          # max parallel provisions

# ── Parse args ────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -n NUM       Number of instances to create (default: $COUNT)
  -u URL       Base URL of provisioning service (required)
  -p PREFIX    Password prefix (default: $PASSWORD_PREFIX)
  -N NODEPOOL  Karpenter NodePool name (default: $NODEPOOL_NAME)
  -c NUM       Max concurrent requests (default: $CONCURRENT)
  -h           Show this help
EOF
  exit 1
}

while getopts "n:u:p:N:c:h" opt; do
  case $opt in
    n) COUNT=$OPTARG ;;
    u) BASE_URL=$OPTARG ;;
    p) PASSWORD_PREFIX=$OPTARG ;;
    N) NODEPOOL_NAME=$OPTARG ;;
    c) CONCURRENT=$OPTARG ;;
    h) usage ;;
    *) usage ;;
  esac
done

if [ -z "$BASE_URL" ]; then
  echo "Error: -u BASE_URL is required"
  usage
fi

# Strip trailing slash
BASE_URL="${BASE_URL%/}"

# ── Output file ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)"
OUTPUT_FILE="${SCRIPT_DIR}/openclaw-batch-$(date +%Y%m%d-%H%M%S).csv"
echo "email,username,password,user_id,instance_name,status" > "$OUTPUT_FILE"

# ── Pre-flight: set Karpenter env vars on provisioning service ────────────────
echo "Configuring provisioning service for Karpenter (nodepool: $NODEPOOL_NAME)..."
kubectl set env deployment/openclaw-provisioning -n openclaw-provisioning \
  KARPENTER_NODEPOOL_NAME="$NODEPOOL_NAME" \
  KARPENTER_TAINT_KEY="kata-dedicated" \
  USE_KARPENTER=true 2>/dev/null && \
  kubectl rollout status deployment/openclaw-provisioning -n openclaw-provisioning --timeout=120s 2>/dev/null || \
  echo "⚠️  Could not update provisioning service env (not fatal if already set)"

# Wait for all pods to be ready and serving traffic
echo "Waiting for provisioning service to be fully ready..."
kubectl wait --for=condition=Available deployment/openclaw-provisioning \
  -n openclaw-provisioning --timeout=60s 2>/dev/null || true
# Extra grace period for LB / CloudFront to pick up healthy targets
sleep 5
echo "✅ Provisioning service ready"
echo ""

echo "======================================"
echo "  Batch Provision OpenClaw Instances"
echo "======================================"
echo "  Count:    $COUNT"
echo "  URL:      $BASE_URL"
echo "  NodePool: $NODEPOOL_NAME (Karpenter)"
echo "  Output:   $OUTPUT_FILE"
echo "======================================"
echo ""

# ── Counters ──────────────────────────────────────────────────────────────────
SUCCESS=0
FAIL=0
SKIP=0

# ── Helper: provision one user ────────────────────────────────────────────────
# Runs in a subshell (backgrounded), so disable set -e to ensure errors are
# captured and written to OUTPUT_FILE instead of silently killing the process.
provision_one() {
  set +e
  local idx=$1
  local num=$(printf "%03d" "$idx")
  local username="user${num}"
  local email="user${num}@workshop.openclaw.dev"
  local password="${PASSWORD_PREFIX}${num}"
  local cookie_jar=$(mktemp /tmp/openclaw-cookie-XXXXXX)
  local status="error"
  local user_id=""
  local instance_name=""

  # 1. Register (409 = already exists, that's fine)
  local reg_http
  reg_http=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 \
    -X POST "${BASE_URL}/register" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${username}\",\"email\":\"${email}\",\"password\":\"${password}\"}" 2>/dev/null) || reg_http="000"

  if [ "$reg_http" != "201" ] && [ "$reg_http" != "409" ]; then
    echo "  [${num}] ❌ Register failed (HTTP ${reg_http})"
    echo "${email},${username},${password},,,register_failed_${reg_http}" >> "$OUTPUT_FILE"
    rm -f "$cookie_jar"
    return 1
  fi

  # 2. Login (save session cookie)
  local login_http
  login_http=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 \
    -X POST "${BASE_URL}/login" \
    -H "Content-Type: application/json" \
    -c "$cookie_jar" \
    -d "{\"email\":\"${email}\",\"password\":\"${password}\"}" 2>/dev/null) || login_http="000"

  if [ "$login_http" != "200" ]; then
    echo "  [${num}] ❌ Login failed (HTTP ${login_http})"
    echo "${email},${username},${password},,,login_failed_${login_http}" >> "$OUTPUT_FILE"
    rm -f "$cookie_jar"
    return 1
  fi

  # 3. Provision with Karpenter
  local prov_resp
  prov_resp=$(curl -s -w "\n%{http_code}" --max-time 60 \
    -X POST "${BASE_URL}/provision" \
    -H "Content-Type: application/json" \
    -b "$cookie_jar" \
    -d "{\"use_karpenter\":true,\"provider\":\"bedrock\"}" 2>/dev/null) || prov_resp=$'\n000'

  local prov_http
  prov_http=$(echo "$prov_resp" | tail -1)
  local prov_body
  prov_body=$(echo "$prov_resp" | sed '$d')

  if [ "$prov_http" = "201" ]; then
    status="created"
  elif [ "$prov_http" = "200" ]; then
    status="exists"
  else
    echo "  [${num}] ❌ Provision failed (HTTP ${prov_http})"
    echo "${email},${username},${password},,,provision_failed_${prov_http}" >> "$OUTPUT_FILE"
    rm -f "$cookie_jar"
    return 1
  fi

  user_id=$(echo "$prov_body" | grep -o '"user_id":"[^"]*"' | cut -d'"' -f4 || true)
  instance_name=$(echo "$prov_body" | grep -o '"instance_name":"[^"]*"' | cut -d'"' -f4 || true)

  echo "  [${num}] ✅ ${status} — ${email} → ${instance_name}"
  echo "${email},${username},${password},${user_id},${instance_name},${status}" >> "$OUTPUT_FILE"

  rm -f "$cookie_jar"
  return 0
}

# ── Main loop (parallel with throttle) ────────────────────────────────────────
RUNNING=0

for i in $(seq 1 "$COUNT"); do
  provision_one "$i" &
  RUNNING=$((RUNNING + 1))

  # Throttle: wait when hitting concurrency limit
  if [ "$RUNNING" -ge "$CONCURRENT" ]; then
    wait -n 2>/dev/null || true
    RUNNING=$((RUNNING - 1))
  fi
done

# Wait for all remaining
wait

# ── Summary ───────────────────────────────────────────────────────────────────
SUCCESS=$(grep -c ',created\|,exists' "$OUTPUT_FILE" || true)
FAIL=$(grep -c 'failed' "$OUTPUT_FILE" || true)

echo ""
echo "======================================"
echo "  Done!"
echo "======================================"
echo "  ✅ Success: $SUCCESS"
echo "  ❌ Failed:  $FAIL"
echo "  📄 Output:  $OUTPUT_FILE"
echo "======================================"
echo ""
echo "Preview:"
column -t -s',' "$OUTPUT_FILE" | head -20
