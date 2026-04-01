#!/bin/bash
set -euo pipefail

# ============================================================
# Hub Service Orchestrator — Deployment Script
# ============================================================
# Reads a deployment payload JSON and executes the full GitOps
# deployment flow: generate ArgoCD apps → commit → sync → watch
#
# Interfaces:
#   - Git (commit, push, revert)
#   - ArgoCD REST API (create app, sync, watch status)
#
# Usage:
#   ./deploy.sh <payload.json> [--dry-run]
# ============================================================

PAYLOAD_FILE="$(cd "$(dirname "${1:?Usage: ./deploy.sh <payload.json> [--dry-run]}")" && pwd)/$(basename "$1")"
DRY_RUN="${2:-}"
AUTO_APPROVE="${3:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GITOPS_DIR="/tmp/nf-demo-gitops"
MANIFESTS_DIR="$PROJECT_DIR/manifests"

# ArgoCD config
ARGOCD_URL="https://localhost:30443"
ARGOCD_INSECURE="-sk"

# Gitea config
GITEA_URL="http://localhost:3000"
GITEA_USER="gitea_admin"
GITEA_PASS="gitea_admin"

# State file
STATE_FILE="/tmp/hub-deployment-state.json"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

# ============================================================
# Utility functions
# ============================================================

log()   { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()    { echo -e "${GREEN}[$(date +%H:%M:%S)] ✓${NC} $*"; }
warn()  { echo -e "${YELLOW}[$(date +%H:%M:%S)] !${NC} $*"; }
err()   { echo -e "${RED}[$(date +%H:%M:%S)] ✗${NC} $*"; }
header(){ echo -e "\n${BOLD}${CYAN}═══ $* ═══${NC}\n"; }

jq_read() { jq -r "$1" "$PAYLOAD_FILE"; }

# ============================================================
# ArgoCD API helpers
# ============================================================

argocd_login() {
  local pass
  pass=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
  ARGOCD_TOKEN=$(curl $ARGOCD_INSECURE "$ARGOCD_URL/api/v1/session" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"admin\",\"password\":\"$pass\"}" 2>/dev/null | jq -r '.token')

  if [ -z "$ARGOCD_TOKEN" ] || [ "$ARGOCD_TOKEN" = "null" ]; then
    err "Failed to get ArgoCD token"
    exit 1
  fi
  ok "ArgoCD authenticated (token: ${ARGOCD_TOKEN:0:20}...)"
}

argocd_api() {
  local method="$1" path="$2" data="${3:-}"
  local args=($ARGOCD_INSECURE -H "Cookie: argocd.token=$ARGOCD_TOKEN" -H "Content-Type: application/json")
  if [ -n "$data" ]; then
    args+=(-d "$data")
  fi
  curl -s "${args[@]}" -X "$method" "$ARGOCD_URL/api/v1/$path" 2>/dev/null
}

argocd_create_app() {
  local name="$1" repo="$2" path="$3" namespace="$4" project="$5" wave="${6:-0}"

  local body
  body=$(jq -n \
    --arg name "$name" \
    --arg repo "$repo" \
    --arg path "$path" \
    --arg ns "$namespace" \
    --arg project "$project" \
    --arg wave "$wave" \
    '{
      metadata: { name: $name, namespace: "argocd", annotations: { "argocd.argoproj.io/sync-wave": $wave }, labels: { "app.kubernetes.io/managed-by": "hub-orchestrator" } },
      spec: {
        project: $project,
        source: { repoURL: $repo, path: ("environments/dev/" + $path), targetRevision: "main" },
        destination: { server: "https://kubernetes.default.svc", namespace: $ns }
      }
    }')

  argocd_api POST "applications" "$body"
}

argocd_sync_app() {
  local name="$1"
  argocd_api POST "applications/$name/sync" '{"prune":true,"strategy":{"apply":{"force":false}}}'
}

argocd_get_app() {
  local name="$1"
  argocd_api GET "applications/$name"
}

argocd_get_health() {
  local name="$1"
  argocd_get_app "$name" | jq -r '{sync: .status.sync.status, health: .status.health.status}'
}

argocd_delete_app() {
  local name="$1"
  argocd_api DELETE "applications/$name?cascade=true"
}

argocd_wait_healthy() {
  local name="$1" timeout="${2:-120}"
  local elapsed=0

  while [ $elapsed -lt $timeout ]; do
    local status
    status=$(argocd_get_app "$name" 2>/dev/null)
    local sync_status health_status
    sync_status=$(echo "$status" | jq -r '.status.sync.status // "Unknown"')
    health_status=$(echo "$status" | jq -r '.status.health.status // "Unknown"')

    if [ "$sync_status" = "Synced" ] && [ "$health_status" = "Healthy" ]; then
      return 0
    elif [ "$health_status" = "Degraded" ]; then
      return 1
    fi

    sleep 5
    elapsed=$((elapsed + 5))
    printf "\r  Waiting... sync=%s health=%s (%ds/%ds)  " "$sync_status" "$health_status" "$elapsed" "$timeout"
  done
  echo ""
  return 1
}

argocd_get_health_report() {
  local name="$1"
  local tree
  tree=$(argocd_api GET "applications/$name/resource-tree")

  local pods_total pods_healthy
  pods_total=$(echo "$tree" | jq '[.nodes[] | select(.kind=="Pod")] | length' 2>/dev/null || echo "0")
  pods_healthy=$(echo "$tree" | jq '[.nodes[] | select(.kind=="Pod") | select(.health.status=="Healthy")] | length' 2>/dev/null || echo "0")

  local svcs_total svcs_healthy
  svcs_total=$(echo "$tree" | jq '[.nodes[] | select(.kind=="Service")] | length' 2>/dev/null || echo "0")
  svcs_healthy=$(echo "$tree" | jq '[.nodes[] | select(.kind=="Service") | select(.health.status=="Healthy")] | length' 2>/dev/null || echo "0")

  # Capture error messages from unhealthy resources
  local errors
  errors=$(echo "$tree" | jq -c '[.nodes[] | select(.health.status != "Healthy" and .health.status != null and .health.message != null) | {kind: .kind, name: .name, status: .health.status, message: .health.message}] // []' 2>/dev/null || echo "[]")

  echo "{\"pods_ready\":\"$pods_healthy/$pods_total\",\"services_with_endpoints\":\"$svcs_healthy/$svcs_total\",\"errors\":$errors}"
}

# ============================================================
# Git helpers
# ============================================================

git_clone_or_pull() {
  if [ -d "$GITOPS_DIR/.git" ]; then
    cd "$GITOPS_DIR"
    git pull --rebase origin main 2>/dev/null || true
  else
    rm -rf "$GITOPS_DIR"
    git clone "http://${GITEA_USER}:${GITEA_PASS}@localhost:3000/${GITEA_USER}/nf-demo-gitops.git" "$GITOPS_DIR" 2>/dev/null
    cd "$GITOPS_DIR"
  fi
}

git_commit_and_push() {
  local message="$1"
  cd "$GITOPS_DIR"
  git add -A
  if git diff --staged --quiet 2>/dev/null; then
    warn "No changes to commit"
    return 1
  fi
  git commit -m "$message" 2>/dev/null
  local sha
  sha=$(git rev-parse HEAD)
  git push origin main 2>/dev/null
  echo "$sha"
}

git_diff_preview() {
  cd "$GITOPS_DIR"
  git add -A
  git diff --staged --stat 2>/dev/null
  echo "---"
  git diff --staged 2>/dev/null | head -100
  git reset HEAD 2>/dev/null || true
}

# ============================================================
# State management
# ============================================================

state_init() {
  local deployment_id helix_id action environment nf
  deployment_id=$(jq_read '.deployment_id')
  helix_id=$(jq_read '.helix_id')
  action=$(jq_read '.action')
  environment=$(jq_read '.environment')
  nf=$(jq_read '.nf')

  jq -n \
    --arg did "$deployment_id" \
    --arg hid "$helix_id" \
    --arg action "$action" \
    --arg env "$environment" \
    --arg nf "$nf" \
    '{
      deployment_id: $did,
      helix_id: $hid,
      action: $action,
      environment: $env,
      nf: $nf,
      status: "pending",
      deployed: [],
      current: null,
      pending_approval: false,
      component_results: {},
      created_at: (now | todate)
    }' > "$STATE_FILE"
}

