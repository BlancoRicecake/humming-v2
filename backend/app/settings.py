"""Centralised env-var loader (Pydantic Settings).

Loaded once at import time. Missing optional vars default to None so the
backend can boot without IAP / R2 / Supabase configured (e.g. local
``/analyze`` development).
"""
from __future__ import annotations

import os
from functools import lru_cache
from typing import Optional

try:
    from pydantic_settings import BaseSettings, SettingsConfigDict
except ImportError:  # pragma: no cover — pydantic-settings is in requirements
    from pydantic import BaseSettings  # type: ignore
    SettingsConfigDict = None  # type: ignore


class Settings(BaseSettings):
    # Supabase
    supabase_url: Optional[str] = None
    supabase_service_role_key: Optional[str] = None
    supabase_anon_key: Optional[str] = None
    supabase_jwt_secret: Optional[str] = None  # used to verify user JWT locally

    # Cloudflare R2 (S3-compatible)
    r2_access_key_id: Optional[str] = None
    r2_secret_access_key: Optional[str] = None
    r2_endpoint: Optional[str] = None
    r2_bucket: Optional[str] = None
    r2_public_base_url: Optional[str] = None  # https://cdn.example.com

    # Apple App Store Server API
    # NOTE: App Store Server API uses Team ID as JWT `iss` (NOT the
    # App Store Connect API issuer UUID). We keep apple_issuer_id around as
    # an optional override for environments that still use a legacy key.
    apple_shared_secret: Optional[str] = None  # Legacy verifyReceipt fallback
    apple_bundle_id: Optional[str] = None
    apple_team_id: Optional[str] = None
    apple_iap_key_id: Optional[str] = None
    apple_iap_private_key: Optional[str] = None  # Inline PEM (.p8 contents)
    apple_iap_private_key_path: Optional[str] = None  # Path to .p8 file
    # Back-compat shims (older deploys used these names)
    apple_key_id: Optional[str] = None
    apple_issuer_id: Optional[str] = None
    apple_private_key: Optional[str] = None
    apple_environment: str = "production"  # "sandbox" | "production"
    apple_iap_product_monthly: Optional[str] = None
    apple_iap_product_yearly: Optional[str] = None

    # Google Play Developer API
    google_service_account_json: Optional[str] = None  # raw JSON string
    google_package_name: Optional[str] = None

    # Observability
    sentry_dsn: Optional[str] = None
    sentry_traces_sample_rate: float = 0.1
    environment: str = "dev"

    # Misc
    max_body_bytes: int = 2 * 1024 * 1024  # 2MB
    presign_max_bytes: int = 5 * 1024 * 1024  # 5MB
    presign_ttl_sec: int = 300

    # --- Apple resolution helpers ------------------------------------------
    def resolve_apple_key_id(self) -> Optional[str]:
        return self.apple_iap_key_id or self.apple_key_id

    def resolve_apple_issuer(self) -> Optional[str]:
        # App Store Server API: use Team ID as `iss`. Fallback to legacy
        # apple_issuer_id if present (older ASC API style keys).
        return self.apple_team_id or self.apple_issuer_id

    def resolve_apple_private_key(self) -> Optional[str]:
        """Return PEM contents. Prefer inline env, then path on disk."""
        if self.apple_iap_private_key:
            return self.apple_iap_private_key
        if self.apple_private_key:
            return self.apple_private_key
        path = self.apple_iap_private_key_path
        if path:
            try:
                # Allow relative to backend/ working dir
                with open(path, "r", encoding="utf-8") as f:
                    return f.read()
            except FileNotFoundError:
                return None
        return None

    def accepted_apple_product_ids(self) -> set[str]:
        return {p for p in (self.apple_iap_product_monthly,
                            self.apple_iap_product_yearly) if p}

    if SettingsConfigDict is not None:
        model_config = SettingsConfigDict(env_file=".env", case_sensitive=False, extra="ignore")
    else:  # pydantic v1 fallback
        class Config:  # type: ignore
            env_file = ".env"
            case_sensitive = False


@lru_cache
def get_settings() -> Settings:
    return Settings()
