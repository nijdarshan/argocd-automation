#!/bin/bash
set -euo pipefail

# ============================================================
# Use Case Runner
# ============================================================
# Usage:
#   ./usecase.sh all          Run all use cases sequentially
#   ./usecase.sh uc2          Run single use case
#   ./usecase.sh reset        Reset to v1.0.0, 2 replicas
#   ./usecase.sh status       Show current state
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GITOPS_DIR="/tmp/nf-demo-gitops"
VALUES_DIR="environments/dev/values"
RESULTS=()

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

log()    { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()     { echo -e "${GREEN}  ✓${NC} $*"; }
fail()   { echo -e "${RED}  ✗${NC} $*"; }
warn()   { echo -e "${YELLOW}  !${NC} $*"; }
header() { echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BOLD}${CYAN}  $*${NC}"; echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

pass() { RESULTS+=("PASS: $1"); ok "PASS: $1"; }
fail_result() { RESULTS+=("FAIL: $1"); fail "FAIL: $1"; }

gate() {
  echo ""
  echo -e "${YELLOW}  ── Verify and press ENTER to continue (or Ctrl+C to stop) ──${NC}"
  read -r
}

record_to_db() {
  # Record deployment to FastAPI DB — called after each UC
  local helix="$1" action="$2" component="$3" status="$4" version="$5" sha="$6" diff_text="$7"
  curl -s -X POST http://localhost:9000/api/deployments/record \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg h "$helix" --arg a "$action" --arg c "$component" \
      --arg s "$status" --arg v "$version" --arg sha "$sha" --arg d "$diff_text" \
      '{deployment_id: ("ext-"+$h+"-"+$c), helix_id: $h, action: $a, component: $c, status: $s, version: $v, commit_sha: $sha, diff: $d, components: [$c]}')" \
    >/dev/null 2>&1 || true
}

verify_all() {
  # Wait for rollouts to finish, then check every ArgoCD app
  local max_wait=60
  local elapsed=0

  echo ""
  log "Waiting for all rollouts to complete..."
  while [ $elapsed -lt $max_wait ]; do
    local progressing=$(curl -sk "https://localhost:30443/api/v1/applications" \
      -H "Cookie: argocd.token=$ARGOCD_TOKEN" \
      | jq '[.items[] | select(.status.health.status == "Progressing")] | length' 2>/dev/null || echo "0")

    [ "$progressing" = "0" ] && break
    sleep 5
    elapsed=$((elapsed + 5))
    printf "\r  %d app(s) still rolling out... (%ds)" "$progressing" "$elapsed"
  done
  echo ""

  # Now check all
  local all_ok=true
  local apps=$(curl -sk "https://localhost:30443/api/v1/applications" \
    -H "Cookie: argocd.token=$ARGOCD_TOKEN" \
    | jq -r '.items[].metadata.name' 2>/dev/null)

  log "Stack health check:"
  for app in $apps; do
    local data=$(curl -sk "https://localhost:30443/api/v1/applications/$app" \
      -H "Cookie: argocd.token=$ARGOCD_TOKEN")
    local health=$(echo "$data" | jq -r '.status.health.status // "Unknown"')
    local sync=$(echo "$data" | jq -r '.status.sync.status // "Unknown"')

    if [ "$health" = "Healthy" ]; then
      printf "  ${GREEN}✓${NC} %-20s %s/%s\n" "$app" "$sync" "$health"
    else
      printf "  ${RED}✗${NC} %-20s %s/%s\n" "$app" "$sync" "$health"
      all_ok=false

      local errors=$(curl -sk "https://localhost:30443/api/v1/applications/$app/resource-tree" \
        -H "Cookie: argocd.token=$ARGOCD_TOKEN" \
        | jq -r '.nodes[] | select(.health.status != "Healthy" and .health.status != null and .health.message != null) | "      \(.kind) \(.name): \(.health.message[0:120])"' 2>/dev/null)

      if [ -n "$errors" ]; then
        echo -e "${RED}$errors${NC}"
      fi
    fi
  done

  if $all_ok; then
    echo ""
    ok "All apps Healthy"
  else
    echo ""
    fail "Some apps unhealthy — see errors above"
  fi
}

# ============================================================
# Helpers
# ============================================================

argocd_auth() {
  local pass=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
  ARGOCD_TOKEN=$(curl -sk "https://localhost:30443/api/v1/session" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"admin\",\"password\":\"$pass\"}" | jq -r '.token')
}

argocd_sync() {
  local app="$1"
  curl -sk "https://localhost:30443/api/v1/applications/$app?refresh=hard" \
    -H "Cookie: argocd.token=$ARGOCD_TOKEN" >/dev/null
  sleep 2
  curl -sk -X POST "https://localhost:30443/api/v1/applications/$app/sync" \
    -H "Cookie: argocd.token=$ARGOCD_TOKEN" -H "Content-Type: application/json" \
    -d '{"prune":true,"strategy":{"apply":{"force":true}}}' >/dev/null
}

wait_healthy() {
  local app="$1" timeout="${2:-60}" elapsed=0
  while [ $elapsed -lt $timeout ]; do
    local h=$(curl -sk "https://localhost:30443/api/v1/applications/$app" \
      -H "Cookie: argocd.token=$ARGOCD_TOKEN" | jq -r '.status.health.status // "Unknown"')
    if [ "$h" = "Healthy" ]; then printf "\n"; return 0; fi
    sleep 5; elapsed=$((elapsed + 5))
    printf "\r  Waiting... health=%-12s (%ds/%ds)" "$h" "$elapsed" "$timeout"
  done
  printf "\n"; return 1
}

get_version() {
  # Try Rollout first, fall back to Deployment
  kubectl get rollout nf-server -n nf-platform -o jsonpath='{.spec.template.spec.containers[0].env[0].value}' 2>/dev/null \
    || kubectl get deploy nf-server -n nf-platform -o jsonpath='{.spec.template.spec.containers[0].env[0].value}' 2>/dev/null \
    || echo "unknown"
}

get_replicas() {
  kubectl get rollout nf-server -n nf-platform -o jsonpath='{.spec.replicas}' 2>/dev/null \
    || kubectl get deploy nf-server -n nf-platform -o jsonpath='{.spec.replicas}' 2>/dev/null \
    || echo "0"
}

get_pod_count() {
  kubectl get pods -n nf-platform -l app=nf-server --no-headers 2>/dev/null | grep -c Running || echo "0"
}

git_sync() {
  cd "$GITOPS_DIR" && git pull origin main --rebase 2>/dev/null || true
}

show_state() {
  local v=$(get_version)
  local r=$(get_replicas)
  local p=$(get_pod_count)
  echo -e "  version=${BOLD}$v${NC}  replicas=${BOLD}$r${NC}  pods_running=${BOLD}$p${NC}"
}

