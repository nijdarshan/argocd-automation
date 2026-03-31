"""
Deployment request/response models.

Design note: The request models are intentionally simple —
the frontend shouldn't need to know about ArgoCD, git, or sync-waves.
It just says "deploy this component to this version" and gets back a result.

The response models are richer — they include ArgoCD health, git SHAs,
and per-pod status. The Vue frontend can show as much or as little as it wants.
"""

from pydantic import BaseModel, Field
from datetime import datetime
from .common import DeploymentStatus, ComponentHealth, ComponentResult, HealthReport


# ── Deploy Requests ───────────────────────────────────────

class DeployComponentRequest(BaseModel):
    """Deploy a single component to a new version."""
    component: str = Field(..., example="platform/server", description="Component path in the GitOps repo")
    version: str = Field(..., example="2.0.0", description="Target version")
    helix_id: str = Field(..., example="HELIX-2001", description="Tracking ticket ID")

    class Config:
        json_schema_extra = {
            "example": {
                "component": "platform/server",
                "version": "2.0.0",
                "helix_id": "HELIX-2001"
            }
        }


class DeployConfigRequest(BaseModel):
    """Config-only change (replicas, settings) — no version bump."""
    component: str = Field(..., example="platform/server")
    changes: dict = Field(..., example={"replicas": 3}, description="Key-value pairs to change in the manifest")
    helix_id: str = Field(..., example="HELIX-3001")


class DeployFullRequest(BaseModel):
    """Full stack deployment from a payload JSON (Day 0 or re-deploy)."""
    payload_file: str = Field(..., example="payloads/nf-demo-deploy.json", description="Path to deployment payload JSON")
    helix_id: str = Field(..., example="HELIX-1001")
    auto_approve: bool = Field(False, description="Skip manual approval gates")
    dry_run: bool = Field(False, description="Validate + show diff, no commit or sync")


# ── Deploy Responses ──────────────────────────────────────

class DeployComponentResponse(BaseModel):
    """Result of a single component deployment."""
    status: ComponentHealth
    component: str
    version: str
    commit_sha: str | None = None
    health: str | None = None                 # "Healthy" / "Progressing" / "Degraded"
    health_report: HealthReport | None = None
    message: str | None = None


class DeployFullResponse(BaseModel):
    """Result of a full stack deployment."""
    deployment_id: str
    helix_id: str
    status: DeploymentStatus
    components: dict[str, ComponentResult] = {}
    started_at: datetime | None = None
    completed_at: datetime | None = None
    duration_seconds: int | None = None
    message: str | None = None


# ── Dry Run Response ──────────────────────────────────────

class DryRunResponse(BaseModel):
    """What would change without actually changing anything."""
    component: str
    version: str
    would_change: list[str] = []              # file paths that would be modified
    diff: str = ""                            # git diff output
    commit_message: str = ""                  # what the commit message would be
    committed: bool = False                   # always False for dry-run