state_update() {
  local field="$1" value="$2"
  local tmp=$(mktemp)
  jq "$field = $value" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

state_read() {
  jq -r "$1" "$STATE_FILE"
}

state_add_deployed() {
  local component="$1"
  local tmp=$(mktemp)
  jq --arg c "$component" '.deployed += [$c]' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

state_set_component_result() {
  local component="$1" status="$2" commit_sha="$3" health_report="${4:-{}}"
  local tmp=$(mktemp)
  # Ensure health_report is valid JSON, default to empty object
  if ! echo "$health_report" | jq . >/dev/null 2>&1; then
    health_report='{}'
  fi
  jq --arg c "$component" --arg s "$status" --arg sha "$commit_sha" --argjson hr "$health_report" \
    '.component_results[$c] = {status: $s, commit_sha: $sha, deployed_at: (now | todate), health_report: $hr}' \
    "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# ============================================================
# Core orchestration
# ============================================================

create_app_of_apps() {
  local gitops_repo namespace project
  gitops_repo=$(jq_read '.defaults.gitops_repo')
  project=$(jq_read '.defaults.argocd_project')

  header "Day 0: Creating App-of-Apps"

  local body
  body=$(jq -n \
    --arg repo "$gitops_repo" \
    --arg project "$project" \
    '{
      metadata: { name: "nf-demo", namespace: "argocd" },
      spec: {
        project: $project,
        source: { repoURL: $repo, path: "environments/dev/applications", targetRevision: "main" },
        destination: { server: "https://kubernetes.default.svc" },
        syncPolicy: { automated: { prune: true } }
      }
    }')

  if [ "$DRY_RUN" = "--dry-run" ]; then
    warn "[DRY RUN] Would create app-of-apps"
    echo "$body" | jq .
    return
  fi

  argocd_api POST "applications" "$body" | jq -r '.metadata.name // "error"'
  ok "App-of-apps created"
}

generate_application_yamls() {
  header "Generating ArgoCD Application YAMLs from payload"

  local gitops_repo namespace project env
  gitops_repo=$(jq_read '.defaults.gitops_repo')
  namespace=$(jq_read '.defaults.namespace')
  project=$(jq_read '.defaults.argocd_project')
  env=$(jq_read '.environment')

  mkdir -p "$GITOPS_DIR/environments/$env/applications"

  # Namespace
  cat > "$GITOPS_DIR/environments/$env/applications/namespace.yaml" << EOFNS
apiVersion: v1
kind: Namespace
metadata:
  name: $namespace
EOFNS

  # Generate Application YAML per chart from payload
  for component in $(jq_read '.components | keys[]'); do
    local comp_ns
    comp_ns=$(jq_read ".components[\"$component\"].namespace")

    for chart_key in $(jq_read ".components[\"$component\"].charts | keys[]"); do
      local chart_type path sync_wave display_name
      chart_type=$(jq_read ".components[\"$component\"].charts[\"$chart_key\"].type")
      path=$(jq_read ".components[\"$component\"].charts[\"$chart_key\"].path")
      sync_wave=$(jq_read ".components[\"$component\"].charts[\"$chart_key\"].sync_wave")
      display_name=$(jq_read ".components[\"$component\"].charts[\"$chart_key\"].display_name")

      if [ "$chart_type" = "multi_instance" ]; then
        # Pattern C: create one Application per instance
        for instance in $(jq_read ".components[\"$component\"].charts[\"$chart_key\"].instances | keys[]"); do
          local inst_path
          inst_path=$(jq_read ".components[\"$component\"].charts[\"$chart_key\"].instances[\"$instance\"].path")
          local app_name="${chart_key}-${instance}"

          cat > "$GITOPS_DIR/environments/$env/applications/$app_name.yaml" << EOFAPP
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $app_name
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "$sync_wave"
  labels:
    app.kubernetes.io/part-of: $project
    app.kubernetes.io/component: $component
    app.kubernetes.io/managed-by: hub-orchestrator
spec:
  project: $project
  source:
    repoURL: $gitops_repo
    path: environments/$env/$inst_path
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: $comp_ns
EOFAPP
          log "  Generated: $app_name (multi-instance: $instance)"
        done
      else
        # Pattern A or B: one Application per chart
        cat > "$GITOPS_DIR/environments/$env/applications/$chart_key.yaml" << EOFAPP
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $chart_key
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "$sync_wave"
  labels:
    app.kubernetes.io/part-of: $project
    app.kubernetes.io/component: $component
    app.kubernetes.io/managed-by: hub-orchestrator
spec:
  project: $project
  source:
    repoURL: $gitops_repo
    path: environments/$env/$path
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: $comp_ns
EOFAPP
        log "  Generated: $chart_key ($display_name)"
      fi
    done
  done

  ok "Application YAMLs generated"
}

copy_manifests() {
  local env
  env=$(jq_read '.environment')

  header "Copying manifests to GitOps repo"

  # Copy all manifest directories
  for component in $(jq_read '.components | keys[]'); do
    for chart_key in $(jq_read ".components[\"$component\"].charts | keys[]"); do
      local chart_type path
      chart_type=$(jq_read ".components[\"$component\"].charts[\"$chart_key\"].type")
      path=$(jq_read ".components[\"$component\"].charts[\"$chart_key\"].path")

      if [ "$chart_type" = "multi_instance" ]; then
        for instance in $(jq_read ".components[\"$component\"].charts[\"$chart_key\"].instances | keys[]"); do
          local inst_path
          inst_path=$(jq_read ".components[\"$component\"].charts[\"$chart_key\"].instances[\"$instance\"].path")
          mkdir -p "$GITOPS_DIR/environments/$env/$inst_path"
          cp -r "$MANIFESTS_DIR/$inst_path/"* "$GITOPS_DIR/environments/$env/$inst_path/" 2>/dev/null || true
          log "  Copied: $inst_path"
        done
      else
        mkdir -p "$GITOPS_DIR/environments/$env/$path"
        cp -r "$MANIFESTS_DIR/$path/"* "$GITOPS_DIR/environments/$env/$path/" 2>/dev/null || true
        log "  Copied: $path"
      fi
    done
  done

  # Also copy landing page
  mkdir -p "$GITOPS_DIR/environments/$env/landing"
  cp -r "$MANIFESTS_DIR/landing/"* "$GITOPS_DIR/environments/$env/landing/" 2>/dev/null || true

  ok "Manifests copied"
}

deploy_component() {
  local component="$1"
  local display_name helix_id
  display_name=$(jq_read ".components[\"$component\"].display_name")
  helix_id=$(jq_read '.helix_id')

  header "Deploying: $display_name ($component)"
  state_update '.current' "\"$component\""
  state_update '.status' '"in_progress"'

  # Check if already deployed
  local deployed
  deployed=$(state_read '.deployed[]' 2>/dev/null || echo "")
  if echo "$deployed" | grep -q "^${component}$"; then
    warn "Already deployed, skipping"
    return 0
  fi

  # Get chart keys for this component
  local charts
  charts=$(jq_read ".components[\"$component\"].charts | keys[]")

  # Commit manifests for this component
  local commit_message commit_sha
  local version
  version=$(jq_read ".components[\"$component\"].charts | to_entries[0].value.version")
  commit_message="${component}: Deploy v${version} - ${helix_id}"

  if [ "$DRY_RUN" = "--dry-run" ]; then
    warn "[DRY RUN] Would commit: $commit_message"
    log "Files that would change:"
    git_diff_preview
    state_set_component_result "$component" "skipped" "dry-run" '{}'
    return 0
  fi

  commit_sha=$(git_commit_and_push "$commit_message" 2>/dev/null || echo "")
  if [ -z "$commit_sha" ]; then
    warn "No changes for $component (already up to date)"
    state_set_component_result "$component" "skipped" "no-change" '{}'
    state_add_deployed "$component"
    return 0
  fi
  ok "Committed: ${commit_sha:0:8} — $commit_message"

  # Sync each ArgoCD app for this component
  for chart_key in $charts; do
    local chart_type
    chart_type=$(jq_read ".components[\"$component\"].charts[\"$chart_key\"].type")

    if [ "$chart_type" = "multi_instance" ]; then
      for instance in $(jq_read ".components[\"$component\"].charts[\"$chart_key\"].instances | keys[]"); do
        local app_name="${chart_key}-${instance}"
        log "  Syncing: $app_name"
        argocd_sync_app "$app_name" >/dev/null 2>&1 || true
      done
    else
      log "  Syncing: $chart_key"
      argocd_sync_app "$chart_key" >/dev/null 2>&1 || true
    fi
  done

  # Wait for health
  local timeout
  timeout=$(jq_read ".components[\"$component\"].deployment_config.sync_timeout" | sed 's/s//')
  local all_healthy=true

  for chart_key in $charts; do
    local chart_type
    chart_type=$(jq_read ".components[\"$component\"].charts[\"$chart_key\"].type")

    if [ "$chart_type" = "multi_instance" ]; then
      for instance in $(jq_read ".components[\"$component\"].charts[\"$chart_key\"].instances | keys[]"); do
        local app_name="${chart_key}-${instance}"
        printf "\n"
        if argocd_wait_healthy "$app_name" "$timeout"; then
          ok "  $app_name: Healthy"
        else
          err "  $app_name: Unhealthy"
          all_healthy=false
        fi
      done
    else
      printf "\n"
      if argocd_wait_healthy "$chart_key" "$timeout"; then
        ok "  $chart_key: Healthy"
      else
        err "  $chart_key: Unhealthy"
        all_healthy=false
      fi
    fi
  done

  # Get health report
  local first_chart
  first_chart=$(echo "$charts" | head -1)
  local health_report
  health_report=$(argocd_get_health_report "$first_chart" 2>/dev/null || echo '{}')
  # Ensure valid JSON
  echo "$health_report" | jq . >/dev/null 2>&1 || health_report='{}'

  if $all_healthy; then
    state_set_component_result "$component" "healthy" "$commit_sha" "$health_report"
    state_add_deployed "$component"
    ok "$display_name: HEALTHY"
  else
    local auto_rollback
    auto_rollback=$(jq_read ".components[\"$component\"].deployment_config.auto_rollback")
    state_set_component_result "$component" "unhealthy" "$commit_sha" "$health_report"

    if [ "$auto_rollback" = "true" ]; then
      warn "$display_name: UNHEALTHY — auto-rollback enabled"
      rollback_component "$component" "$commit_sha"
    else
      err "$display_name: UNHEALTHY — manual intervention required"
      state_update '.status' '"failed"'
      return 1
    fi
  fi
}

check_approval() {
  local component="$1"
  local manual_approval approval_message
  manual_approval=$(jq_read ".components[\"$component\"].deployment_config.manual_approval")
  approval_message=$(jq_read ".components[\"$component\"].deployment_config.approval_message")

  if [ "$manual_approval" = "true" ]; then
    if [ "$AUTO_APPROVE" = "--auto-approve" ]; then
      warn "Auto-approved: $approval_message"
    else
      state_update '.pending_approval' 'true'
      echo ""
      echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
      echo -e "${YELLOW}║  APPROVAL REQUIRED                                        ║${NC}"
      echo -e "${YELLOW}║  $approval_message"
      echo -e "${YELLOW}║                                                            ║${NC}"
      echo -e "${YELLOW}║  Press ENTER to approve, or Ctrl+C to cancel              ║${NC}"
      echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
      echo ""
      read -r
      state_update '.pending_approval' 'false'
      ok "Approved — continuing deployment"
    fi
  fi
}

rollback_component() {
  local component="$1" commit_sha="$2"
  local helix_id
  helix_id=$(jq_read '.helix_id')

  header "Rolling back: $component"

  cd "$GITOPS_DIR"
  git revert --no-edit "$commit_sha" 2>/dev/null
  git commit --amend -m "${component}: Rollback - ${helix_id}" 2>/dev/null
  git push origin main 2>/dev/null

  # Sync affected apps
  for chart_key in $(jq_read ".components[\"$component\"].charts | keys[]"); do
    local chart_type
    chart_type=$(jq_read ".components[\"$component\"].charts[\"$chart_key\"].type")
    if [ "$chart_type" = "multi_instance" ]; then
      for instance in $(jq_read ".components[\"$component\"].charts[\"$chart_key\"].instances | keys[]"); do
        argocd_sync_app "${chart_key}-${instance}" >/dev/null 2>&1 || true
      done
    else
      argocd_sync_app "$chart_key" >/dev/null 2>&1 || true
    fi
  done

  state_set_component_result "$component" "rolled_back" "$(git rev-parse HEAD)" '{}'
  ok "$component rolled back"
}

# ============================================================
# Main orchestration loop
# ============================================================

main() {
  header "Hub Service Orchestrator"
  log "Payload: $PAYLOAD_FILE"
  log "Dry run: ${DRY_RUN:-no}"

  # Initialize
  argocd_login
  state_init
  git_clone_or_pull

  local deployment_id helix_id nf is_bootstrap
  deployment_id=$(jq_read '.deployment_id')
  helix_id=$(jq_read '.helix_id')
  nf=$(jq_read '.nf')
  is_bootstrap=$(jq_read '.is_bootstrap')

  log "Deployment: $deployment_id"
  log "Helix: $helix_id"
  log "NF: $nf"
  log "Bootstrap: $is_bootstrap"

  # Generate Application YAMLs from payload
  generate_application_yamls
  copy_manifests

  # Bootstrap app-of-apps if Day 0
  if [ "$is_bootstrap" = "true" ]; then
    # Commit the initial structure first
    cd "$GITOPS_DIR"
    git add -A
    git commit -m "Bootstrap: Initial GitOps structure - ${helix_id}" 2>/dev/null || true
    git push origin main 2>/dev/null || true

    create_app_of_apps

    if [ "$DRY_RUN" != "--dry-run" ]; then
      log "Waiting for app-of-apps to discover applications..."
      sleep 10
    fi
  fi

  # Create namespace
  if [ "$DRY_RUN" != "--dry-run" ]; then
    kubectl create namespace "$(jq_read '.defaults.namespace')" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
  fi

  state_update '.status' '"in_progress"'

  # Deploy batch by batch
  local max_batch
  max_batch=$(jq_read '[.deployment_order[].batch] | max')

  for batch in $(seq 1 "$max_batch"); do
    local components_in_batch
    components_in_batch=$(jq -r ".deployment_order[] | select(.batch == $batch) | .component" "$PAYLOAD_FILE")
    local count
    count=$(echo "$components_in_batch" | wc -l | tr -d ' ')

    header "Batch $batch/$max_batch ($count component(s))"

    if [ "$count" -gt 1 ]; then
      log "Parallel deployment: $components_in_batch"
    fi

    for component in $components_in_batch; do
      deploy_component "$component"
      check_approval "$component"
    done
  done

  # Finalize
  state_update '.status' '"success"'
  state_update '.current' 'null'

  header "Deployment Complete"
  ok "Status: SUCCESS"
  ok "Deployment ID: $deployment_id"
  ok "Helix: $helix_id"
  echo ""
  log "Deployed components:"
  state_read '.deployed[]' | while read -r c; do
    local result
    result=$(state_read ".component_results[\"$c\"].status")
    echo -e "  ${GREEN}✓${NC} $c ($result)"
  done

  echo ""
  log "State file: $STATE_FILE"
  echo ""
}

main