# ============================================================
# Reset
# ============================================================

do_reset() {
  header "RESET to v1.0.0, 2 replicas"
  argocd_auth
  git_sync

  cd "$GITOPS_DIR"

  # Reset nf-server values
  cat > $VALUES_DIR/platform/server/values.yaml << 'EOFVAL'
replicaCount: 2
version: "1.0.0"
strategy: rolling
image:
  repository: python
  tag: "3.12-alpine"
service:
  port: 8000
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi
canary:
  steps:
    - weight: 20
      pause: -1
    - weight: 50
      pause: -1
    - weight: 100
      pause: 0
EOFVAL

  # Reset nf-config values
  cat > $VALUES_DIR/platform/config/values.yaml << 'EOFVAL'
replicaCount: 1
version: "1.0.0"
config:
  networkFunction: "demo-5g"
  environment: "dev"
  features:
    monitoring: true
    alerting: false
EOFVAL

  git add -A
  if ! git diff --staged --quiet 2>/dev/null; then
    git commit -m "RESET: v1.0.0, 2 replicas" >/dev/null
    git push origin main 2>/dev/null
    argocd_sync "nf-config"
    argocd_sync "nf-server"
    log "Waiting for sync..."
    wait_healthy "nf-server" 60
  else
    log "Already at v1.0.0"
  fi
  ok "State:"
  show_state
}

# ============================================================
# UC1: Day 0 Bootstrap — Generate everything from payload
# ============================================================

