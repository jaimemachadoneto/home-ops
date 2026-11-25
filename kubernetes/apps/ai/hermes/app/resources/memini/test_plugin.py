"""Self-test of the memory provider memini. It needs the Hermes modules, so run it in the Hermes pod:

    kubectl -n ai exec -i deploy/hermes -c app -- <hermes python> - < test_plugin.py

The test reads the plugin from PLUGIN_DIR (default: /tmp/memini-test). It replaces the transport, so
it makes no network call.
"""

import importlib.util
import json
import os
import sys
import time

path = os.path.join(os.environ.get("PLUGIN_DIR", "/tmp/memini-test"), "__init__.py")
spec = importlib.util.spec_from_file_location("memini_provider", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

calls = []


def fake(namespace, tool, args):
    calls.append((namespace, tool, args))
    if tool == "memory_recall":
        return json.dumps({"results": [
            {"content": "Jaime uses the Dracula theme.", "namespace": "personal/jaime"},
            {"content": "The office light is light.office.", "namespace": "hermes/house"},
            {"content": "Jaime lives in Spain.", "namespace": "hermes"},
        ]})
    if tool == "memory_briefing":
        return json.dumps({
            "pinned": [{"content": "The home cluster has 4 nodes.", "namespace": "hermes"},
                       {"content": "A Claude Code rule.", "namespace": "personal/jaime"}],
            "facts": [{"content": "House fact.", "namespace": "hermes/house"}],
            "procedures": [], "namespace": "hermes/house", "scope_header": "Scope: hermes/house"})
    return "{}"


def wait():
    for _ in range(50):
        if all(not t.is_alive() for t in list(p._threads)):
            return
        time.sleep(0.02)


mod._call = fake

# The namespace comes from the profile home.
p = mod.MeminiProvider()
p.initialize("s1", hermes_home="/opt/data/profiles/house", platform="telegram", agent_context="primary")
assert p._namespace == "hermes/house", p._namespace
wait()
first = p.prefetch("hello")
assert "4 nodes" in first and "House fact." in first, "the first turn gets the briefing"
assert "Claude Code" not in first and "{" not in first, "only Hermes memories, as lines"
assert p.prefetch("hello") == "", "a prefetch result is used once"

p.queue_prefetch("where does Jaime live")
wait()
got = p.prefetch("where does Jaime live")
assert "Jaime lives in Spain." in got and "light.office" in got, got
assert "Dracula" not in got, "memories of personal/jaime are not injected"
assert calls[-1][:2] == ("hermes/house", "memory_recall")

# A built-in memory write goes to memini: user facts for all Hermes agents, the others in the profile.
calls.clear()
p.on_memory_write("add", "user", "Jaime prefers short answers.")
p.on_memory_write("add", "memory", "The office light is light.office.")
p.on_memory_write("remove", "memory", "old")
p.on_memory_write("add", "memory", "   ")
wait()
saved = [(c[2]["content"], c[2].get("visibility")) for c in calls if c[1] == "memory_remember"]
assert saved == [("Jaime prefers short answers.", "hermes"), ("The office light is light.office.", None)], saved

# The root profile is default.
d = mod.MeminiProvider()
d.initialize("s2", hermes_home="/opt/data", platform="cli")
assert d._namespace == "hermes/default"

# A scheduled job or a subagent does not write.
calls.clear()
c = mod.MeminiProvider()
c.initialize("s3", hermes_home="/opt/data/profiles/kid", platform="cron", agent_context="cron")
c.on_memory_write("add", "memory", "x")
time.sleep(0.2)
assert not [x for x in calls if x[1] == "memory_remember"], "no write outside the primary agent"


# A failed call gives no context and no error.
def broken(namespace, tool, args):
    raise OSError("memini is down")


mod._call = broken
b = mod.MeminiProvider()
b.initialize("s4", hermes_home="/opt/data/profiles/house", platform="cli", agent_context="primary")
b.queue_prefetch("x")
b.on_memory_write("add", "memory", "y")
time.sleep(0.2)
assert b.prefetch("x") == ""

assert p.get_tool_schemas() == [] and p.name == "memini"
print("memini: all checks passed")
sys.exit(0)
