"""Application configuration.

Every knob is an environment variable. Nothing is hardcoded, because all of
these values are supplied at deploy time by the ConfigMap/Secret that Ansible
renders and Helm ships (see ansible/roles/app_config).
"""

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="APP_", env_file=".env", extra="ignore")

    # --- identity ---------------------------------------------------------
    app_name: str = "csv-app"
    environment: str = "dev"
    log_level: str = "INFO"

    # --- object storage ---------------------------------------------------
    # s3_endpoint_url is the only thing that differs between MinIO (local) and
    # real AWS S3 (production). Leave it unset and boto3 talks to real AWS.
    s3_bucket: str = "csv-uploads"
    s3_prefix: str = "uploads"
    s3_region: str = "us-east-1"
    s3_endpoint_url: str | None = None
    s3_access_key_id: str | None = None
    s3_secret_access_key: str | None = None
    # MinIO needs path-style addressing; real S3 prefers virtual-host style.
    s3_force_path_style: bool = False

    # --- upload limits ----------------------------------------------------
    max_upload_bytes: int = 25 * 1024 * 1024  # 25 MiB
    # The whole file is always archived to S3; this only caps what we render,
    # so a large upload cannot lock up the browser.
    max_rows_display: int = 1000
    # How many previously-processed files to list on the index page.
    max_files_listed: int = 100

    @property
    def display_environment(self) -> str:
        return self.environment.lower()


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Cached accessor so the settings are parsed once per process."""
    return Settings()
