from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


MODEL_BLOB = "sha256-71b5c9c9abbc2a9e7c13550b6f9fe1f062650117a24490b15a310cbd7de03f8b"
MMPROJ_BLOB = "sha256-f48b452316f9b213758e8659444029b961a24a07f99a1abb2a9f88b06f7c00c6"


def _int(name: str, default: int) -> int:
    return int(os.environ.get(name, str(default)))


def _bool(name: str, default: bool) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Config:
    public_host: str
    public_port: int
    backend_host: str
    backend_port: int
    model_path: Path
    mmproj_path: Path
    model_name: str
    llama_binary: str
    slots: int
    context_size: int
    session_token_limit: int
    total_cache_token_limit: int
    lease_seconds: int
    max_output_tokens: int
    snapshot_mode: str
    model_unload_policy: str
    model_idle_seconds: int
    api_key: str
    state_dir: Path
    backend_autostart: bool
    log_level: str

    @classmethod
    def from_env(cls) -> "Config":
        home = Path.home()
        default_state = Path(__file__).resolve().parents[1] / "state"
        blob_dir = home / ".ollama" / "models" / "blobs"
        cfg = cls(
            public_host=os.environ.get("MUSE_HOST", "127.0.0.1"),
            public_port=_int("MUSE_PORT", 11434),
            backend_host=os.environ.get("MUSE_BACKEND_HOST", "127.0.0.1"),
            backend_port=_int("MUSE_BACKEND_PORT", 18080),
            model_path=Path(os.environ.get("MUSE_MODEL_PATH", str(blob_dir / MODEL_BLOB))).expanduser(),
            mmproj_path=Path(os.environ.get("MUSE_MMPROJ_PATH", str(blob_dir / MMPROJ_BLOB))).expanduser(),
            model_name=os.environ.get("MUSE_MODEL_NAME", "muse-glimmer:latest"),
            llama_binary=os.environ.get("MUSE_LLAMA_SERVER", "llama-server"),
            slots=_int("MUSE_SLOTS", 4),
            context_size=_int("MUSE_CONTEXT_SIZE", 32768),
            session_token_limit=_int("MUSE_SESSION_TOKEN_LIMIT", 8192),
            total_cache_token_limit=_int("MUSE_TOTAL_CACHE_TOKEN_LIMIT", 24576),
            lease_seconds=_int("MUSE_LEASE_SECONDS", 300),
            max_output_tokens=_int("MUSE_MAX_OUTPUT_TOKENS", 2048),
            snapshot_mode=os.environ.get("MUSE_SNAPSHOT_MODE", "disabled").strip().lower(),
            model_unload_policy=os.environ.get("MUSE_MODEL_UNLOAD_POLICY", "keep_loaded").strip().lower(),
            model_idle_seconds=_int("MUSE_MODEL_IDLE_SECONDS", 900),
            api_key=os.environ.get("MUSE_API_KEY", ""),
            state_dir=Path(os.environ.get("MUSE_STATE_DIR", str(default_state))).expanduser(),
            backend_autostart=_bool("MUSE_BACKEND_AUTOSTART", True),
            log_level=os.environ.get("MUSE_LOG_LEVEL", "INFO").upper(),
        )
        cfg.validate()
        return cfg

    def validate(self) -> None:
        if self.slots < 1:
            raise ValueError("MUSE_SLOTS must be at least 1")
        if self.context_size < self.slots:
            raise ValueError("MUSE_CONTEXT_SIZE must be at least MUSE_SLOTS")
        if self.session_token_limit < 128:
            raise ValueError("MUSE_SESSION_TOKEN_LIMIT must be at least 128")
        if self.total_cache_token_limit < self.session_token_limit:
            raise ValueError("MUSE_TOTAL_CACHE_TOKEN_LIMIT cannot be smaller than MUSE_SESSION_TOKEN_LIMIT")
        if self.session_token_limit > self.slot_context_size:
            raise ValueError("MUSE_SESSION_TOKEN_LIMIT cannot exceed the per-slot context size")
        if self.max_output_tokens < 1 or self.max_output_tokens >= self.slot_context_size - 31:
            raise ValueError("MUSE_MAX_OUTPUT_TOKENS must leave at least 32 prompt tokens per slot")
        if self.lease_seconds < 1:
            raise ValueError("MUSE_LEASE_SECONDS must be positive")
        if self.snapshot_mode not in {"disabled", "best_effort"}:
            raise ValueError("MUSE_SNAPSHOT_MODE must be disabled or best_effort")
        if self.model_unload_policy not in {"keep_loaded", "idle_timeout", "immediate"}:
            raise ValueError("MUSE_MODEL_UNLOAD_POLICY must be keep_loaded, idle_timeout, or immediate")
        if self.backend_autostart:
            if not self.model_path.is_file():
                raise ValueError("Muse Glimmer model file not found: %s" % self.model_path)
            if not self.mmproj_path.is_file():
                raise ValueError("Muse Glimmer vision projector not found: %s" % self.mmproj_path)

    @property
    def slot_context_size(self) -> int:
        return self.context_size // self.slots

    @property
    def backend_url(self) -> str:
        return "http://%s:%d" % (self.backend_host, self.backend_port)
