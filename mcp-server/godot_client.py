"""HTTP client for the Godot ClaudeHarness plugin."""

from __future__ import annotations

import json
import os
from typing import Any

import httpx

GODOT_HARNESS_URL = os.environ.get("GODOT_HARNESS_URL", "http://localhost:9080")

_NOT_RUNNING_MSG = (
    "Cannot connect to Godot at {url}.\n"
    "Make sure:\n"
    "  1. The ClaudeHarness plugin is enabled in your Godot project.\n"
    "  2. The game is running (press F5 in Godot or run: godot --path <project_dir>).\n"
    "  3. The port matches: default is 9080, override with GODOT_HARNESS_URL env var."
)


class GodotClient:
    def __init__(self, base_url: str = GODOT_HARNESS_URL) -> None:
        self.base_url = base_url.rstrip("/")

    # ------------------------------------------------------------------
    # Core request helpers
    # ------------------------------------------------------------------

    def get(self, path: str, timeout: float = 10.0) -> str:
        """GET request, returns raw response text."""
        try:
            r = httpx.get(f"{self.base_url}{path}", timeout=timeout)
            r.raise_for_status()
            return r.text
        except httpx.ConnectError:
            raise ConnectionError(
                _NOT_RUNNING_MSG.format(url=self.base_url)
            ) from None

    def get_json(self, path: str, timeout: float = 10.0) -> Any:
        """GET request, returns parsed JSON."""
        return json.loads(self.get(path, timeout))

    def post(
        self,
        path: str,
        body: dict | None = None,
        timeout: float = 10.0,
    ) -> str:
        """POST request with optional JSON body, returns raw response text."""
        try:
            r = httpx.post(
                f"{self.base_url}{path}",
                json=body,
                timeout=timeout,
            )
            r.raise_for_status()
            return r.text
        except httpx.ConnectError:
            raise ConnectionError(
                _NOT_RUNNING_MSG.format(url=self.base_url)
            ) from None

    def post_json(
        self,
        path: str,
        body: dict | None = None,
        timeout: float = 10.0,
    ) -> Any:
        """POST request, returns parsed JSON."""
        return json.loads(self.post(path, body, timeout))
