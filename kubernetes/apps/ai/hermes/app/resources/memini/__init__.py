"""Memory provider memini: recall from memini before a turn, and save to memini what the agent keeps.

The provider calls memini through the LiteLLM MCP gateway, with the Hermes key and the server
memini_hermes, as the agents do with their memini tools. Each profile uses its own namespace,
hermes/<profile>, and memini adds the parents hermes and personal/jaime. The provider injects the
memories of hermes and hermes/<profile>, and of personal/jaime only those with the tag hermes:
personal/jaime holds mostly the work of Claude Code, which is noise for a Hermes agent. A call that
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
# The tag of the facts about Jaime that Hermes saves in personal/jaime.
TAG = "hermes"
PERSONAL = "personal/jaime"


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
    kept = [str(i.get("content") or "").strip() for i in items if isinstance(i, dict)]
    return [f"- {c}" for c in kept if c][:limit]


def _recall(namespace: str, query: str) -> str:
    args = {"query": query, "limit": RECALL_FETCH, "response_format": "concise"}
    ours = [i for i in json.loads(_call(namespace, "memory_recall", args)).get("results", []) if _ours(i)]
    # The tag selects the Hermes facts in personal/jaime: a concise result does not show its tags.
    tagged = json.loads(_call(namespace, "memory_recall", {**args, "tags": [TAG]})).get("results", [])
    seen, items = set(), []
    for item in tagged + ours:
        if isinstance(item, dict) and item.get("id") not in seen:
            seen.add(item.get("id"))
            items.append(item)
    return "\n".join(_lines(items, RECALL_LIMIT))


def _format_briefing(text: str) -> str:
    briefing = json.loads(text)
    lines = []
    for section in ("pinned", "facts", "procedures"):
        lines += _lines([i for i in briefing.get(section) or [] if isinstance(i, dict) and _ours(i)], RECALL_LIMIT)
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
        namespace = self._namespace
        self._background(self._load, lambda: _format_briefing(_call(namespace, "memory_briefing", {})),
                         "memini briefing")

    def queue_prefetch(self, query: str, *, session_id: str = "") -> None:
        if query.strip():
            namespace = self._namespace
            self._background(self._load, lambda: _recall(namespace, query[:500]), "memini recall")

    def prefetch(self, query: str, *, session_id: str = "") -> str:
        with self._lock:
            context, self._context = self._context, ""
        return context

    def on_memory_write(self, action: str, target: str, content: str,
                        metadata: Optional[dict[str, Any]] = None) -> None:
        if not self._writes or action not in ("add", "replace", "remove"):
            return
        user = target == "user"
        # Hermes gives the old entry on a replace or a remove: its memini copy goes, or it goes stale.
        previous = str((metadata or {}).get("previous_content") or "").strip() if action != "add" else ""
        args: Optional[dict[str, Any]] = None
        if action != "remove" and content.strip():
            # The Hermes memory is durable. memini can classify a short entry as working, which
            # expires in days and which memini keeps in hermes/<profile> for any visibility.
            args = {"content": content.strip(), "tier": "semantic"}
            if user:
                # A fact about Jaime: every agent of Jaime knows it, and the tag brings it into recalls.
                args.update(visibility="personal", tags=[TAG])
        if previous or args:
            # One thread, so the forget of a replace comes before its save.
            self._background(self._mirror, previous, user, args)

    def get_tool_schemas(self) -> list[dict[str, Any]]:
        return []  # The agents have the memini tools through their MCP servers.

    def _background(self, target, *args) -> None:
        thread = spawn_context_thread(target, name="memini", args=args)
        self._threads = [t for t in self._threads if t.is_alive()] + [thread]
        thread.start()

    def _load(self, fetch, heading: str) -> None:
        try:
            text = fetch()
        except Exception as exc:  # noqa: BLE001 - memory must never stop a turn.
            logger.debug("memini: %s failed: %s", heading, exc)
            return
        if text:
            with self._lock:
                self._context = f"## {heading}\n{text[:MAX_CHARS]}"

    def _mirror(self, previous: str, user: bool, args: Optional[dict[str, Any]]) -> None:
        try:
            if previous:
                self._forget(previous, user)
            if args:
                _call(self._namespace, "memory_remember", args)
        except Exception as exc:  # noqa: BLE001 - a lost copy is better than a failed turn.
            logger.warning("memini: memory write failed: %s", exc)

    def _forget(self, content: str, user: bool) -> None:
        """Forget the copy that this provider saved: the same text, where the provider saves it."""
        args: dict[str, Any] = {"query": content[:500], "limit": 5, "response_format": "detailed"}
        if user:
            args["tags"] = [TAG]  # Never a memory of Claude Code in personal/jaime.
        namespace = PERSONAL if user else self._namespace
        for item in json.loads(_call(self._namespace, "memory_recall", args)).get("results", []):
            if (isinstance(item, dict) and item.get("namespace") == namespace
                    and str(item.get("content") or "").strip() == content and item.get("id")):
                _call(self._namespace, "memory_forget", {"id": item["id"], "namespace": namespace})


def register(ctx) -> None:
    ctx.register_memory_provider(MeminiProvider())
