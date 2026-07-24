#!/usr/bin/env bash
# =============================================================================
# publish-status.sh — Query Prometheus and publish status.json to the site
# =============================================================================
#
# PURPOSE
#   Queries the kube-prometheus-stack Prometheus instance for current "up"
#   status and 30-day uptime percentages, then writes a status.json file.
#   Intended to run as a cron job inside the homelab (on the NAS, a cluster
#   CronJob, or a node with cluster network access).
#
# DEPLOYMENT
#   1. Copy this script to the machine that will run the cron (NAS, VM, etc.)
#   2. Fill in the variables below or set them as environment variables.
#   3. Test manually: bash publish-status.sh
#   4. Add to crontab (every 15 minutes is a reasonable interval):
#        */15 * * * * /opt/scripts/publish-status.sh >> /var/log/publish-status.log 2>&1
#
# PUBLISHING OPTIONS (choose one, uncomment and configure)
#   A. Commit to Hugo site repo and push (triggers Cloudflare Pages rebuild)
#   B. Upload directly to Cloudflare Pages via API
#   C. Copy to a static file served by another process (e.g., nginx, Caddy)
#
# DEPENDENCIES
#   curl, jq  — must be installed on the runner machine
#
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — override via environment or edit directly
# ---------------------------------------------------------------------------

# Prometheus endpoint (internal cluster DNS or NodePort)
PROMETHEUS_URL="${PROMETHEUS_URL:-http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090}"

# Output file — path where status.json will be written before publishing
OUTPUT_FILE="${OUTPUT_FILE:-/tmp/status.json}"

# Path inside the Hugo repo (if using git-commit publish method)
SITE_REPO="${SITE_REPO:-/opt/fin.oflaherty.is}"
SITE_STATUS_JSON="${SITE_REPO}/static/status.json"

# ---------------------------------------------------------------------------
# Service definitions
# Each entry: "Display Name|Kubernetes service label selector for `up` metric"
# The selector is matched against the `job` label in Prometheus.
# Adjust job names to match your kube-prometheus-stack scrape config.
# ---------------------------------------------------------------------------

declare -A SERVICES=(
  ["Jellyfin"]="jellyfin"
  ["Home Assistant"]="home-assistant"
  ["Grafana"]="grafana"
  ["Forgejo"]="forgejo"
  ["Navidrome"]="navidrome"
  ["AdGuard Home"]="adguard-home"
  ["Prometheus"]="prometheus"
)

declare -A SERVICE_DESCRIPTIONS=(
  ["Jellyfin"]="Media streaming"
  ["Home Assistant"]="Home automation"
  ["Grafana"]="Metrics & dashboards"
  ["Forgejo"]="Git hosting"
  ["Navidrome"]="Music streaming"
  ["AdGuard Home"]="DNS & ad-blocking"
  ["Prometheus"]="Metrics collection"
)

# ---------------------------------------------------------------------------
# Helper: run a PromQL instant query, return the first result value
# ---------------------------------------------------------------------------
promql_query() {
  local query="$1"
  local encoded
  encoded=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$query" \
    || printf '%s' "$query" | sed 's/ /%20/g; s/{/%7B/g; s/}/%7D/g; s/"/%22/g; s/=/%3D/g; s/\[/%5B/g; s/\]/%5D/g')

  curl -sf "${PROMETHEUS_URL}/api/v1/query?query=${encoded}" \
    | jq -r '.data.result[0].value[1] // "null"'
}

# ---------------------------------------------------------------------------
# Build services array for JSON output
# ---------------------------------------------------------------------------

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

build_services_json() {
  local first=true
  printf '['

  for name in "${!SERVICES[@]}"; do
    local job="${SERVICES[$name]}"
    local desc="${SERVICE_DESCRIPTIONS[$name]:-}"

    # Current up status: up{job="<job>"} offset 1d — returns 1 (up) or 0 (down) or null
    local up_val
    up_val=$(promql_query "up{job=\"${job}\"} offset 1d" 2>/dev/null || echo "null")

    # 30-day uptime percentage ending 1 day ago
    # avg_over_time(up{job="<job>"}[30d] offset 1d) * 100
    local uptime_val
    uptime_val=$(promql_query "avg_over_time(up{job=\"${job}\"}[30d] offset 1d) * 100" 2>/dev/null || echo "null")

    # Determine up boolean
    local up_bool="false"
    if [ "$up_val" = "1" ]; then
      up_bool="true"
    fi

    # Round uptime to 1 decimal place if numeric
    local uptime_rounded="null"
    if [ "$uptime_val" != "null" ] && [ -n "$uptime_val" ]; then
      uptime_rounded=$(printf "%.1f" "$uptime_val" 2>/dev/null || echo "null")
    fi

    if [ "$first" = true ]; then
      first=false
    else
      printf ','
    fi

    printf '\n    {"name":%s,"description":%s,"up":%s,"uptime_30d":%s}' \
      "$(printf '%s' "$name" | jq -Rs '.')" \
      "$(printf '%s' "$desc" | jq -Rs '.')" \
      "$up_bool" \
      "$uptime_rounded"
  done

  printf '\n  ]'
}

# ---------------------------------------------------------------------------
# Write status.json
# ---------------------------------------------------------------------------

echo "[$(date -u)] Querying Prometheus at ${PROMETHEUS_URL}..."

SERVICES_JSON=$(build_services_json)

cat > "${OUTPUT_FILE}" <<JSON
{
  "updated": "${TIMESTAMP}",
  "services": ${SERVICES_JSON}
}
JSON

echo "[$(date -u)] Wrote ${OUTPUT_FILE}"

# ---------------------------------------------------------------------------
# PUBLISH METHOD A: Git commit + push (triggers Cloudflare Pages rebuild)
# Uncomment and configure SITE_REPO above.
# ---------------------------------------------------------------------------
# cp "${OUTPUT_FILE}" "${SITE_STATUS_JSON}"
# git -C "${SITE_REPO}" add static/status.json
# git -C "${SITE_REPO}" commit -m "chore: update status.json [$(date -u +%Y-%m-%dT%H:%M)]" \
#   --author="status-bot <status@localhost>"
# git -C "${SITE_REPO}" push origin main

# ---------------------------------------------------------------------------
# PUBLISH METHOD B: Upload to Cloudflare Pages via direct upload API
# Requires: CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_API_TOKEN, PAGES_PROJECT
# ---------------------------------------------------------------------------
# CLOUDFLARE_ACCOUNT_ID="your-account-id"
# CLOUDFLARE_API_TOKEN="your-api-token"
# PAGES_PROJECT="fin-oflaherty-is"
#
# curl -sf -X PUT \
#   "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/pages/projects/${PAGES_PROJECT}/deployments/latest/assets/status.json" \
#   -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
#   -H "Content-Type: application/json" \
#   --data-binary @"${OUTPUT_FILE}"

# ---------------------------------------------------------------------------
# PUBLISH METHOD C: Copy to a local static file path
# If Caddy / nginx serves the Hugo public/ directory directly from this machine
# ---------------------------------------------------------------------------
# cp "${OUTPUT_FILE}" /srv/fin.oflaherty.is/static/status.json

echo "[$(date -u)] Done."
