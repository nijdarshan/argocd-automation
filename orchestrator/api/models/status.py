"""
Status and rollback models.

Design note: Status endpoints are the most-called endpoints —
the Vue frontend polls GET /api/status every few seconds.
Keep the response lean but complete.
"""

from pydantic import BaseModel, Field
from datetime import datetime
from .common import (
    DeploymentStatus, ComponentHealth, ComponentResult,
    AppStatus, HealthReport
)


# ── Status Responses ──────────────────────────────────────

class ComponentStatusResponse(BaseModel):
    """Detailed status of a single component — pods, version, health."""
    name: str
    health: str                               # "Healthy" / "Progressing" / "Degraded"
    version: str | None = None
    replicas: int | None = None
    image: str | None = None
    pods: list[dict] = []                     # [{name, health}]
    health_report: HealthReport | None = None
    argocd_apps: list[AppStatus] = []         # one per chart/instance


class StackStatusResponse(BaseModel):
    """Full stack status — all components, all ArgoCD apps."""
    status: DeploymentStatus = DeploymentStatus.PENDING
    deployed: list[str] = []
    current: str | None = None
    pending_approval: bool = False
    components: dict[str, ComponentStatusResponse] = {}
    total_pods: int = 0
    healthy_pods: int = 0
    last_deployment: str | None = None        # helix_id of last deployment
    last_updated: datetime | None = None


class GitLogEntry(BaseModel):
    """One line from git log — represents a deployment action."""
    sha: str
    message: str
    timestamp: datetime | None = None


class DeploymentHistoryResponse(BaseModel):
    """Git-based deployment history."""
    entries: list[GitLogEntry] = []
    total: int = 0


# ── Rollback Requests/Responses ───────────────────────────

class RollbackComponentRequest(BaseModel):
    """Rollback a single component by reverting its last git commit."""
    component: str = Field(..., example="platform/server")
    helix_id: str = Field(..., example="HELIX-5001")


class RollbackFullRequest(BaseModel):
    """Full stack rollback to a known-good state."""
    target_sha: str = Field(..., example="b8d43c4", description="Git SHA of the known-good state (from deployment history)")
    helix_id: str = Field(..., example="HELIX-6001")


class RollbackResponse(BaseModel):
    """Result of a rollback operation."""
    status: str                               # "rolled_back" / "failed"
    component: str | None = None              # null for full rollback
    reverted_commit: str | None = None
    rollback_commit: str | None = None
    health: str | None = None
    health_report: HealthReport | None = None
    message: str | None = None


# ── Approval ──────────────────────────────────────────────

class ApproveRequest(BaseModel):
    """Approve a paused deployment to continue."""
    approved_by: str = Field(..., example="darsh@vmo2.co.uk")
    notes: str = Field("", example="CMS replication verified")


class ApproveResponse(BaseModel):
    status: str = "approved"
    next_component: str | None = None
    message: str | None = None


# ── Diff ──────────────────────────────────────────────────

class DiffResponse(BaseModel):
    """Git diff of current uncommitted changes."""
    files_changed: list[str] = []
    diff: str = ""
    has_changes: bool = False