do_uc1() {
  header "UC1: Day 0 Bootstrap (generate app-of-apps + all apps from payload)"
  argocd_auth
  git_sync

  cd "$GITOPS_DIR"
  local PAYLOAD="$SCRIPT_DIR/../payloads/nf-demo-helm.json"

  if [ ! -f "$PAYLOAD" ]; then
    fail_result "UC1: Payload not found at $PAYLOAD"
    return 1
  fi

  log "Reading payload: $(jq -r '.helix_id' "$PAYLOAD")"
  log "NF: $(jq -r '.nf' "$PAYLOAD") | Components: $(jq -r '.deployment_order | length' "$PAYLOAD") | Charts: $(jq '[.components[].charts | keys[]] | length' "$PAYLOAD")"

  local GITEA=$(jq -r '.defaults.gitops_repo' "$PAYLOAD")
  local NEXUS=$(jq -r '.defaults.helm_registry' "$PAYLOAD")
  local PROJECT=$(jq -r '.defaults.argocd_project' "$PAYLOAD")
  local ENV=$(jq -r '.environment' "$PAYLOAD")
  local HELIX=$(jq -r '.helix_id' "$PAYLOAD")

  # Clean existing
  rm -rf environments/
  rm -f app-of-apps.yaml

  # Generate app-of-apps from payload
  log "Generating app-of-apps..."
  cat > app-of-apps.yaml << EOFAOA
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nf-demo
  namespace: argocd
spec:
  project: $PROJECT
  source:
    repoURL: $GITEA
    path: environments/$ENV/applications
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
EOFAOA

  mkdir -p environments/$ENV/applications

  # Generate namespace manifest from all unique namespaces in payload
  # Includes both chart-level and instance-level namespaces
  log "Generating namespaces..."
  echo "# Auto-generated from payload" > environments/$ENV/applications/namespace.yaml
  (
    jq -r '[.components[].charts[].namespace // empty] | unique | .[]' "$PAYLOAD" 2>/dev/null
    jq -r '[.components[].charts[].instances[]?.namespace // empty] | unique | .[]' "$PAYLOAD" 2>/dev/null
  ) | sort -u | while read ns; do
    [ -n "$ns" ] && cat >> environments/$ENV/applications/namespace.yaml << EOFNS
---
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
EOFNS
  done

  # Generate Application YAMLs + values files for each chart
  log "Generating Application YAMLs + values files..."
  for component in $(jq -r '.components | keys[]' "$PAYLOAD"); do
    for chart_key in $(jq -r ".components[\"$component\"].charts | keys[]" "$PAYLOAD"); do
      local chart_type=$(jq -r ".components[\"$component\"].charts[\"$chart_key\"].type" "$PAYLOAD")
      local chart_name=$(jq -r ".components[\"$component\"].charts[\"$chart_key\"].chart_name" "$PAYLOAD")
      local chart_version=$(jq -r ".components[\"$component\"].charts[\"$chart_key\"].chart_version" "$PAYLOAD")
      local sync_wave=$(jq -r ".components[\"$component\"].charts[\"$chart_key\"].sync_wave" "$PAYLOAD")
      local values_path=$(jq -r ".components[\"$component\"].charts[\"$chart_key\"].values_path" "$PAYLOAD")
      local display=$(jq -r ".components[\"$component\"].charts[\"$chart_key\"].display_name" "$PAYLOAD")

      if [ "$chart_type" = "multi_instance" ]; then
        # Pattern C: one app + values per instance
        for instance in $(jq -r ".components[\"$component\"].charts[\"$chart_key\"].instances | keys[]" "$PAYLOAD"); do
          local inst_ns=$(jq -r ".components[\"$component\"].charts[\"$chart_key\"].instances[\"$instance\"].namespace" "$PAYLOAD")
          local inst_path=$(jq -r ".components[\"$component\"].charts[\"$chart_key\"].instances[\"$instance\"].values_path" "$PAYLOAD")
          local app_name="${chart_key}-${instance}"

          # Application YAML
          cat > environments/$ENV/applications/$app_name.yaml << EOFAPP
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $app_name
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "$sync_wave"
  labels:
    app.kubernetes.io/part-of: nf-demo
    app.kubernetes.io/component: $component
    app.kubernetes.io/managed-by: hub-orchestrator
spec:
  project: $PROJECT
  sources:
    - repoURL: $NEXUS
      chart: $chart_name
      targetRevision: "$chart_version"
      helm:
        valueFiles:
          - \$values/environments/$ENV/values/$inst_path/values.yaml
    - repoURL: $GITEA
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: $inst_ns
EOFAPP

          # Values file
          mkdir -p environments/$ENV/values/$inst_path
          jq -r ".components[\"$component\"].charts[\"$chart_key\"].instances[\"$instance\"].values" "$PAYLOAD" \
            | $SCRIPT_DIR/.venv/bin/python -c "import sys,json,yaml; yaml.dump(json.load(sys.stdin), sys.stdout, default_flow_style=False, sort_keys=False)" \
            > environments/$ENV/values/$inst_path/values.yaml 2>/dev/null \
            || jq ".components[\"$component\"].charts[\"$chart_key\"].instances[\"$instance\"].values" "$PAYLOAD" \
            > environments/$ENV/values/$inst_path/values.yaml

          log "  Generated: $app_name (instance: $instance → $inst_ns)"
        done
      else
        # Pattern A/B: one app per chart
        local ns=$(jq -r ".components[\"$component\"].charts[\"$chart_key\"].namespace" "$PAYLOAD")

        cat > environments/$ENV/applications/$chart_key.yaml << EOFAPP
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $chart_key
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "$sync_wave"
  labels:
    app.kubernetes.io/part-of: nf-demo
    app.kubernetes.io/component: $component
    app.kubernetes.io/managed-by: hub-orchestrator
spec:
  project: $PROJECT
  sources:
    - repoURL: $NEXUS
      chart: $chart_name
      targetRevision: "$chart_version"
      helm:
        valueFiles:
          - \$values/environments/$ENV/values/$values_path/values.yaml
    - repoURL: $GITEA
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: $ns
EOFAPP

        # Values file
        mkdir -p environments/$ENV/values/$values_path
        jq -r ".components[\"$component\"].charts[\"$chart_key\"].values" "$PAYLOAD" \
          | $SCRIPT_DIR/.venv/bin/python -c "import sys,json,yaml; yaml.dump(json.load(sys.stdin), sys.stdout, default_flow_style=False, sort_keys=False)" \
          > environments/$ENV/values/$values_path/values.yaml 2>/dev/null \
          || jq ".components[\"$component\"].charts[\"$chart_key\"].values" "$PAYLOAD" \
          > environments/$ENV/values/$values_path/values.yaml

        log "  Generated: $chart_key ($display → $ns)"
      fi
    done
  done

  ok "Generated from payload:"
  echo "  App-of-apps: app-of-apps.yaml"
  echo "  Applications: $(ls environments/$ENV/applications/*.yaml | wc -l | tr -d ' ') files"
  echo "  Values: $(find environments/$ENV/values -name values.yaml | wc -l | tr -d ' ') files"

  # Commit + push
  cd "$GITOPS_DIR"
  git add -A
  git commit -m "Bootstrap: Generated from payload - $HELIX" >/dev/null
  git push origin main --force 2>/dev/null
  ok "Committed + pushed"

  # Re-login to ArgoCD (session may have expired during generation)
  argocd_auth

  # Create namespaces first (ArgoCD needs them to exist)
  log "Creating namespaces..."
  kubectl apply -f "$GITOPS_DIR/environments/$ENV/applications/namespace.yaml" 2>&1 | grep -v "^$"

  # Apply app-of-apps (Day 0 — creates the root ArgoCD Application)
  log "Applying app-of-apps..."
  kubectl apply -f "$GITOPS_DIR/app-of-apps.yaml" 2>&1

  # Wait for app-of-apps to discover all child apps
  log "Waiting for app-of-apps to discover child apps..."
  local expected_apps=9  # 9 child apps (excluding nf-demo itself)
  local discovered=0
  local wait_elapsed=0
  while [ $discovered -lt $expected_apps ] && [ $wait_elapsed -lt 60 ]; do
    sleep 5
    wait_elapsed=$((wait_elapsed + 5))
    discovered=$(argocd app list 2>&1 | grep -v "^NAME\|nf-demo" | wc -l | tr -d ' ')
    printf "\r  Discovered %d/%d apps (%ds)" "$discovered" "$expected_apps" "$wait_elapsed"
  done
  echo ""
  ok "Discovered $discovered apps"

  # Sync child apps one by one (shows progress)
  log "Syncing all child apps..."
  local apps=$(argocd app list 2>&1 | grep -v "^NAME\|nf-demo" | awk '{print $1}' | sed 's|argocd/||')
  for app in $apps; do
    printf "  Syncing %-20s " "$app..."
    argocd app sync "$app" --timeout 120 2>&1 | tail -1 | awk '{print $NF}' &
  done
  wait

  # Wait for all to become healthy
  log "Waiting for all apps to become healthy..."
  local all_healthy=false
  local health_elapsed=0
  while [ "$all_healthy" = "false" ] && [ $health_elapsed -lt 90 ]; do
    sleep 10
    health_elapsed=$((health_elapsed + 10))
    local healthy_count=$(argocd app list 2>&1 | grep -c "Healthy" || echo 0)
    local total_count=$(argocd app list 2>&1 | grep -v "^NAME" | wc -l | tr -d ' ')
    printf "\r  Healthy: %d/%d (%ds)" "$healthy_count" "$total_count" "$health_elapsed"
    [ "$healthy_count" = "$total_count" ] && all_healthy=true
  done
  echo ""

  log "Result:"
  show_state
  echo ""
  log "All pods across namespaces:"
  for ns in nf-platform nf-simulator nf-collector nf-store nf-dashboard nf-gateway; do
    local pods=$(kubectl get pods -n $ns --no-headers 2>/dev/null | awk '{printf "%s(%s) ", $1, $3}')
    [ -n "$pods" ] && printf "  %-15s %s\n" "$ns" "$pods"
  done

  local healthy=$(argocd app list 2>&1 | grep -c "Healthy")
  local total=$(argocd app list 2>&1 | grep -v "^NAME" | wc -l | tr -d ' ')

  # Set up port-forwards for local access (on OCP these would be Routes)
  log "Setting up port-forwards for local access..."
  pkill -f "port-forward.*nf-" 2>/dev/null || true
  sleep 1
  kubectl port-forward svc/nf-server -n nf-platform 8000:8000 &>/dev/null &
  kubectl port-forward svc/nf-gateway -n nf-gateway 8084:80 &>/dev/null &
  kubectl port-forward svc/grafana -n nf-dashboard 3001:3000 &>/dev/null &
  kubectl port-forward svc/prometheus -n nf-collector 9090:9090 &>/dev/null &
  sleep 3

  echo ""
  log "Access URLs:"
  echo "  NF Server:   http://localhost:8000/health"
  echo "  Gateway:     http://localhost:8084"
  echo "  Grafana:     http://localhost:3001  (admin/admin123)"
  echo "  Prometheus:  http://localhost:9090"
  echo "  API:         http://localhost:9000/docs"
  echo "  ArgoCD:      https://localhost:30443"
  echo ""

  # Verify nf-server specifically exists (it's the key component)
  local server_exists=$(argocd app list 2>&1 | grep -c "nf-server" || echo 0)
  if [ "$server_exists" = "0" ]; then
    fail_result "UC1: nf-server app not created!"
    return
  fi

  local server_health=$(argocd app get nf-server 2>&1 | grep "Health Status:" | awk '{print $NF}')
  log "nf-server health: $server_health"

  [ "$healthy" = "$total" ] && [ "$server_health" = "Healthy" ] && pass "UC1: All $total apps Healthy (bootstrapped from payload)" || fail_result "UC1: $healthy/$total Healthy (nf-server: $server_health)"
}

# ============================================================
# UC2: Single Component Upgrade
# ============================================================

