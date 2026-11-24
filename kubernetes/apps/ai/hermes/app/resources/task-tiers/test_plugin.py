"""Self-test of the task-tiers backend. It needs the Hermes modules, so run it in the Hermes pod:

    kubectl -n ai exec -i deploy/hermes -c app -- <hermes python> - < test_plugin.py

The test reads the plugin from PLUGIN_DIR (default: /tmp/task-tiers-test).
"""

import importlib.util
import os
import sys

from agent.delegation_provider import DelegationRouteError

path = os.path.join(os.environ.get("PLUGIN_DIR", "/tmp/task-tiers-test"), "__init__.py")
spec = importlib.util.spec_from_file_location("task_tiers", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
p = mod.TaskTiersProvider()


def cfg(**block):
    return {"backend": "task-tiers", "backends": {"task-tiers": block}}


def refused(task, config):
    try:
        p.route_task(task, config)
    except DelegationRouteError:
        return True
    return False


tiers = {"light": {"model": "opr-free-light", "use": "one read"}, "standard": {"model": "opr-free-strong"}}
agents = {"house": {"use": "lights"}, "research": {"use": "lessons"}}

# Tiers only (infra).
c = cfg(tiers=tiers, default="standard")
assert set(p.task_parameters(c)) == {"tier"}
assert p.route_task({"goal": "x", "tier": "light"}, c) == {"provider": "litellm", "model": "opr-free-light", "label": "light"}
assert p.route_task({"goal": "x"}, c)["model"] == "opr-free-strong"
assert refused({"goal": "x", "tier": "nope"}, c)
assert refused({"goal": "x", "agent": "house"}, c), "an agent that is not in the list is refused"

# Agents only (default).
c = cfg(agents=agents)
assert set(p.task_parameters(c)) == {"agent"}
assert p.task_parameters(c)["agent"]["enum"] == ["house", "research"]
assert p.route_task({"goal": "x", "agent": "house"}, c) == {"profile": "house", "label": "house (relayed)"}
assert refused({"goal": "x", "agent": "dev"}, c), "dev is not in the list"
assert p.route_task({"goal": "x"}, c) == {}, "no agent and no tiers: the parent model"
assert "house: lights" in p.description(c)

# Both.
c = cfg(agents=agents, tiers=tiers, default="light")
assert set(p.task_parameters(c)) == {"agent", "tier"}
assert p.route_task({"goal": "x", "agent": "research", "tier": "light"}, c)["profile"] == "research"
assert p.route_task({"goal": "x"}, c)["model"] == "opr-free-light"

# Nothing configured.
assert p.task_parameters(cfg()) == {} and p.description(cfg()) == ""
print("task-tiers: all checks passed")
sys.exit(0)
