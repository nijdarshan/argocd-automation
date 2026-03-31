"""
Common enums and base models shared across all endpoints.

Design note: Pydantic models serve dual purpose —
1. Runtime validation (FastAPI rejects bad requests automatically)
2. OpenAPI schema generation (Vue team gets typed API client for free)

Every enum here becomes a dropdown in the Swagger UI at /docs.
"""

from enum import Enum
from pydantic import BaseModel
from datetime import datetime


# ── Status Enums ──────────────────────────────────────────
# These match the state machine from docs/handover/07-deployment-rollback.md

class DeploymentStatus(str, Enum):
    """Overall deployment lifecycle status."""
    PENDING = "pending"
    IN_PROGRESS = "in_progress"
    SUCCESS = "success"
    FAILED = "failed"
    ROLLED_BACK = "rolled_back"
    CANCELLED = "cancelled"


class ComponentHealth(str, Enum):
    """Per-component health derived from ArgoCD."""
    PENDING = "pending"
    IN_PROGRESS = "in_progress"
    SYNCED = "synced"
    HEALTHY = "healthy"
    UNHEALTHY = "unhealthy"
    ROLLED_BACK = "rolled_back"
    SKIPPED = "skipped"


class SyncStatus(str, Enum):
    """ArgoCD sync status."""
    SYNCED = "Synced"
    OUT_OF_SYNC = "OutOfSync"
    UNKNOWN = "Unknown"


class HealthStatus(str, Enum):
    """ArgoCD health status."""
    HEALTHY = "Healthy"
    PROGRESSING = "Progressing"
    DEGRADED = "Degraded"
    MISSING = "Missing"
    UNKNOWN = "Unknown"


# ── Shared Response Models ────────────────────────────────

class HealthReport(BaseModel):
    """Health details from ArgoCD resource-tree. No kubectl needed."""
    pods_ready: str = "0/0"           # "3/3"
    healthy_pods: int = 0
    total_pods: int = 0
    services_ready: str = "0/0"       # "1/1"
    errors: list[dict] = []           # [{kind, name, msg}] from unhealthy resources


class ComponentResult(BaseModel):
    """Result of deploying/rolling back a single component."""
    status: ComponentHealth
    commit_sha: str | None = None
    version: str | None = None
    deployed_at: datetime | None = None
    health_report: HealthReport | None = None
    error: str | None = None


class AppStatus(BaseModel):
    """ArgoCD application status — one per chart/instance."""
    name: str
    sync: SyncStatus
    health: HealthStatus
    pods_ready: str = "0/0"
    errors: list[dict] = []
