"""
Deploy routes.

Design note: Routes are thin — they validate the request (Pydantic does this),
call the service, and return the response. No business logic here.
"""

from fastapi import APIRouter
from ..models.deploy import (
    DeployComponentRequest, DeployComponentResponse,
    DeployConfigRequest, DryRunResponse,
)
from ..services.deployment import deployment_service

router = APIRouter(prefix="/api", tags=["Deploy"])


@router.post("/deploy/component", response_model=DeployComponentResponse)
async def deploy_component(req: DeployComponentRequest):
    """Deploy a single component to a new version."""
    return await deployment_service.deploy_component(
        component=req.component,
        version=req.version,
        helix_id=req.helix_id,
    )


@router.post("/deploy/config", response_model=DeployComponentResponse)
async def deploy_config(req: DeployConfigRequest):
    """Config-only change (replicas, settings) — no version bump."""
    return await deployment_service.deploy_config(
        component=req.component,
        changes=req.changes,
        helix_id=req.helix_id,
    )


@router.post("/dry-run", response_model=DryRunResponse)
async def dry_run(req: DeployComponentRequest):
    """Show what would change without committing or syncing."""
    return await deployment_service.dry_run(
        component=req.component,
        version=req.version,
    )
