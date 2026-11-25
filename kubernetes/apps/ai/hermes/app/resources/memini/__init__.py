"""Memory provider memini: recall from memini before a turn, and save to memini what the agent keeps.

The provider calls memini through the LiteLLM MCP gateway, with the Hermes key and the server
memini_hermes, as the agents do with their memini tools. Each profile uses its own namespace,
hermes/<profile>, and memini adds the parents hermes and personal/jaime. The provider injects only
the memories of hermes and hermes/<profile>: personal/jaime holds mostly the work of Claude Code,
which is noise for a Hermes agent. An agent reads it on purpose with its memini tools. A call that
fails gives no context and no error: memory must never stop a turn.

Activate it with `memory.provider: memini` (profiles.sh does this).
"""

from __future__ import annotations

import json
import logging
import os
import threading
import urllib.request
from pathlib import Path
from typing import Any, Optional

from agent.memory_provider import MemoryProvider, spawn_context_thread

logger = logging.getLogger(__name__)

URL = os.environ.get("MEMINI_MCP_URL", "http://litellm.ai.svc.cluster.local:4000/mcp/")
KEY_FILE = Path(os.environ.get("MEMINI_KEY_FILE", "/mnt/secrets/litellm/key"))
SERVER = "memini_hermes"
TIMEOUT_SECONDS = 8
MAX_CHARS = 2000
RECALL_LIMIT = 5
# More results than we inject, because the filter drops the memories of other namespaces.
RECALL_FETCH = 15


def _call(namespace: str, tool: str, args: dict[str, Any]) -> str:
    """Call one memini tool through LiteLLM and return its text. Raise on any failure."""
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                       "params": {"name": f"{SERVER}-{tool}", "arguments": args}}).encode()
    request = urllib.request.Request(URL, data=body, headers={
        "Authorization": "Bearer " + KEY_FILE.read_text().strip(),
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "x-mcp-servers": SERVER,
        "X-Memini-Namespace": namespace,
    })
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        raw = response.read().decode()
    # The gateway answers with server-sent events: the JSON is on the data lines.
    data = "\n".join(line[5:].strip() for line in raw.splitlines() if line.startswith("data:")) or raw
    result = json.loads(data)["result"]
    text = "".join(part.get("text", "") for part in result.get("content", []))
    if result.get("isError"):
        raise RuntimeError(text[:200])
    return text


def _profile(hermes_home: Any) -> str:
    home = Path(str(hermes_home))
    return home.name if home.parent.name == "profiles" else "default"


def _ours(item: dict[str, Any]) -> bool:
    namespace = str(item.get("namespace") or item.get("from") or "")
    return namespace == "hermes" or namespace.startswith("hermes/")


def _lines(items: list[dict[str, Any]], limit: int) -> list[str]:
    kept = [str(i.get("content") or "").strip() for i in items if isinstance(i, dict) and _ours(i)]
    return [f"- {c}" for c in kept if c][:limit]


def _format_recall(text: str) -> str:
    return "\n".join(_lines(json.loads(text).get("results", []), RECALL_LIMIT))


def _format_briefing(text: str) -> str:
    briefing = json.loads(text)
    lines = []
    for section in ("pinned", "facts", "procedures"):
        lines += _lines(briefing.get(section) or [], RECALL_LIMIT)
    return "\n".join(lines)


class MeminiProvider(MemoryProvider):
    def __init__(self) -> None:
        self._namespace = ""
        self._writes = False
        self._context = ""
        self._lock = threading.Lock()
        self._threads: list[threading.Thread] = []

    @property
    def name(self) -> str:
        return "memini"

    def is_available(self) -> bool:
        return KEY_FILE.is_file()

    def initialize(self, session_id: str, **kwargs) -> None:
        self._namespace = "hermes/" + _profile(kwargs["hermes_home"])
        # Only the agent that talks to Jaime saves: a scheduled job or a subagent only reads.
        self._writes = kwargs.get("agent_context", "primary") == "primary"
        self._background(self._load, "memory_briefing", {}, _format_briefing, "memini briefing")

    def queue_prefetch(self, query: str, *, session_id: str = "") -> None:
        if query.strip():
            args = {"query": query[:500], "limit": RECALL_FETCH, "response_format": "concise"}
            self._background(self._load, "memory_recall", args, _format_recall, "memini recall")

    def prefetch(self, query: str, *, session_id: str = "") -> str:
        with self._lock:
            context, self._context = self._context, ""
        return context

    def on_memory_write(self, action: str, target: str, content: str,
                        metadata: Optional[dict[str, Any]] = None) -> None:
        # shortcut: a remove does not forget the memini copy; memini ages facts out. Add a
        # memory_forget by content if stale facts show up in recalls.
        if not self._writes or action not in ("add", "replace") or not content.strip():
            return
        args: dict[str, Any] = {"content": content.strip()}
        if target == "user":
            args["visibility"] = "hermes"  # A fact about Jaime: every Hermes agent knows it.
        self._background(self._save, args)

    def get_tool_schemas(self) -> list[dict[str, Any]]:
        return []  # The agents have the memini tools through their MCP servers.

    def _background(self, target, *args) -> None:
        thread = spawn_context_thread(target, name="memini", args=args)
        self._threads = [t for t in self._threads if t.is_alive()] + [thread]
        thread.start()

    def _load(self, tool: str, args: dict[str, Any], render, heading: str) -> None:
        try:
            text = render(_call(self._namespace, tool, args))
        except Exception as exc:  # noqa: BLE001 - memory must never stop a turn.
            logger.debug("memini: %s failed: %s", tool, exc)
            return
        if text:
            with self._lock:
                self._context = f"## {heading}\n{text[:MAX_CHARS]}"

    def _save(self, args: dict[str, Any]) -> None:
        try:
            _call(self._namespace, "memory_remember", args)
        except Exception as exc:  # noqa: BLE001 - a lost copy is better than a failed turn.
            logger.warning("memini: memory_remember failed: %s", exc)


def register(ctx) -> None:
    ctx.register_memory_provider(MeminiProvider())