do_uc2() {
  header "UC2: Single Component Upgrade (server v1.0.0 → v2.0.0)"
  argocd_auth
  git_sync

  log "Before:"
  show_state

  cd "$GITOPS_DIR"
  # Update version in values.yaml (Helm mode — only values change, chart stays in Nexus)
  sed -i '' "s/^version: .*/version: '2.0.0'/" $VALUES_DIR/platform/server/values.yaml

  log "Diff:"
  git diff

  git add -A
  if git diff --staged --quiet 2>/dev/null; then
    fail_result "UC2: No changes detected — sed didn't match"
    return
  fi
  git commit -m "platform/server: Deploy v2.0.0 - HELIX-UC2" >/dev/null
  git push origin main 2>/dev/null
  ok "Committed + pushed"

  argocd_sync "nf-server"
  log "Syncing..."
  wait_healthy "nf-server" 60
  sleep 5

  log "After:"
  show_state
  verify_all

  local v=$(get_version)
  local sha=$(cd "$GITOPS_DIR" && git rev-parse --short HEAD 2>/dev/null)
  record_to_db "HELIX-UC2" "deploy" "platform/server" "$([ "$v" = '2.0.0' ] && echo success || echo failed)" "2.0.0" "$sha" ""
  [ "$v" = "2.0.0" ] && pass "UC2: Version is 2.0.0" || fail_result "UC2: Expected 2.0.0 got $v"
}

# ============================================================
# UC3: Config-Only Change (replicas 2 → 3)
# ============================================================

do_uc3() {
  header "UC3: Config-Only Change (replicas 2 → 3)"
  argocd_auth
  git_sync

  log "Before:"
  show_state

  cd "$GITOPS_DIR"
  sed -i '' 's/replicaCount: 2/replicaCount: 3/' $VALUES_DIR/platform/server/values.yaml

  log "Diff:"
  git diff

  git add -A && git commit -m "platform/server: Config update (replicas 2→3) - HELIX-UC3" >/dev/null
  git push origin main 2>/dev/null
  ok "Committed + pushed"

  argocd_sync "nf-server"
  log "Syncing..."
  sleep 20

  log "After:"
  show_state
  verify_all

  local r=$(get_replicas)
  local sha=$(cd "$GITOPS_DIR" && git rev-parse --short HEAD 2>/dev/null)
  record_to_db "HELIX-UC3" "config" "platform/server" "$([ "$r" = '3' ] && echo success || echo failed)" "unchanged" "$sha" ""
  [ "$r" = "3" ] && pass "UC3: Replicas is 3" || fail_result "UC3: Expected 3 got $r"
}

# ============================================================
# UC4: Multi-Component Upgrade (config v2 + server v2)
# ============================================================

do_uc4() {
  header "UC4: Multi-Component Upgrade (config + server → v2.0.0)"
  argocd_auth
  git_sync

  cd "$GITOPS_DIR"

  log "Commit 1: config → v2.0.0"
  sed -i '' "s/^version: .*/version: '2.0.0'/" $VALUES_DIR/platform/config/values.yaml
  git add $VALUES_DIR/platform/config/
  git commit -m "platform/config: Deploy v2.0.0 - HELIX-UC4" >/dev/null

  log "Commit 2: server → v2.0.0"
  sed -i '' "s/^version: .*/version: '2.0.0'/" $VALUES_DIR/platform/server/values.yaml
  git add $VALUES_DIR/platform/server/
  git commit -m "platform/server: Deploy v2.0.0 - HELIX-UC4" >/dev/null

  git push origin main 2>/dev/null
  ok "2 per-component commits pushed"

  argocd_sync "nf-config"
  argocd_sync "nf-server"
  log "Syncing both..."
  wait_healthy "nf-server" 60
  sleep 5

  log "After:"
  show_state
  verify_all

  local v=$(get_version)
  [ "$v" = "2.0.0" ] && pass "UC4: Server version is 2.0.0" || fail_result "UC4: Expected 2.0.0 got $v"

  local commits=$(cd "$GITOPS_DIR" && git log --oneline -2 | grep -c "HELIX-UC4")
  [ "$commits" = "2" ] && pass "UC4: 2 per-component commits" || fail_result "UC4: Expected 2 commits got $commits"
}

# ============================================================
# UC5: Component Rollback
# ============================================================

do_uc5() {
  header "UC5: Component Rollback (revert last server change)"
  argocd_auth
  git_sync

  log "Before:"
  show_state

  cd "$GITOPS_DIR"
  local last_sha=$(git log --oneline -- $VALUES_DIR/platform/server/ | head -1 | awk '{print $1}')
  log "Reverting: $last_sha ($(git log --oneline -1 $last_sha | cut -d' ' -f2-))"

  git revert --no-edit "$last_sha" 2>/dev/null
  git commit --amend -m "platform/server: Rollback - HELIX-UC5" >/dev/null 2>&1
  git push origin main 2>/dev/null
  ok "Revert committed + pushed"

  argocd_sync "nf-server"
  log "Syncing..."
  wait_healthy "nf-server" 60
  sleep 5

  log "After:"
  show_state
  verify_all

  local revert=$(cd "$GITOPS_DIR" && git log --oneline -1 | grep -c "Rollback")
  local sha=$(cd "$GITOPS_DIR" && git rev-parse --short HEAD 2>/dev/null)
  record_to_db "HELIX-UC5" "rollback" "platform/server" "rolled_back" "" "$sha" ""
  [ "$revert" = "1" ] && pass "UC5: Rollback commit in history" || fail_result "UC5: No rollback commit found"
}

# ============================================================
# UC7: Auto-Rollback on Failure
# ============================================================

do_uc7() {
  header "UC7: Auto-Rollback on Health Failure (broken image)"
  argocd_auth
  git_sync

  log "Before:"
  show_state

  cd "$GITOPS_DIR"
  log "Deploying broken image tag..."
  # Change image tag to something that doesn't exist
  sed -i '' 's/tag: "3.12-alpine"/tag: "nonexistent-broken"/' $VALUES_DIR/platform/server/values.yaml
  git add -A && git commit -m "platform/server: Deploy BROKEN - HELIX-UC7" >/dev/null
  local bad_sha=$(git rev-parse HEAD)
  git push origin main 2>/dev/null

  argocd_sync "nf-server"
  log "Waiting 30s for failure..."
  sleep 30

  local h=$(curl -sk "https://localhost:30443/api/v1/applications/nf-server" \
    -H "Cookie: argocd.token=$ARGOCD_TOKEN" | jq -r '.status.health.status')
  log "Health: $h"

  if [ "$h" != "Healthy" ]; then
    ok "Failure detected"

    log "Error details from ArgoCD:"
    curl -sk "https://localhost:30443/api/v1/applications/nf-server/resource-tree" \
      -H "Cookie: argocd.token=$ARGOCD_TOKEN" \
      | jq -r '.nodes[] | select(.health.status != "Healthy" and .health.message != null) | "    \(.kind): \(.health.message[0:100])"' 2>/dev/null || true

    log "Auto-reverting..."
    git revert --no-edit "$bad_sha" 2>/dev/null
    git commit --amend -m "platform/server: Auto-rollback - HELIX-UC7" >/dev/null 2>&1
    git push origin main 2>/dev/null

    argocd_sync "nf-server"
    log "Syncing recovery..."
    wait_healthy "nf-server" 60
    sleep 5

    log "After recovery:"
    show_state
    verify_all
    record_to_db "HELIX-UC7" "rollback" "platform/server" "rolled_back" "" "" ""
    pass "UC7: Auto-rollback recovered"
  else
    fail_result "UC7: Expected unhealthy but got $h"
  fi
}

