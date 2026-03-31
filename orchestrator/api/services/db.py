"""
Deployment state database — SQLite for PoC, swap to MariaDB/Postgres for prod.

Design: raw SQL, no ORM. Any dev can read this and reimplement in their stack.
The schema is 2 tables: deployments + component_results. That's it.

To switch to MariaDB: replace aiosqlite with aiomysql, change CREATE TABLE
syntax slightly (AUTO_INCREMENT instead of AUTOINCREMENT), same queries.
"""

import aiosqlite
import json
from datetime import datetime
from pathlib import Path

DB_PATH = Path(__file__).parent.parent.parent / "deployments.db"


async def init_db():
    """Create tables if they don't exist. Called on FastAPI startup."""
    async with aiosqlite.connect(DB_PATH) as db:
        await db.executescript("""
            CREATE TABLE IF NOT EXISTS deployments (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                deployment_id TEXT UNIQUE NOT NULL,
                helix_id TEXT NOT NULL,
                action TEXT NOT NULL,
                environment TEXT NOT NULL,
                nf TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending',
                created_at TEXT NOT NULL,
                completed_at TEXT,
                components_json TEXT
            );

            CREATE TABLE IF NOT EXISTS component_results (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                deployment_id TEXT NOT NULL,
                component TEXT NOT NULL,
                status TEXT NOT NULL,
                version TEXT,
                commit_sha TEXT,
                health TEXT,
                health_report_json TEXT,
                error TEXT,
                created_at TEXT NOT NULL,
                FOREIGN KEY (deployment_id) REFERENCES deployments(deployment_id)
            );

            CREATE TABLE IF NOT EXISTS diffs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                deployment_id TEXT NOT NULL,
                component TEXT NOT NULL,
                diff_text TEXT,
                files_json TEXT,
                created_at TEXT NOT NULL,
                FOREIGN KEY (deployment_id) REFERENCES deployments(deployment_id)
            );

            CREATE INDEX IF NOT EXISTS idx_deployments_helix ON deployments(helix_id);
            CREATE INDEX IF NOT EXISTS idx_deployments_nf ON deployments(nf, environment);
            CREATE INDEX IF NOT EXISTS idx_results_deployment ON component_results(deployment_id);
        """)


async def create_deployment(deployment_id: str, helix_id: str, action: str,
                            environment: str, nf: str, components: list[str]) -> dict:
    async with aiosqlite.connect(DB_PATH) as db:
        now = datetime.utcnow().isoformat()
        await db.execute(
            "INSERT OR REPLACE INTO deployments (deployment_id, helix_id, action, environment, nf, status, created_at, components_json) VALUES (?, ?, ?, ?, ?, 'in_progress', ?, ?)",
            (deployment_id, helix_id, action, environment, nf, now, json.dumps(components))
        )
        await db.commit()
    return {"deployment_id": deployment_id, "status": "in_progress", "created_at": now}


async def update_deployment_status(deployment_id: str, status: str):
    async with aiosqlite.connect(DB_PATH) as db:
        now = datetime.utcnow().isoformat()
        await db.execute(
            "UPDATE deployments SET status = ?, completed_at = ? WHERE deployment_id = ?",
            (status, now, deployment_id)
        )
        await db.commit()


async def record_component_result(deployment_id: str, component: str, status: str,
                                   version: str = None, commit_sha: str = None,
                                   health: str = None, health_report: dict = None,
                                   error: str = None):
    async with aiosqlite.connect(DB_PATH) as db:
        now = datetime.utcnow().isoformat()
        await db.execute(
            "INSERT INTO component_results (deployment_id, component, status, version, commit_sha, health, health_report_json, error, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (deployment_id, component, status, version, commit_sha, health,
             json.dumps(health_report) if health_report else None, error, now)
        )
        await db.commit()


async def get_deployment(deployment_id: str) -> dict | None:
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute("SELECT * FROM deployments WHERE deployment_id = ?", (deployment_id,)) as cursor:
            row = await cursor.fetchone()
            if not row:
                return None
            d = dict(row)
            d["components"] = json.loads(d.pop("components_json", "[]"))

            # Get component results
            async with db.execute("SELECT * FROM component_results WHERE deployment_id = ? ORDER BY created_at", (deployment_id,)) as cr:
                results = []
                async for r in cr:
                    r = dict(r)
                    r["health_report"] = json.loads(r.pop("health_report_json", "null") or "null")
                    results.append(r)
            d["component_results"] = results
            return d


async def get_deployments(nf: str = None, environment: str = None, limit: int = 20) -> list[dict]:
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        query = "SELECT * FROM deployments"
        params = []
        conditions = []
        if nf:
            conditions.append("nf = ?")
            params.append(nf)
        if environment:
            conditions.append("environment = ?")
            params.append(environment)
        if conditions:
            query += " WHERE " + " AND ".join(conditions)
        query += " ORDER BY created_at DESC LIMIT ?"
        params.append(limit)

        async with db.execute(query, params) as cursor:
            rows = []
            async for row in cursor:
                d = dict(row)
                d["components"] = json.loads(d.pop("components_json", "[]"))
                rows.append(d)
            return rows


async def get_latest_deployment(nf: str, environment: str) -> dict | None:
    results = await get_deployments(nf=nf, environment=environment, limit=1)
    return results[0] if results else None


async def store_diff(deployment_id: str, component: str, diff: str, files_changed: list[str]):
    """Store a diff snapshot — what changed in this deployment."""
    async with aiosqlite.connect(DB_PATH) as conn:
        now = datetime.utcnow().isoformat()
        await conn.execute(
            "INSERT INTO diffs (deployment_id, component, diff_text, files_json, created_at) VALUES (?, ?, ?, ?, ?)",
            (deployment_id, component, diff, json.dumps(files_changed), now)
        )
        await conn.commit()


async def get_diff(deployment_id: str) -> list[dict]:
    async with aiosqlite.connect(DB_PATH) as conn:
        conn.row_factory = aiosqlite.Row
        async with conn.execute("SELECT * FROM diffs WHERE deployment_id = ? ORDER BY created_at", (deployment_id,)) as cursor:
            rows = []
            async for row in cursor:
                d = dict(row)
                d["files_changed"] = json.loads(d.pop("files_json", "[]"))
                rows.append(d)
            return rows
