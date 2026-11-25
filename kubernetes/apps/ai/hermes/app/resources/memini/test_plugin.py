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
    if tool == "memory_recall" and args.get("response_format") == "detailed":
        # The lookup of a stale copy: the same text in many places, only one of them ours.
        same = [
            {"id": "own", "content": "Old fact.", "namespace": "hermes/house"},
            {"id": "other-profile", "content": "Old fact.", "namespace": "hermes/kid"},
            {"id": "near", "content": "Old fact. And more.", "namespace": "hermes/house"},
        ]
        if args.get("tags") == ["hermes"]:
            same = [{"id": "jaime-hermes", "content": "Jaime likes tea.", "namespace": "personal/jaime"}]
        else:
            same.append({"id": "claude-code", "content": "Jaime likes tea.", "namespace": "personal/jaime"})
        return json.dumps({"results": same})
    if tool == "memory_recall" and args.get("tags") == ["hermes"]:
        return json.dumps({"results": [
            {"id": "t1", "content": "Jaime prefers short answers.", "namespace": "personal/jaime"},
            {"id": "h2", "content": "Jaime lives in Spain.", "namespace": "hermes"},
        ]})
    if tool == "memory_recall":
        return json.dumps({"results": [
            {"id": "c1", "content": "Jaime uses the Dracula theme.", "namespace": "personal/jaime"},
            {"id": "h1", "content": "The office light is light.office.", "namespace": "hermes/house"},
            {"id": "h2", "content": "Jaime lives in Spain.", "namespace": "hermes"},
        ]})
    if tool == "memory_briefing" and args.get("scope") == "project":
        # memini answers with the memories of the namespace in the header only.
        content = {"hermes": "The home cluster has 4 nodes.", "hermes/house": "House fact."}[namespace]
        return json.dumps({"pinned": [], "facts": [{"content": content}], "procedures": []})
    if tool == "memory_briefing":
        return json.dumps({"pinned": [{"content": "A Claude Code rule.", "namespace": "personal/jaime"}]})
    if tool == "memory_list":
        assert args == {"namespace": "personal/jaime", "tags": ["hermes"], "limit": 5}, args
        return json.dumps({"memories": [{"content": "Jaime drinks tea.", "namespace": "personal/jaime"}]})
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
assert "Jaime drinks tea." in first, "the briefing has the Hermes facts about Jaime"
assert "Claude Code" not in first and "{" not in first, "only Hermes memories, as lines"
assert p.prefetch("hello") == "", "a prefetch result is used once"

p.queue_prefetch("where does Jaime live")
wait()
got = p.prefetch("where does Jaime live")
assert "Jaime lives in Spain." in got and "light.office" in got, got
assert "Dracula" not in got, "untagged memories of personal/jaime are not injected"
assert "short answers" in got, "a Hermes fact in personal/jaime is injected"
assert got.count("Spain") == 1, "a memory in both recalls is injected once"
assert [c[:2] for c in calls[-2:]] == [("hermes/house", "memory_recall")] * 2

# A built-in memory write goes to memini: user facts to personal/jaime, the others to the profile.
calls.clear()
p.on_memory_write("add", "user", "Jaime prefers short answers.")
p.on_memory_write("add", "memory", "The office light is light.office.")
p.on_memory_write("remove", "memory", "old")
p.on_memory_write("add", "memory", "   ")
wait()
saved = [(c[2]["content"], c[2].get("visibility"), c[2].get("tags"), c[2].get("tier"))
         for c in calls if c[1] == "memory_remember"]
assert saved == [("Jaime prefers short answers.", "personal", ["hermes"], "semantic"),
                 ("The office light is light.office.", None, None, "semantic")], saved

# A remove forgets only the copy that the provider saved: same text, same namespace.
calls.clear()
p.on_memory_write("remove", "memory", "", {"previous_content": "Old fact."})
wait()
forgets = [c[2] for c in calls if c[1] == "memory_forget"]
assert forgets == [{"id": "own", "namespace": "hermes/house"}], forgets
assert not [c for c in calls if c[1] == "memory_remember"]

# A user fact is forgotten only with the tag hermes: a Claude Code memory with the same text stays.
calls.clear()
p.on_memory_write("remove", "user", "", {"previous_content": "Jaime likes tea."})
wait()
forgets = [c[2] for c in calls if c[1] == "memory_forget"]
assert forgets == [{"id": "jaime-hermes", "namespace": "personal/jaime"}], forgets

# A replace forgets the old copy, then saves the new text.
calls.clear()
p.on_memory_write("replace", "memory", "New fact.", {"previous_content": "Old fact."})
wait()
order = [c[1] for c in calls if c[1] in ("memory_forget", "memory_remember")]
assert order == ["memory_forget", "memory_remember"], order
assert calls[-1][2] == {"content": "New fact.", "tier": "semantic"}

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


# The first turn comes right after initialize: prefetch waits for a slow briefing.
def slow(namespace, tool, args):
    time.sleep(0.5)
    return fake(namespace, tool, args)


mod._call = slow
s = mod.MeminiProvider()
s.initialize("s5", hermes_home="/opt/data/profiles/house", platform="cli", agent_context="primary")
assert "House fact." in s.prefetch("hello"), "the first prefetch waits for the briefing"
mod._call = fake


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
