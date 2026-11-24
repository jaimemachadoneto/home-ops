"""Delegation backend: one model for each tier, selected for each subagent task.

The settings are in delegation.backends.task-tiers of config.yaml:

    tiers:
      light: {model: opr-free-light, use: "one read or one query"}
    default: light

A tier without a provider uses the provider litellm.
"""

from __future__ import annotations

from typing import Any, Mapping

from agent.delegation_provider import DelegationProvider, DelegationRouteError


class TaskTiersProvider(DelegationProvider):
    @property
    def name(self) -> str:
        return "task-tiers"

    @property
    def display_name(self) -> str:
        return "Task tiers"

    @property
    def summary(self) -> str:
        return "The orchestrator selects a tier (a model) for each subagent task."

    def _tiers(self, config: Mapping[str, Any]) -> dict[str, Mapping[str, Any]]:
        tiers = self.settings(config).get("tiers")
        if not isinstance(tiers, Mapping):
            return {}
        return {str(k): v for k, v in tiers.items() if isinstance(v, Mapping) and v.get("model")}

    def task_parameters(self, config: Mapping[str, Any]) -> dict[str, dict[str, Any]]:
        tiers = self._tiers(config)
        if not tiers:
            return {}
        return {"tier": {"type": "string", "enum": sorted(tiers),
                         "description": "The model tier for this task. Select it from the difficulty of the task."}}

    def description(self, config: Mapping[str, Any]) -> str:
        tiers = self._tiers(config)
        if not tiers:
            return ""
        lines = [f"- {k}: {str(v.get('use') or '').strip()}" for k, v in sorted(tiers.items())]
        return "Set `tier` on each task. Use the least strong tier that can do the task:\n" + "\n".join(lines)

    def route_task(self, task: Mapping[str, Any], config: Mapping[str, Any]) -> dict[str, Any]:
        tiers = self._tiers(config)
        name = task.get("tier") or self.settings(config).get("default")
        if name not in tiers:
            raise DelegationRouteError(f"Set `tier` to one of: {', '.join(sorted(tiers)) or '(no tiers configured)'}.")
        tier = tiers[name]
        return {"provider": str(tier.get("provider") or "litellm"), "model": str(tier["model"]), "label": name}


def register(ctx) -> None:
    ctx.register_delegation_provider(TaskTiersProvider())
