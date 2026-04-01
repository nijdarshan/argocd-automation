"""
ArgoCD REST API service.

Design note: This is an async HTTP client wrapping the ArgoCD API.
Every method maps to one ArgoCD API call we tested in the shell.
The service handles auth (session token) and returns parsed data.

The deployment service calls this — routes never call ArgoCD directly.
"""

import httpx
import asyncio
from ..config import settings
from ..models.common import AppStatus, HealthReport, SyncStatus, HealthStatus


class ArgoService:
    def __init__(self):
        self.base_url = f"{settings.argocd_url}/api/v1"
        self.token: str | None = None

    async def _get_client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(
            verify=not settings.argocd_insecure,
            timeout=30.0
        )

    async def authenticate(self) -> str:
        """Get session token. ArgoCD uses cookie-based auth."""
        # Get password from K8s secret (in prod, from Vault)
        import subprocess
        password = subprocess.run(
            ["kubectl", "-n", "argocd", "get", "secret",
             "argocd-initial-admin-secret", "-o", "jsonpath={.data.password}"],
            capture_output=True, text=True
        ).stdout
        import base64
        password = base64.b64decode(password).decode()

        async with await self._get_client() as client:
            resp = await client.post(
                f"{self.base_url}/session",
                json={"username": settings.argocd_username, "password": password}
            )
            self.token = resp.json().get("token")
            return self.token

    def _headers(self) -> dict:
        return {"Cookie": f"argocd.token={self.token}"}

    # ── Read Operations ───────────────────────────────────

    async def list_apps(self) -> list[AppStatus]:
        """List all ArgoCD applications with sync + health status."""
        async with await self._get_client() as client:
            resp = await client.get(f"{self.base_url}/applications", headers=self._headers())
            items = resp.json().get("items") or []
            return [
                AppStatus(
                    name=app["metadata"]["name"],
                    sync=SyncStatus(app.get("status", {}).get("sync", {}).get("status", "Unknown")),
                    health=HealthStatus(app.get("status", {}).get("health", {}).get("status", "Unknown")),
                )
                for app in items
            ]

    async def get_app_health(self, app_name: str) -> dict:
        """Get app sync + health status."""
        async with await self._get_client() as client:
            resp = await client.get(
                f"{self.base_url}/applications/{app_name}",
                headers=self._headers()
            )
            data = resp.json()
            status = data.get("status", {})
            return {
                "sync": status.get("sync", {}).get("status", "Unknown"),
                "health": status.get("health", {}).get("status", "Unknown"),
                "revision": status.get("sync", {}).get("revision", "")[:8],
            }

    async def get_health_report(self, app_name: str) -> HealthReport:
        """Get detailed health from resource-tree: pods, services, errors."""
        async with await self._get_client() as client:
            resp = await client.get(
                f"{self.base_url}/applications/{app_name}/resource-tree",
                headers=self._headers()
            )
            nodes = resp.json().get("nodes", [])

            pods = [n for n in nodes if n.get("kind") == "Pod"]
            healthy_pods = [p for p in pods if p.get("health", {}).get("status") == "Healthy"]
            svcs = [n for n in nodes if n.get("kind") == "Service"]
            healthy_svcs = [s for s in svcs if s.get("health", {}).get("status") == "Healthy"]

            errors = [
                {"kind": n["kind"], "name": n.get("name", ""), "msg": n["health"]["message"][:200]}
                for n in nodes
                if n.get("health", {}).get("status") not in ("Healthy", None)
                and n.get("health", {}).get("message")
            ]

            return HealthReport(
                pods_ready=f"{len(healthy_pods)}/{len(pods)}",
                healthy_pods=len(healthy_pods),
                total_pods=len(pods),
                services_ready=f"{len(healthy_svcs)}/{len(svcs)}",
                errors=errors,
            )

    async def get_live_resource(self, app_name: str, resource_name: str,
                                 kind: str = "Deployment", namespace: str = None) -> dict:
        """Get live K8s resource spec from ArgoCD (no kubectl needed)."""
        ns = namespace or settings.namespace
        async with await self._get_client() as client:
            resp = await client.get(
                f"{self.base_url}/applications/{app_name}/resource",
                params={
                    "resourceName": resource_name,
                    "kind": kind,
                    "namespace": ns,
                    "group": "apps",
                    "version": "v1",
                },
                headers=self._headers()
            )
            data = resp.json()
            if "manifest" in data:
                import json
                return json.loads(data["manifest"])
            return data

    # ── Write Operations ──────────────────────────────────

    async def sync_app(self, app_name: str, force: bool = False,
                       chart_version_changed: bool = False,
                       is_rollback: bool = False) -> dict:
        """
        Trigger ArgoCD sync.

        Three modes based on operation type:

        NORMAL DEPLOY (values change, same chart):
          - No hard refresh (ArgoCD detects Git change on sync)
          - force=False (patch, not replace)
          - Safest for prod — minimal disruption

        CHART VERSION UPGRADE:
          - Normal refresh (nudge ArgoCD to re-read Git)
          - force=False
          - targetRevision change in Application YAML triggers chart re-fetch
          - DO NOT delete+recreate in prod (kills pods)

        ROLLBACK (emergency):
          - Hard refresh (need fresh state immediately)
          - force=True (override any drift)
          - Justified because it's recovery from a failure

        In local/dev: we use hard refresh + force for speed.
        In prod: use the appropriate mode.
        """
        async with await self._get_client() as client:
            if is_rollback:
                # Emergency: hard refresh + force
                refresh_type = "hard"
                apply_force = True
            elif chart_version_changed:
                # Chart upgrade: normal refresh, no force
                refresh_type = "normal"
                apply_force = False
            else:
                # Values-only: normal refresh, no force
                refresh_type = "normal"
                apply_force = force

            # Dev/local override: hard refresh for speed (caching issues on Kind)
            # In prod, remove this block — normal refresh + force=false is correct
            if settings.argocd_insecure:  # local dev only
                refresh_type = "hard"
                # force stays as-is (false for deploys, true for rollback)

            await client.get(
                f"{self.base_url}/applications/{app_name}?refresh={refresh_type}",
                headers=self._headers()
            )
            await asyncio.sleep(3 if refresh_type == "hard" else 1)

            resp = await client.post(
                f"{self.base_url}/applications/{app_name}/sync",
                headers=self._headers(),
                json={
                    "prune": True,
                    "strategy": {"apply": {"force": apply_force}}
                }
            )
            return resp.json()

    async def create_app(self, app_spec: dict) -> dict:
        """Create an ArgoCD Application."""
        async with await self._get_client() as client:
            resp = await client.post(
                f"{self.base_url}/applications",
                headers=self._headers(),
                json=app_spec
            )
            return resp.json()

    async def wait_healthy(self, app_name: str, timeout: int = 60) -> bool:
        """Poll until app is Synced + Healthy, or timeout."""
        elapsed = 0
        while elapsed < timeout:
            status = await self.get_app_health(app_name)
            if status["sync"] == "Synced" and status["health"] == "Healthy":
                return True
            if status["health"] == "Degraded":
                return False
            await asyncio.sleep(5)
            elapsed += 5
        return False


# Singleton
argo_service = ArgoService()
