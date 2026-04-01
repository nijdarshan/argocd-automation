"""
Deployment orchestration service — Helm multi-source mode.

Design: The orchestrator changes values.yaml files in the GitOps repo.
Charts stay in Nexus. ArgoCD merges chart + values on sync.

Deploy flow:
  1. Read current values.yaml
  2. Merge with requested changes (version, replicas, etc.)
  3. Write updated values.yaml
  4. Git commit + push
  5. ArgoCD sync (hard refresh + sync)
  6. Wait healthy
  7. Return result
"""

import yaml
import re
import copy
from datetime import datetime
from ..config import settings
from ..models.common import ComponentHealth, HealthReport
from ..models.deploy import DeployComponentResponse, DryRunResponse
from ..models.status import (
    ComponentStatusResponse, StackStatusResponse, RollbackResponse,
    DeploymentHistoryResponse, GitLogEntry,
)
from .argocd import argo_service
from .git import git_service
from . import db


class DeploymentService:

    # ── Deploy ────────────────────────────────────────────

    async def deploy_component(self, component: str, version: str, helix_id: str) -> DeployComponentResponse:
        """
        Deploy a component by updating its values.yaml.
        Only values change — chart stays in Nexus.
        """
        git_service.ensure_cloned()
        app_name = self._component_to_app(component)
        values_path = f"environments/dev/values/{component}/values.yaml"
        deployment_id = f"deploy-{helix_id}-{component.replace('/', '-')}"

        # Create DB record
        await db.create_deployment(deployment_id, helix_id, "deploy", "dev", "nf-demo", [component])

        # Read current values
        current_yaml = git_service.get_file(values_path)
        if not current_yaml:
            await db.update_deployment_status(deployment_id, "failed")
            return DeployComponentResponse(
                status=ComponentHealth.UNHEALTHY,
                component=component,
                version=version,
                message=f"Values file not found: {values_path}"
            )

        current = yaml.safe_load(current_yaml)

        # Update version fields
        if "version" in current:
            current["version"] = version

        # Write back
        new_yaml = yaml.dump(current, default_flow_style=False, sort_keys=False)
        git_service.write_file(values_path, new_yaml)

        # Capture diff before commit
        diff = git_service.diff()
        diff_stat = git_service.diff_stat()
        files = [l.split("|")[0].strip() for l in diff_stat.splitlines() if "|" in l]

        # Commit
        commit_msg = f"{component}: Deploy v{version} - {helix_id}"
        sha = git_service.commit_and_push(commit_msg)

        if not sha:
            await db.update_deployment_status(deployment_id, "skipped")
            return DeployComponentResponse(
                status=ComponentHealth.SKIPPED,
                component=component,
                version=version,
                message="No changes — already at this version"
            )

        # Store diff
        await db.store_diff(deployment_id, component, diff, files)

        # Sync
        await argo_service.sync_app(app_name)
        is_healthy = await argo_service.wait_healthy(app_name, timeout=60)
        health_report = await argo_service.get_health_report(app_name)

        # Record result
        status = ComponentHealth.HEALTHY if is_healthy else ComponentHealth.UNHEALTHY
        await db.record_component_result(
            deployment_id, component, status.value, version, sha,
            "Healthy" if is_healthy else "Unhealthy",
            health_report.model_dump() if health_report else None
        )
        await db.update_deployment_status(deployment_id, "success" if is_healthy else "failed")

        return DeployComponentResponse(
            status=status,
            component=component,
            version=version,
            commit_sha=sha,
            health="Healthy" if is_healthy else "Unhealthy",
            health_report=health_report,
        )

    async def deploy_config(self, component: str, changes: dict, helix_id: str) -> DeployComponentResponse:
        """
        Config-only change — update specific fields in values.yaml.
        Example: {"replicaCount": 3} or {"config.features.alerting": true}
        """
        git_service.ensure_cloned()
        app_name = self._component_to_app(component)
        values_path = f"environments/dev/values/{component}/values.yaml"
        deployment_id = f"config-{helix_id}-{component.replace('/', '-')}"

        await db.create_deployment(deployment_id, helix_id, "config", "dev", "nf-demo", [component])

        current_yaml = git_service.get_file(values_path)
        if not current_yaml:
            await db.update_deployment_status(deployment_id, "failed")
            return DeployComponentResponse(
                status=ComponentHealth.UNHEALTHY,
                component=component,
                version="unchanged",
                message=f"Values file not found: {values_path}"
            )

        current = yaml.safe_load(current_yaml)

        for key, value in changes.items():
            self._set_nested(current, key, value)

        new_yaml = yaml.dump(current, default_flow_style=False, sort_keys=False)
        git_service.write_file(values_path, new_yaml)

        diff = git_service.diff()
        diff_stat = git_service.diff_stat()
        files = [l.split("|")[0].strip() for l in diff_stat.splitlines() if "|" in l]

        change_desc = ", ".join(f"{k}={v}" for k, v in changes.items())
        sha = git_service.commit_and_push(f"{component}: Config update ({change_desc}) - {helix_id}")

        if not sha:
            await db.update_deployment_status(deployment_id, "skipped")
            return DeployComponentResponse(
                status=ComponentHealth.SKIPPED,
                component=component,
                version="unchanged",
                message="No changes detected"
            )

        await db.store_diff(deployment_id, component, diff, files)

        await argo_service.sync_app(app_name)
        is_healthy = await argo_service.wait_healthy(app_name, timeout=60)
        health_report = await argo_service.get_health_report(app_name)

        status = ComponentHealth.HEALTHY if is_healthy else ComponentHealth.UNHEALTHY
        await db.record_component_result(
            deployment_id, component, status.value, "unchanged", sha,
            "Healthy" if is_healthy else "Unhealthy",
            health_report.model_dump() if health_report else None
        )
        await db.update_deployment_status(deployment_id, "success" if is_healthy else "failed")

        return DeployComponentResponse(
            status=status,
            component=component,
            version="unchanged",
            commit_sha=sha,
            health="Healthy" if is_healthy else "Unhealthy",
            health_report=health_report,
        )

    # ── Dry Run ───────────────────────────────────────────

    async def dry_run(self, component: str, version: str) -> DryRunResponse:
        """Show what values.yaml would change without committing."""
        git_service.ensure_cloned()
        values_path = f"environments/dev/values/{component}/values.yaml"

        current_yaml = git_service.get_file(values_path)
        current = yaml.safe_load(current_yaml) if current_yaml else {}

        modified = copy.deepcopy(current)
        if "version" in modified:
            modified["version"] = version

        git_service.write_file(values_path, yaml.dump(modified, default_flow_style=False, sort_keys=False))

        diff = git_service.diff()
        stat = git_service.diff_stat()

        # Revert
        git_service._run("checkout", "--", ".")

        files = [l.split("|")[0].strip() for l in stat.splitlines() if "|" in l]

        return DryRunResponse(
            component=component,
            version=version,
            would_change=files,
            diff=diff,
            commit_message=f"{component}: Deploy v{version} - DRY-RUN",
            committed=False,
        )

    # ── Rollback ──────────────────────────────────────────

    async def rollback_component(self, component: str, helix_id: str) -> RollbackResponse:
        """Rollback by reverting the last commit that touched this component's values."""
        git_service.ensure_cloned()
        app_name = self._component_to_app(component)
        values_path = f"environments/dev/values/{component}/"
        deployment_id = f"rollback-{helix_id}-{component.replace('/', '-')}"

        await db.create_deployment(deployment_id, helix_id, "rollback", "dev", "nf-demo", [component])

        last = git_service.last_commit_for_path(values_path)
        if not last:
            await db.update_deployment_status(deployment_id, "failed")
            return RollbackResponse(
                status="failed",
                component=component,
                message="No commits found for this component"
            )

        rollback_sha = git_service.revert_commit(
            last["sha"],
            f"{component}: Rollback - {helix_id}"
        )

        await argo_service.sync_app(app_name, force=True, is_rollback=True)
        is_healthy = await argo_service.wait_healthy(app_name, timeout=60)
        health_report = await argo_service.get_health_report(app_name)

        rb_status = "rolled_back" if is_healthy else "failed"
        await db.record_component_result(
            deployment_id, component, rb_status, None, rollback_sha,
            "Healthy" if is_healthy else "Unhealthy",
            health_report.model_dump() if health_report else None
        )
        await db.update_deployment_status(deployment_id, rb_status)

        return RollbackResponse(
            status="rolled_back" if is_healthy else "failed",
            component=component,
            reverted_commit=last["sha"],
            rollback_commit=rollback_sha,
            health="Healthy" if is_healthy else "Unhealthy",
            health_report=health_report,
        )

    # ── Status ────────────────────────────────────────────

    async def get_component_status(self, app_name: str) -> ComponentStatusResponse:
        """Full status from ArgoCD API — version, replicas, pods, health."""
        health = await argo_service.get_app_health(app_name)
        report = await argo_service.get_health_report(app_name)

        # Find namespace for this app
        ns = None
        resource_name = app_name
        for comp, info in self.COMPONENT_MAP.items():
            if info["app"] == app_name:
                ns = info["namespace"]
                resource_name = info["resource"]
                break

        version = None
        replicas = None
        image = None
        try:
            live = await argo_service.get_live_resource(app_name, resource_name, namespace=ns)
            spec = live.get("spec", {})
            replicas = spec.get("replicas")
            containers = spec.get("template", {}).get("spec", {}).get("containers", [])
            if containers:
                image = containers[0].get("image")
                for env in containers[0].get("env", []):
                    if env.get("name") == "APP_VERSION":
                        version = env.get("value")
        except Exception:
            pass

        pods = []
        try:
            pods = [
                {"name": n.get("name", ""), "health": n.get("health", {}).get("status", "Unknown")}
                for n in (await self._get_tree_nodes(app_name))
                if n.get("kind") == "Pod"
            ]
        except Exception:
            pass

        return ComponentStatusResponse(
            name=app_name,
            health=health.get("health", "Unknown"),
            version=version,
            replicas=replicas,
            image=image,
            pods=pods,
            health_report=report,
        )

    async def get_stack_status(self) -> StackStatusResponse:
        """All apps status — single ArgoCD list call + per-app health."""
        apps = await argo_service.list_apps()

        components = {}
        total_pods = 0
        healthy_pods = 0

        for app in apps:
            if app.name == "nf-demo":
                continue
            try:
                report = await argo_service.get_health_report(app.name)
                total_pods += report.total_pods
                healthy_pods += report.healthy_pods
            except Exception:
                report = HealthReport()

            components[app.name] = ComponentStatusResponse(
                name=app.name,
                health=app.health.value,
                health_report=report,
            )

        return StackStatusResponse(
            status="success" if all(
                a.health.value == "Healthy" for a in apps if a.name != "nf-demo"
            ) else "in_progress",
            components=components,
            total_pods=total_pods,
            healthy_pods=healthy_pods,
            last_updated=datetime.utcnow(),
        )

    async def get_history(self, count: int = 15) -> DeploymentHistoryResponse:
        git_service.ensure_cloned()
        entries = git_service.log(count)
        return DeploymentHistoryResponse(
            entries=[GitLogEntry(sha=e["sha"], message=e["message"]) for e in entries],
            total=len(entries),
        )

    # ── Helpers ────────────────────────────────────────────

    # Component registry: maps values path → ArgoCD app name + namespace
    COMPONENT_MAP = {
        "platform/server":  {"app": "nf-server",       "namespace": "nf-platform",  "resource": "nf-server"},
        "platform/config":  {"app": "nf-config",       "namespace": "nf-platform",  "resource": "nf-config"},
        "simulator":        {"app": "nf-simulator",    "namespace": "nf-simulator", "resource": "nf-simulator"},
        "collector":        {"app": "prometheus",      "namespace": "nf-collector", "resource": "prometheus"},
        "store/cache":      {"app": "redis-cache",     "namespace": "nf-store",     "resource": "redis-cache"},
        "store/sessions":   {"app": "redis-sessions",  "namespace": "nf-store",     "resource": "redis-sessions"},
        "store/events":     {"app": "redis-events",    "namespace": "nf-store",     "resource": "redis-events"},
        "dashboard":        {"app": "grafana",         "namespace": "nf-dashboard", "resource": "grafana"},
        "gateway":          {"app": "nf-gateway",      "namespace": "nf-gateway",   "resource": "nf-gateway"},
    }

    def _component_to_app(self, component: str) -> str:
        return self.COMPONENT_MAP.get(component, {}).get("app", component)

    def _component_to_namespace(self, component: str) -> str:
        return self.COMPONENT_MAP.get(component, {}).get("namespace", "default")

    def _component_to_resource(self, component: str) -> str:
        return self.COMPONENT_MAP.get(component, {}).get("resource", component)

    def _set_nested(self, d: dict, key: str, value):
        """Set a nested dict value using dot notation: 'config.features.alerting' = true"""
        keys = key.split(".")
        for k in keys[:-1]:
            d = d.setdefault(k, {})
        d[keys[-1]] = value

    async def _get_tree_nodes(self, app_name: str) -> list:
        async with await argo_service._get_client() as client:
            resp = await client.get(
                f"{argo_service.base_url}/applications/{app_name}/resource-tree",
                headers=argo_service._headers()
            )
            return resp.json().get("nodes", [])


deployment_service = DeploymentService()
