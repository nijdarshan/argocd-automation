"""
Configuration — all connection details in one place.

Design note: These are defaults for the local Kind lab.
In production, read from env vars or Vault.
The Config class uses Pydantic Settings which auto-reads env vars:
  ARGOCD_URL=https://argocd.prod.internal → overrides the default.
"""

from pydantic_settings import BaseSettings


class Config(BaseSettings):
    # ArgoCD
    argocd_url: str = "https://localhost:30443"
    argocd_username: str = "admin"
    argocd_insecure: bool = True  # skip TLS verify for local

    # Gitea / Git
    gitea_url: str = "http://localhost:3000"
    gitea_user: str = "gitea_admin"
    gitea_password: str = "gitea_admin"
    gitops_repo_name: str = "nf-demo-gitops"
    gitops_local_path: str = "/tmp/nf-demo-gitops"

    # Namespace
    namespace: str = "nf-demo"

    # Manifests source
    manifests_path: str = ""  # set at startup from project dir

    class Config:
        env_prefix = "HUB_"  # HUB_ARGOCD_URL, HUB_NAMESPACE, etc.


settings = Config()
