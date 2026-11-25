"""Delegation backend: the orchestrator selects, for each subagent task, a model tier or another agent.

The settings are in delegation.backends.task-tiers of config.yaml:

    tiers:
      light: {model: opr-free-light, use: "one read or one query"}
    default: light
    agents:
      house: {use: "lights, scenes, media and the state of the house"}

A tier runs the subagent on that model; a tier without a provider uses the
provider litellm. An agent runs the subagent as that Hermes profile, with its
own SOUL, tools and model. Only the agents in this list are allowed.
"""

from __future__ import annotations

from typing import Any, Mapping

from agent.delegation_provider import DelegationProvider, DelegationRouteError


def _entries(settings: Mapping[str, Any], key: str, need: str | None = None) -> dict[str, Mapping[str, Any]]:
    block = settings.get(key)
    if not isinstance(block, Mapping):
        return {}
    return {str(k): v for k, v in block.items() if isinstance(v, Mapping) and (need is None or v.get(need))}


def _caller() -> str:
    """The profile that gives the task: the route runs in the scope of the parent."""
    from hermes_cli.profiles import current_profile_name

    return current_profile_name("default") or "default"


def _lines(entries: Mapping[str, Mapping[str, Any]]) -> str:
    return "\n".join(f"- {k}: {str(v.get('use') or '').strip()}" for k, v in sorted(entries.items()))


class TaskTiersProvider(DelegationProvider):
    @property
    def name(self) -> str:
        return "task-tiers"

    @property
    def display_name(self) -> str:
        return "Task tiers"

    @property
    def summary(self) -> str:
        return "The orchestrator selects a model tier or an agent for each subagent task."

    def task_parameters(self, config: Mapping[str, Any]) -> dict[str, dict[str, Any]]:
        settings = self.settings(config)
        params: dict[str, dict[str, Any]] = {}
        tiers = _entries(settings, "tiers", "model")
        agents = _entries(settings, "agents")
        if tiers:
            params["tier"] = {"type": "string", "enum": sorted(tiers),
                              "description": "The model tier for this task. Select it from the difficulty of the task."}
        if agents:
            params["agent"] = {"type": "string", "enum": sorted(agents),
                               "description": "Give the task to this agent. It runs with its own tools and model."}
        return params

    def description(self, config: Mapping[str, Any]) -> str:
        settings = self.settings(config)
        parts = []
        tiers = _entries(settings, "tiers", "model")
        agents = _entries(settings, "agents")
        if agents:
            parts.append("Set `agent` to give a task to the agent that owns it:\n" + _lines(agents))
        if tiers:
            parts.append("Set `tier` on each task. Use the least strong tier that can do the task:\n" + _lines(tiers))
        return "\n\n".join(parts)

    def route_task(self, task: Mapping[str, Any], config: Mapping[str, Any]) -> dict[str, Any]:
        settings = self.settings(config)
        agents = _entries(settings, "agents")
        agent = task.get("agent")
        # Only default asks Jaime for an approval, so only default can pass one on. A child cannot
        # see who sent a task, so the check is here and not in the SOUL of the child.
        text = " ".join(str(v) for v in task.values() if isinstance(v, str)).lower()
        if "jaime approved" in text and _caller() != "default":
            raise DelegationRouteError("Only default can pass an approval of Jaime. Remove it from the task.")
        if agent:
            if agent not in agents:
                raise DelegationRouteError(f"Set `agent` to one of: {', '.join(sorted(agents)) or '(none allowed)'}.")
            # The relayed marker tells the agent that the request comes from another agent, not from Jaime.
            return {"profile": agent, "label": f"{agent} (relayed)"}
        tiers = _entries(settings, "tiers", "model")
        if not tiers:
            return {}  # No tiers: the subagent uses the model of this profile.
        name = task.get("tier") or settings.get("default")
        if name not in tiers:
            raise DelegationRouteError(f"Set `tier` to one of: {', '.join(sorted(tiers))}.")
        tier = tiers[name]
        return {"provider": str(tier.get("provider") or "litellm"), "model": str(tier["model"]), "label": name}


def register(ctx) -> None:
    ctx.register_delegation_provider(TaskTiersProvider())
