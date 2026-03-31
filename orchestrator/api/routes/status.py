"""
Status and rollback routes.
"""

from fastapi import APIRouter
from ..models.status import (
    StackStatusResponse, ComponentStatusResponse,
    DeploymentHistoryResponse, DiffResponse,
    RollbackComponentRequest, RollbackFullRequest, RollbackResponse,
    ApproveRequest, ApproveResponse,
)
from ..services.deployment import deployment_service
from ..services.git import git_service
from ..services import db

router = APIRouter(prefix="/api", tags=["Status & Rollback"])


@router.get("/status", response_model=StackStatusResponse)
async def get_status():
    """Full stack status — all components, pods, health."""
    return await deployment_service.get_stack_status()


@router.get("/status/{app_name}", response_model=ComponentStatusResponse)
async def get_component_status(app_name: str):
    """Detailed status of a single component — version, replicas, pods."""
    return await deployment_service.get_component_status(app_name)


@router.get("/history", response_model=DeploymentHistoryResponse)
async def get_history(count: int = 15):
    """Deployment history from git log."""
    return await deployment_service.get_history(count)


@router.get("/diff", response_model=DiffResponse)
async def get_diff():
    """Preview uncommitted changes in the GitOps repo."""
    git_service.ensure_cloned()
    diff = git_service.diff()
    stat = git_service.diff_stat()
    files = [l.split("|")[0].strip() for l in stat.splitlines() if "|" in l]
    return DiffResponse(
        files_changed=files,
        diff=diff,
        has_changes=len(diff) > 0,
    )


@router.post("/rollback/component", response_model=RollbackResponse)
async def rollback_component(req: RollbackComponentRequest):
    """Rollback a single component by reverting its last git commit."""
    return await deployment_service.rollback_component(
        component=req.component,
        helix_id=req.helix_id,
    )


@router.post("/approve", response_model=ApproveResponse)
async def approve(req: ApproveRequest):
    """Approve a paused deployment to continue."""
    return ApproveResponse(
        status="approved",
        message=f"Approved by {req.approved_by}: {req.notes}",
    )


# ── Deployment Records (DB) ──────────────────────────────

@router.get("/deployments")
async def list_deployments(nf: str = None, environment: str = None, limit: int = 20):
    """List past deployments from DB."""
    return await db.get_deployments(nf=nf, environment=environment, limit=limit)


@router.get("/deployments/latest")
async def latest_deployment(nf: str = "nf-demo", environment: str = "dev"):
    """Most recent deployment."""
    return await db.get_latest_deployment(nf=nf, environment=environment)


@router.get("/deployments/{deployment_id}")
async def get_deployment(deployment_id: str):
    """Single deployment with component results and diff."""
    result = await db.get_deployment(deployment_id)
    if not result:
        return {"error": "not found"}
    result["diffs"] = await db.get_diff(deployment_id)
    return result


@router.post("/deployments/record")
async def record_deployment(data: dict):
    """Record a deployment from external source (CLI, pipeline).
    Used by usecase.sh to write to DB without going through the full deploy flow."""
    dep_id = data.get("deployment_id", f"ext-{data.get('helix_id','?')}")
    await db.create_deployment(
        dep_id,
        data.get("helix_id", "?"),
        data.get("action", "deploy"),
        data.get("environment", "dev"),
        data.get("nf", "nf-demo"),
        data.get("components", [])
    )
    if data.get("component"):
        await db.record_component_result(
            dep_id,
            data["component"],
            data.get("status", "unknown"),
            data.get("version"),
            data.get("commit_sha"),
            data.get("health"),
            data.get("health_report"),
            data.get("error")
        )
    if data.get("diff"):
        await db.store_diff(dep_id, data.get("component", "?"), data["diff"], data.get("files", []))
    await db.update_deployment_status(dep_id, data.get("status", "unknown"))
    return {"recorded": dep_id}