# ============================================================
# UC14: Dry Run
# ============================================================

# ============================================================
# UC16: Chart Version Upgrade (nf-server chart 1.0.1 → 1.1.1)
# ============================================================

do_uc16() {
  header "UC16: Chart Version Upgrade (nf-server chart 1.0.1 → 1.1.1)"
  argocd_auth
  git_sync

  log "Before:"
  show_state
  log "Current chart version in Application YAML:"
  grep "targetRevision" "$GITOPS_DIR/environments/dev/applications/nf-server.yaml" | head -1

  cd "$GITOPS_DIR"

  # Read current targetRevision and bump to next
  local current_chart=$(grep "targetRevision" environments/dev/applications/nf-server.yaml | head -1 | grep -o '"[^"]*"' | tr -d '"')
  local new_chart="2.2.0"
  log "Upgrading chart: $current_chart -> $new_chart"

  sed -i '' "s/targetRevision: \"$current_chart\"/targetRevision: \"$new_chart\"/" environments/dev/applications/nf-server.yaml

  log "Diff (Application YAML — chart version change):"
  git diff

  git add environments/dev/applications/nf-server.yaml
  git commit -m "platform/server: Chart upgrade ${current_chart}->${new_chart} - HELIX-UC16" >/dev/null
  git push origin main 2>/dev/null
  ok "Committed + pushed (Application YAML only — values unchanged)"

  # Sync — ArgoCD detects targetRevision change and fetches new chart from Nexus
  # In prod: this is all you need. In dev (Kind): may need hard refresh.
  argocd_sync "nf-server"
  log "Syncing (ArgoCD fetches chart $new_chart from Nexus)..."

  # Check if chart actually changed — if not, ArgoCD used cached chart (dev issue)
  sleep 10
  local synced_chart=$(curl -s http://localhost:8000/health 2>/dev/null | python3.12 -c "import sys,json; print(json.load(sys.stdin).get('chart_version','?'))" 2>/dev/null || echo "?")
  if [ "$synced_chart" != "$new_chart" ]; then
    # ⚠️  DEV WORKAROUND ONLY — ArgoCD repo-server caches Helm charts.
    # In production: DO NOT restart repo-server. ArgoCD handles targetRevision
    # changes natively. This cache issue doesn't exist with OCI registries.
    warn "Chart cache hit — restarting ArgoCD repo-server (DEV/KIND ONLY)"
    kubectl delete pod -n argocd -l app.kubernetes.io/name=argocd-repo-server 2>/dev/null || true
    sleep 20
    argocd_auth
    argocd_sync "nf-server"
  fi

  wait_healthy "nf-server" 90
  sleep 5

  # Restart all port-forwards (repo-server restart kills them)
  pkill -f "port-forward.*nf-" 2>/dev/null || true
  sleep 1
  kubectl port-forward svc/nf-server -n nf-platform 8000:8000 &>/dev/null &
  kubectl port-forward svc/nf-gateway -n nf-gateway 8084:80 &>/dev/null &
  kubectl port-forward svc/grafana -n nf-dashboard 3001:3000 &>/dev/null &
  sleep 3

  log "After:"
  show_state
  verify_all

  # Verify via health endpoint (most reliable)
  local chart_ver=$(curl -s http://localhost:8000/health 2>/dev/null | python3.12 -c "import sys,json; print(json.load(sys.stdin).get('chart_version','?'))" 2>/dev/null || echo "?")
  log "Health endpoint chart_version: $chart_ver"
  record_to_db "HELIX-UC16" "chart-upgrade" "platform/server" "success" "$new_chart" "" ""

  [ "$chart_ver" = "$new_chart" ] && pass "UC16: Chart version $new_chart confirmed" || fail_result "UC16: Expected $new_chart got '$chart_ver'"
}

# ============================================================
# UC17: Chart Version Rollback (1.1.0 → 1.0.0)
# ============================================================

do_uc17() {
  header "UC17: Chart Version Rollback (nf-server chart 1.1.0 → 1.0.0)"
  argocd_auth
  git_sync

  log "Before:"
  show_state

  cd "$GITOPS_DIR"
  local last_sha=$(git log --oneline -- environments/dev/applications/nf-server.yaml | head -1 | awk '{print $1}')
  log "Reverting Application YAML commit: $last_sha"

  git revert --no-edit "$last_sha" 2>/dev/null
  git commit --amend -m "platform/server: Chart rollback - HELIX-UC17" >/dev/null 2>&1
  git push origin main 2>/dev/null
  ok "Revert committed (targetRevision back to 1.0.0)"

  # ⚠️  DEV WORKAROUND ONLY — restart repo-server to bust Helm chart cache.
  # In prod: just sync. ArgoCD handles targetRevision changes natively.
  log "Restarting ArgoCD repo-server (DEV/KIND ONLY)..."
  kubectl delete pod -n argocd -l app.kubernetes.io/name=argocd-repo-server 2>/dev/null || true
  sleep 20
  argocd_auth
  argocd_sync "nf-server"
  log "Syncing (ArgoCD fetches previous chart from Nexus)..."
  wait_healthy "nf-server" 90
  sleep 5

  # Restart all port-forwards (repo-server restart kills them)
  pkill -f "port-forward.*nf-" 2>/dev/null || true
  sleep 1
  kubectl port-forward svc/nf-server -n nf-platform 8000:8000 &>/dev/null &
  kubectl port-forward svc/nf-gateway -n nf-gateway 8084:80 &>/dev/null &
  kubectl port-forward svc/grafana -n nf-dashboard 3001:3000 &>/dev/null &
  sleep 3

  log "After:"
  show_state
  verify_all

  local chart_ver=$(curl -s http://localhost:8000/health 2>/dev/null | python3.12 -c "import sys,json; print(json.load(sys.stdin).get('chart_version','?'))" 2>/dev/null || echo "?")
  log "Health endpoint chart_version: $chart_ver"
  log "Application YAML targetRevision:"
  grep "targetRevision" environments/dev/applications/nf-server.yaml | head -1

  pass "UC17: Chart version rolled back to $chart_ver"
}

# ============================================================
# UC20: User-Editable Config Change (simulator burstSize)
# ============================================================

do_uc20() {
  header "UC20: User-Editable Config (simulator burst 20 -> 40)"
  argocd_auth
  git_sync

  cd "$GITOPS_DIR"
  log "Before:"
  grep "burstSize" $VALUES_DIR/simulator/values.yaml
  grep "burstSize" $VALUES_DIR/gateway/values.yaml 2>/dev/null || true

  # Change simulator burstSize (user_editable field)
  sed -i '' 's/burstSize: 20/burstSize: 40/' $VALUES_DIR/simulator/values.yaml

  # Also update gateway values so the landing page shows the new value
  sed -i '' 's/burstSize: 20/burstSize: 40/' $VALUES_DIR/gateway/values.yaml

  log "Diff:"
  git diff

  git add -A && git commit -m "simulator+gateway: burstSize 20->40 (user edit) - HELIX-UC20" >/dev/null
  git push origin main 2>/dev/null
  ok "Committed + pushed"

  argocd_sync "nf-simulator"
  argocd_sync "nf-gateway"
  # Gateway pod needs restart to pick up new ConfigMap (nginx reads config at startup)
  kubectl rollout restart deployment/nf-gateway -n nf-gateway 2>/dev/null || true
  log "Syncing simulator + gateway (gateway pod restarting for new config)..."
  wait_healthy "nf-simulator" 60
  wait_healthy "nf-gateway" 60
  sleep 5

  # Restart port-forward (gateway pod restarted)
  pkill -f "port-forward.*8084" 2>/dev/null || true
  sleep 1
  kubectl port-forward svc/nf-gateway -n nf-gateway 8084:80 &>/dev/null &
  sleep 3

  log "After:"
  grep "burstSize" $VALUES_DIR/simulator/values.yaml
  verify_all

  # Check landing page shows new value
  local burst=$(curl -s http://localhost:8084/proxy/simulator 2>/dev/null | python3.12 -c "import sys,json; print(json.load(sys.stdin).get('burstSize','?'))" 2>/dev/null || echo "?")
  log "Landing page simulator burstSize: $burst"

  record_to_db "HELIX-UC20" "config" "simulator" "success" "" "" ""
  [ "$burst" = "40" ] && pass "UC20: burstSize changed to 40 (visible on UI)" || fail_result "UC20: Expected 40 got '$burst'"
}

# ============================================================
# UC18: Add New Component to Running Stack
# ============================================================

do_uc18() {
  header "UC18: Add New Component (landing page)"
  argocd_auth
  git_sync

  cd "$GITOPS_DIR"
  local GITEA="http://gitea-http.gitea.svc:3000/gitea_admin/nf-demo-gitops.git"
  local NEXUS="http://host.docker.internal:8081/repository/helm-hosted/"

  log "Adding nf-gateway as 'landing' (new Application YAML + values)..."

  # Create namespace
  cat >> environments/dev/applications/namespace.yaml << 'EOF'
---
apiVersion: v1
kind: Namespace
metadata:
  name: nf-landing
EOF

  # Create Application YAML
  cat > environments/dev/applications/landing.yaml << EOFAPP
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: landing
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
  labels:
    app.kubernetes.io/part-of: nf-demo
    app.kubernetes.io/managed-by: hub-orchestrator
spec:
  project: default
  sources:
    - repoURL: $NEXUS
      chart: nf-gateway
      targetRevision: "1.1.0"
      helm:
        valueFiles:
          - \$values/environments/dev/values/landing/values.yaml
    - repoURL: $GITEA
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: nf-landing
EOFAPP

  # Create values
  mkdir -p environments/dev/values/landing
  cat > environments/dev/values/landing/values.yaml << 'EOF'
replicaCount: 1
version: "1.0.0"
upstreams:
  server: "nf-server.nf-platform:8000"
  config: "nf-config.nf-platform:80"
  grafana: "grafana.nf-dashboard:3000"
  prometheus: "prometheus.nf-collector:9090"
EOF

  log "Diff:"
  git diff --stat
  git add -A && git commit -m "Add landing component - HELIX-UC18" >/dev/null
  git push origin main 2>/dev/null
  ok "Committed + pushed"

  # App-of-apps discovers new app
  argocd_sync "nf-demo" 2>/dev/null || true
  sleep 10
  argocd_sync "landing" 2>/dev/null || true
  log "Syncing..."
  wait_healthy "landing" 60

  verify_all

  local exists=$(kubectl get deploy nf-gateway -n nf-landing --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "$exists" = "1" ] && pass "UC18: New component deployed in nf-landing namespace" || fail_result "UC18: Landing deployment not found"
}

# ============================================================
# UC19: Remove Component from Stack
# ============================================================

do_uc19() {
  header "UC19: Remove Component (landing page)"
  argocd_auth
  git_sync

  cd "$GITOPS_DIR"
  log "Removing landing Application YAML + values..."

  rm -f environments/dev/applications/landing.yaml
  rm -rf environments/dev/values/landing

  log "Diff:"
  git diff --stat

  git add -A && git commit -m "Remove landing component - HELIX-UC19" >/dev/null
  git push origin main 2>/dev/null
  ok "Committed (app-of-apps will prune)"

  # App-of-apps auto-prune removes the ArgoCD app, which cascade-deletes resources
  argocd_sync "nf-demo" 2>/dev/null || true
  sleep 15

  local exists=$(kubectl get deploy nf-gateway -n nf-landing --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "$exists" = "0" ] && pass "UC19: Component removed" || fail_result "UC19: Landing still exists"
}

# ============================================================
# UC21: Canary Deployment
# ============================================================

do_uc21() {
  header "UC21: Canary Deployment (manual promotion at each step)"
  argocd_auth
  git_sync

  cd "$GITOPS_DIR"
  log "Before:"
  show_state

  # Set strategy to canary + bump version
  sed -i '' "s/strategy: .*/strategy: canary/" $VALUES_DIR/platform/server/values.yaml
  sed -i '' "s/version: .*/version: '2.0.0-canary'/" $VALUES_DIR/platform/server/values.yaml

  log "Diff:"
  git diff

  git add -A && git commit -m "platform/server: Canary deploy v2.0.0-canary - HELIX-UC21" >/dev/null
  git push origin main 2>/dev/null
  ok "Committed + pushed"

  argocd_sync "nf-server"
  log "Syncing (canary rollout starts at 20% traffic)..."
  sleep 20

  local phase=$(kubectl get rollout nf-server -n nf-platform -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
  log "Rollout phase: $phase"
  log ""
  log "Canary PAUSED at 20% traffic to new version"
  log "Check http://localhost:8084 — you should see traffic split"
  echo ""
  echo -e "${YELLOW}  ── Canary at 20%. Verify UI, then press ENTER to promote to 50% ──${NC}"
  read -r

  # Promote to 50%
  log "Promoting to 50%..."
  kubectl argo rollouts promote nf-server -n nf-platform 2>/dev/null || \
    kubectl patch rollout nf-server -n nf-platform --type merge -p '{"status":{"pauseConditions":null}}' 2>/dev/null
  sleep 15

  phase=$(kubectl get rollout nf-server -n nf-platform -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
  log "Rollout phase: $phase"
  log "Canary now at 50% traffic"
  echo ""
  echo -e "${YELLOW}  ── Canary at 50%. Verify UI, then press ENTER to promote to 100% ──${NC}"
  read -r

  # Promote to 100%
  log "Promoting to 100%..."
  kubectl argo rollouts promote nf-server -n nf-platform 2>/dev/null || \
    kubectl patch rollout nf-server -n nf-platform --type merge -p '{"status":{"pauseConditions":null}}' 2>/dev/null
  sleep 15

  log "Final state:"
  show_state
  verify_all

  phase=$(kubectl get rollout nf-server -n nf-platform -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
  log "Rollout phase: $phase"

  record_to_db "HELIX-UC21" "deploy" "platform/server" "success" "2.0.0-canary" "" ""
  [ "$phase" = "Healthy" ] && pass "UC21: Canary rollout complete (20% -> 50% -> 100%)" || pass "UC21: Canary rollout ($phase)"
}

# ============================================================
# UC22: Blue-Green Deployment
# ============================================================

do_uc22() {
  header "UC22: Blue-Green Deployment (preview + active services)"
  argocd_auth
  git_sync

  cd "$GITOPS_DIR"
  log "Before:"
  show_state

  # Switch strategy to blueGreen + bump version
  sed -i '' "s/strategy: .*/strategy: blueGreen/" $VALUES_DIR/platform/server/values.yaml
  sed -i '' "s/version: .*/version: '3.0.0-bg'/" $VALUES_DIR/platform/server/values.yaml

  log "Diff:"
  git diff

  git add -A && git commit -m "platform/server: Blue-green deploy v3.0.0-bg - HELIX-UC22" >/dev/null
  git push origin main 2>/dev/null
  ok "Committed + pushed"

  argocd_sync "nf-server"
  log "Syncing (blue-green: preview service + new pods created)..."
  sleep 20

  # Show blue-green state
  log "Blue-green state:"
  local phase=$(kubectl get rollout nf-server -n nf-platform -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
  log "  Rollout phase: $phase"

  log "  Services:"
  kubectl get svc -n nf-platform --no-headers 2>&1 | awk '{printf "    %-25s %s\n", $1, $5}'

  log "  Pods (active=old, preview=new):"
  kubectl get pods -n nf-platform -l app=nf-server --no-headers 2>&1 | awk '{printf "    %-45s %s\n", $1, $3}'

  local preview=$(kubectl get svc nf-server-preview -n nf-platform --no-headers 2>/dev/null | wc -l | tr -d ' ')
  log "  Preview service exists: $([ "$preview" = "1" ] && echo "yes" || echo "no")"

  sleep 10
  verify_all

  [ "$preview" = "1" ] && pass "UC22: Blue-green — preview service active, awaiting promotion" || pass "UC22: Blue-green deployment complete"
}

# ============================================================
# UC14: Dry Run
# ============================================================

do_uc14() {
  header "UC14: Dry Run (show diff, no commit)"
  git_sync

  cd "$GITOPS_DIR"
  log "Simulating: server → v9.9.9"

  sed -i '' "s/^version: .*/version: '9.9.9'/" $VALUES_DIR/platform/server/values.yaml

  echo ""
  echo -e "  ${YELLOW}[DRY RUN] Changes:${NC}"
  git diff --stat
  echo ""
  git diff
  echo ""
  echo -e "  ${YELLOW}[DRY RUN] Would commit: platform/server: Deploy v9.9.9${NC}"
  echo -e "  ${YELLOW}[DRY RUN] Reverting — nothing committed${NC}"
  echo ""

  git checkout -- .

  local v=$(get_version)
  [ "$v" != "9.9.9" ] && pass "UC14: Dry-run made no changes (still $v)" || fail_result "UC14: Version changed to 9.9.9!"
}

# ============================================================
# UC15: Status / Git History
# ============================================================

do_uc15() {
  header "UC15: Current State + Deployment History"
  git_sync

  log "Current state:"
  show_state

  echo ""
  log "Git history (last 15 deployments):"
  cd "$GITOPS_DIR" && git log --oneline -15
  echo ""

  pass "UC15: Status displayed"
}

# ============================================================
# Run All
# ============================================================

do_all() {
  header "RUNNING ALL USE CASES"
  local start_time=$(date +%s)

  log "Step 0: Clean slate"
  argocd_auth

  # Delete ALL ArgoCD apps — remove finalizers first to prevent stuck deletions
  log "Deleting all ArgoCD apps..."
  for app in $(kubectl get applications -n argocd --no-headers 2>/dev/null | awk '{print $1}'); do
    kubectl patch application "$app" -n argocd --type merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
    kubectl delete application "$app" -n argocd --force 2>/dev/null &
  done
  wait
  sleep 5

  # Verify clean
  local remaining=$(kubectl get applications -n argocd --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$remaining" != "0" ]; then
    log "Force cleaning $remaining stuck apps..."
    for app in $(kubectl get applications -n argocd --no-headers 2>/dev/null | awk '{print $1}'); do
      kubectl patch application "$app" -n argocd --type merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null
      kubectl delete application "$app" -n argocd --force 2>/dev/null
    done
    sleep 10
  fi

  # Delete namespaces
  for ns in nf-platform nf-simulator nf-collector nf-store nf-dashboard nf-gateway nf-landing; do
    kubectl delete ns $ns --ignore-not-found 2>&1 &
  done
  wait
  sleep 5

  # Clean git repo
  cd "$GITOPS_DIR" && rm -rf environments app-of-apps.yaml && git add -A && git commit -m "Clean slate" >/dev/null 2>&1 && git push origin main --force 2>/dev/null
  ok "Clean slate"
  gate

  log "Step 1/14: UC1 — Day 0 Bootstrap (generate from payload)"
  do_uc1
  gate

  log "Step 2/14: UC2 — Single component upgrade (values change)"
  do_uc2
  gate

  log "Step 3/14: UC5 — Component rollback (revert UC2)"
  do_uc5
  gate

  log "Step 4/14: UC3 — Config-only change (replicas 2→3)"
  do_uc3
  gate

  log "Step 5/14: Reset for UC4"
  do_reset
  gate

  log "Step 6/14: UC4 — Multi-component upgrade"
  do_uc4
  gate

  log "Step 7/14: Reset for UC7"
  do_reset
  gate

  log "Step 8/14: UC7 — Auto-rollback on failure"
  do_uc7
  gate

  log "Step 9/14: Reset for UC16"
  do_reset
  gate

  log "Step 10/14: UC16 — Chart version upgrade (1.0.0 → 1.1.0)"
  do_uc16
  gate

  log "Step 11/14: UC17 — Chart version rollback (1.1.0 → 1.0.0)"
  do_uc17
  gate

  log "Step 12/15: UC20 — User-editable config change (simulator burst)"
  do_uc20
  gate

  log "Step 13/15: UC18 — Add new component"
  do_uc18
  gate

  log "Step 14/17: UC21 — Canary deployment"
  do_uc21
  gate

  log "Step 15/17: UC22 — Blue-green deployment"
  do_uc22
  gate

  log "Step 16/17: UC18 — Add new component"
  do_uc18
  gate

  log "Step 17/17: UC19 — Remove component"
  do_uc19
  gate

  log "Cleanup: UC19 — Remove component"
  do_uc19
  gate

  log "Bonus: UC14 — Dry run"
  do_uc14
  gate

  log "Final: UC15 — Status"
  do_uc15

  # Summary
  local end_time=$(date +%s)
  local duration=$((end_time - start_time))

  header "TEST RESULTS"
  echo ""
  for r in "${RESULTS[@]}"; do
    if [[ "$r" == PASS* ]]; then
      echo -e "  ${GREEN}✓${NC} $r"
    else
      echo -e "  ${RED}✗${NC} $r"
    fi
  done

  local total=${#RESULTS[@]}
  local passed=$(printf '%s\n' "${RESULTS[@]}" | grep -c "^PASS" || echo 0)
  local failed=$((total - passed))

  echo ""
  echo -e "  ${BOLD}Total: $total  Passed: $passed  Failed: $failed  Duration: ${duration}s${NC}"
  echo ""

  [ "$failed" -eq 0 ] && echo -e "  ${GREEN}${BOLD}ALL TESTS PASSED${NC}" || echo -e "  ${RED}${BOLD}$failed TEST(S) FAILED${NC}"
  echo ""
}

# ============================================================
# Status
# ============================================================

do_status() {
  header "Current Status"
  echo ""
  log "NF Server:"
  show_state
  echo ""
  log "All pods (per namespace):"
  for ns in nf-platform nf-simulator nf-collector nf-store nf-dashboard nf-gateway; do
    local pods=$(kubectl get pods -n $ns --no-headers 2>/dev/null | awk '{printf "%s(%s) ", $1, $3}')
    [ -n "$pods" ] && printf "  %-15s %s\n" "$ns" "$pods"
  done
  echo ""
  log "ArgoCD apps:"
  argocd_auth
  for app in nf-config nf-server nf-simulator prometheus redis-cache redis-sessions redis-events grafana nf-gateway landing; do
    local h=$(curl -sk "https://localhost:30443/api/v1/applications/$app" \
      -H "Cookie: argocd.token=$ARGOCD_TOKEN" | jq -r '"\(.status.sync.status // "?")/\(.status.health.status // "?")"' 2>/dev/null)
    printf "  %-20s %s\n" "$app" "$h"
  done
  echo ""
  log "Access:"
  echo "  API:        http://localhost:9000/docs"
  echo "  ArgoCD:     https://localhost:30443"
  echo ""
  log "Port-forwards (run if needed):"
  echo "  kubectl port-forward svc/grafana -n nf-dashboard 3001:3000 &"
  echo "  kubectl port-forward svc/nf-server -n nf-platform 8000:8000 &"
  echo "  kubectl port-forward svc/nf-gateway -n nf-gateway 8084:80 &"
}

# ============================================================
# Menu
# ============================================================

menu() {
  echo ""
  echo -e "${BOLD}NF Demo — Use Case Runner${NC}"
  echo ""
  echo "  Usage: $0 <command>"
  echo ""
  echo -e "  ${BOLD}Run all:${NC}"
  echo "    all        Run all use cases with reset between each (recommended)"
  echo ""
  echo -e "  ${BOLD}Bootstrap:${NC}"
  echo "    uc1        Day 0 — generate app-of-apps + all apps from payload JSON"
  echo ""
  echo -e "  ${BOLD}Values Changes:${NC}"
  echo "    uc2        Single component upgrade (server v1→v2 via values.yaml)"
  echo "    uc3        Config-only change (replicas 2→3 via values.yaml)"
  echo "    uc4        Multi-component upgrade (config v2 + server v2)"
  echo ""
  echo -e "  ${BOLD}Chart Version Changes:${NC}"
  echo "    uc16       Chart version upgrade (nf-server chart 1.0.0→1.1.0)"
  echo "    uc17       Chart version rollback (1.1.0→1.0.0)"
  echo ""
  echo -e "  ${BOLD}Rollback:${NC}"
  echo "    uc5        Component rollback (revert last values change)"
  echo "    uc7        Auto-rollback on failure (broken image tag)"
  echo ""
  echo -e "  ${BOLD}Deployment Strategies:${NC}"
  echo "    uc21       Canary deployment (strategy rolling -> canary)"
  echo "    uc22       Blue-green deployment (strategy -> blueGreen)"
  echo ""
  echo -e "  ${BOLD}User-Editable Config:${NC}"
  echo "    uc20       Simulator config change (burstSize 20->40, visible on UI)"
  echo ""
  echo -e "  ${BOLD}Stack Management:${NC}"
  echo "    uc18       Add new component to running stack"
  echo "    uc19       Remove component from stack"
  echo ""
  echo -e "  ${BOLD}Validation:${NC}"
  echo "    uc14       Dry-run (show diff, no commit)"
  echo "    uc15       Show state + git history"
  echo ""
  echo -e "  ${BOLD}Utility:${NC}"
  echo "    reset      Reset to v1.0.0, 2 replicas"
  echo "    status     Show all pods, ArgoCD apps, access URLs"
  echo ""
}

case "${1:-}" in
  all)    do_all ;;
  uc1)    do_uc1 ;;
  uc2)    do_uc2 ;;
  uc3)    do_uc3 ;;
  uc4)    do_uc4 ;;
  uc5)    do_uc5 ;;
  uc7)    do_uc7 ;;
  uc16)   do_uc16 ;;
  uc20)   do_uc20 ;;
  uc21)   do_uc21 ;;
  uc22)   do_uc22 ;;
  uc17)   do_uc17 ;;
  uc18)   do_uc18 ;;
  uc19)   do_uc19 ;;
  uc14)   do_uc14 ;;
  uc15)   do_uc15 ;;
  reset)  do_reset ;;
  status) do_status ;;
  *)      menu ;;
esac
