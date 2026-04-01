"""
Hub Orchestrator API — FastAPI application.

Design note: This is the single entry point. It:
1. Registers all route modules
2. Sets up CORS (so Vue frontend on a different port can call it)
3. Authenticates to ArgoCD on startup
4. Serves OpenAPI docs at /docs (Vue team imports this)

Run: uvicorn api.app:app --reload --port 9000
Docs: http://localhost:9000/docs
"""

from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from .routes.deploy import router as deploy_router
from .routes.status import router as status_router
from .services.argocd import argo_service
from .services.git import git_service
from .services.db import init_db


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup: init DB, authenticate to ArgoCD, clone git repo."""
    await init_db()
    print("Database initialized")

    try:
        await argo_service.authenticate()
        print("ArgoCD authenticated")
    except Exception as e:
        print(f"ArgoCD auth failed (will retry on first request): {e}")

    try:
        git_service.ensure_cloned()
        print(f"Git repo ready at {git_service.repo_path}")
    except Exception as e:
        print(f"Git clone failed: {e}")

    yield  # app runs
    print("Shutting down")


app = FastAPI(
    title="Hub Orchestrator API",
    description="Deployment orchestration for CNF applications via GitOps + ArgoCD",
    version="0.1.0",
    lifespan=lifespan,
)

# CORS — allow Vue frontend on any port
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Register routes
app.include_router(deploy_router)
app.include_router(status_router)


@app.get("/api/health")
async def health():
    """API health check."""
    return {"status": "ok", "service": "hub-orchestrator"}


@app.get("/")
async def root():
    """Root — redirect to docs for now. Dashboard HTML in Phase 2."""
    return JSONResponse({
        "service": "Hub Orchestrator API",
        "version": "0.1.0",
        "docs": "/docs",
        "endpoints": {
            "deploy_component": "POST /api/deploy/component",
            "deploy_config": "POST /api/deploy/config",
            "dry_run": "POST /api/dry-run",
            "rollback": "POST /api/rollback/component",
            "status": "GET /api/status",
            "component_status": "GET /api/status/{app_name}",
            "history": "GET /api/history",
            "diff": "GET /api/diff",
            "approve": "POST /api/approve",
            "health": "GET /api/health",
        }
    })
