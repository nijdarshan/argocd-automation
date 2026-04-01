"""
Git operations service.

Design note: We use subprocess to call git, not a Python git library.
Why: git CLI is the same tool used in the shell orchestrator — no behavior
differences. The commands are simple (commit, push, revert, diff) and
subprocess is more transparent than a library abstraction.

All operations work on a local clone of the GitOps repo.
"""

import subprocess
import os
from ..config import settings


class GitService:
    def __init__(self):
        self.repo_path = settings.gitops_local_path
        self.remote_url = (
            f"http://{settings.gitea_user}:{settings.gitea_password}"
            f"@localhost:3000/{settings.gitea_user}/{settings.gitops_repo_name}.git"
        )

    def _run(self, *args, check: bool = True) -> str:
        """Run a git command in the repo directory."""
        result = subprocess.run(
            ["git"] + list(args),
            cwd=self.repo_path,
            capture_output=True,
            text=True,
        )
        if check and result.returncode != 0:
            raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr}")
        return result.stdout.strip()

    # ── Setup ─────────────────────────────────────────────

    def ensure_cloned(self):
        """Clone or pull the GitOps repo."""
        if os.path.exists(os.path.join(self.repo_path, ".git")):
            self._run("pull", "origin", "main", "--rebase", check=False)
        else:
            subprocess.run(
                ["git", "clone", self.remote_url, self.repo_path],
                capture_output=True, text=True, check=True,
            )

    # ── Read Operations ───────────────────────────────────

    def diff(self) -> str:
        """Show unstaged changes (what would be committed)."""
        self._run("add", "-A")
        diff = self._run("diff", "--staged")
        self._run("reset", "HEAD", check=False)
        return diff

    def diff_stat(self) -> str:
        """Show files that would change."""
        self._run("add", "-A")
        stat = self._run("diff", "--staged", "--stat")
        self._run("reset", "HEAD", check=False)
        return stat

    def log(self, count: int = 15) -> list[dict]:
        """Get recent git log as structured data."""
        raw = self._run("log", f"--oneline", f"-{count}")
        entries = []
        for line in raw.splitlines():
            parts = line.split(" ", 1)
            if len(parts) == 2:
                entries.append({"sha": parts[0], "message": parts[1]})
        return entries

    def get_file(self, path: str) -> str:
        """Read a file from the repo."""
        full_path = os.path.join(self.repo_path, path)
        if os.path.exists(full_path):
            with open(full_path) as f:
                return f.read()
        return ""

    # ── Write Operations ──────────────────────────────────

    def commit_and_push(self, message: str) -> str | None:
        """Stage all, commit, push. Returns SHA or None if no changes."""
        self._run("add", "-A")

        # Check if there are changes to commit
        result = subprocess.run(
            ["git", "diff", "--staged", "--quiet"],
            cwd=self.repo_path,
            capture_output=True,
        )
        if result.returncode == 0:
            return None  # no changes

        self._run("commit", "-m", message)
        sha = self._run("rev-parse", "HEAD")
        self._run("push", "origin", "main")
        return sha

    def revert_commit(self, sha: str, message: str) -> str:
        """Git revert a specific commit, amend message, push."""
        self._run("revert", "--no-edit", sha)
        self._run("commit", "--amend", "-m", message)
        new_sha = self._run("rev-parse", "HEAD")
        self._run("push", "origin", "main")
        return new_sha

    def last_commit_for_path(self, path: str) -> dict | None:
        """Get the most recent commit that touched a specific path."""
        raw = self._run("log", "--oneline", "-1", "--", path, check=False)
        if raw:
            parts = raw.split(" ", 1)
            return {"sha": parts[0], "message": parts[1] if len(parts) > 1 else ""}
        return None

    # ── File Operations ───────────────────────────────────

    def write_file(self, relative_path: str, content: str):
        """Write content to a file in the repo."""
        full_path = os.path.join(self.repo_path, relative_path)
        os.makedirs(os.path.dirname(full_path), exist_ok=True)
        with open(full_path, "w") as f:
            f.write(content)

    def read_manifest(self, component_path: str) -> str:
        """Read a component's deployment manifest."""
        return self.get_file(f"environments/dev/{component_path}/deployment.yaml")

    def update_manifest_field(self, component_path: str, field: str, old_value: str, new_value: str):
        """Replace a value in a component's manifest (sed-style)."""
        manifest_path = os.path.join(
            self.repo_path, "environments", "dev", component_path, "deployment.yaml"
        )
        if os.path.exists(manifest_path):
            with open(manifest_path) as f:
                content = f.read()
            content = content.replace(old_value, new_value)
            with open(manifest_path, "w") as f:
                f.write(content)


# Singleton
git_service = GitService()
