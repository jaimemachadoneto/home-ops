#!/bin/sh
# Runs in the init container `profiles` before each start of Hermes.
# A persona is seeded once: the app owns it after that, so a Dashboard edit
# survives a redeploy. Only the keys that point at cluster paths are set at
# each start (see README.md, "Profiles from git").
# Not -e: a failed persona setting (model, description) must not stop Hermes.
# hset logs it, and the profile is not marked as seeded, so the next start
# tries again. A failed boundary setting (what a profile can reach) is
# different: hreq logs it, and the script exits 1 at the end, so that Hermes
# does not start with a profile that kept the settings of default.
set -u
failed=0
boundary_failed=0

# hset PROFILE KEY VALUE: one `hermes config set`, logged when it fails.
hset() {
  prof=$1
  shift
  if ! out=$(hermes -p "$prof" config set "$@" 2>&1); then
    echo "profiles: $prof: config set $1 failed: $out"
    failed=1
  fi
  return 0
}

# hreq PROFILE KEY VALUE: a boundary setting. A failure stops Hermes.
hreq() {
  prof=$1
  shift
  if ! out=$(hermes -p "$prof" config set "$@" 2>&1); then
    echo "profiles: $prof: REQUIRED config set $1 failed: $out"
    boundary_failed=1
  fi
  return 0
}

SEEDS=/etc/hermes-personas
LITELLM=http://litellm.ai.svc.cluster.local:4000/v1
PLUGIN=claude-subscription-directsdk

# shortcut: Hermes reads a bundled model-provider plugin only from
# model-providers/ and hermes-k8s ships it one level up. Remove this copy
# when the hermes-k8s image ships it in model-providers/.
copy_plugin() {
  rm -rf "$1/plugins/$PLUGIN"
  mkdir -p "$1/plugins"
  cp -r "$HERMES_BUNDLED_PLUGINS/$PLUGIN" "$1/plugins/$PLUGIN"
  # The Nix store is read-only, and Hermes cannot stage a read-only copy.
  chmod -R u+w "$1/plugins/$PLUGIN"
}

# The delegation backend task-tiers (resources/task-tiers): the orchestrator
# selects a model for each subagent task.
copy_task_tiers() {
  mkdir -p "$1/plugins/task-tiers"
  cp /etc/hermes/task-tiers-plugin.yaml "$1/plugins/task-tiers/plugin.yaml"
  cp /etc/hermes/task-tiers.py "$1/plugins/task-tiers/__init__.py"
}

# use_task_tiers NAME: turn on the backend. `hermes plugins enable` fails in
# this image (it reads uv.lock), so the list is set directly.
use_task_tiers() {
  hreq "$1" plugins.enabled '["task-tiers"]'
  hreq "$1" delegation.backend task-tiers
  # A clone copies the agents and tiers of default: start from an empty block.
  hreq "$1" delegation.backends.task-tiers '{}'
}

# seed_tiers NAME: the subagents use LiteLLM models, by the difficulty of the task.
seed_tiers() {
  t=delegation.backends.task-tiers
  use_task_tiers "$1"
  hset "$1" $t.default standard
  hset "$1" $t.tiers.light.model opr-free-light
  hset "$1" $t.tiers.light.use "one read or one query, then a short summary"
  hset "$1" $t.tiers.standard.model opr-free-strong
  hset "$1" $t.tiers.standard.use "a diagnosis with several steps and tools"
  hset "$1" $t.tiers.strong.model opr-free-strong
  hset "$1" $t.tiers.strong.use "a long analysis of large logs or many resources, when time is not important"
}

# seed_agents NAME: the orchestrator gives tasks to these agents only. Each
# agent decides in its SOUL what it may do on a relayed request. default reads
# mail through personal and web can open a URL: Jaime accepted on 2026-11-24
# that only the SOULs keep mail text out of the tasks for web.
seed_agents() {
  a=delegation.backends.task-tiers.agents
  use_task_tiers "$1"
  hreq "$1" $a.house.use "lights, scenes and media; the state of the house (sensors, temperature, presence)"
  hreq "$1" $a.web.use "a web search: a short answer with the links"
  hreq "$1" $a.infra.use "the health of the cluster and the network (read-only)"
  hreq "$1" $a.personal.use "read mail, calendar and documents; drafts; add a calendar event"
}

# seed_kid_agents NAME: kid can only give calendar items to default.
seed_kid_agents() {
  use_task_tiers "$1"
  hreq "$1" delegation.backends.task-tiers.agents.default.use "add school dates and tasks to the calendar of Jaime"
}

# The secret command of a profile. $1 is the Claude token file, or "-" for a
# profile with no Claude account.
secret_command() {
  echo "set -eu"
  echo "printf 'LITELLM_API_KEY='"
  echo "/bin/cat /mnt/secrets/litellm/key"
  if [ "$1" != "-" ]; then
    echo "if [ -r $1 ]; then"
    echo "  printf '\\nCLAUDE_CODE_OAUTH_TOKEN='"
    echo "  /bin/cat $1"
    echo "fi"
  fi
  echo "printf '\\n'"
}

# profile NAME TOKEN CLAUDE_DIR MODEL MCP_SERVERS DESCRIPTION [SEED_DELEGATION]
# MODEL is a Claude model (sonnet, opus, haiku) on the subscription with
# LiteLLM as the fallback, or a LiteLLM model. SEED_DELEGATION (seed_tiers or
# seed_agents) installs the backend task-tiers and seeds its settings.
profile() {
  # No dollar-brace expansion in this file: Flux substitutes it in the ConfigMap.
  name=$1 token=$2 claude_dir=$3 model=$4 mcp=$5 description=$6 delegation=
  [ $# -ge 7 ] && delegation=$7
  if [ "$name" = default ]; then home=$HERMES_HOME; else home=$HERMES_HOME/profiles/$name; fi
  set_key() { hset "$name" "$@"; }
  req_key() { hreq "$name" "$@"; }
  failed=0

  if [ ! -d "$home" ]; then
    # --no-skills: the skills that default wrote are its own.
    if ! out=$(hermes profile create "$name" --clone-from default --no-alias --no-skills 2>&1); then
      echo "profiles: $name: profile create failed: $out"
      return 0
    fi
  fi

  # Set at each start: these keys point at files and Secrets of the cluster.
  req_key secrets.command.command "$(secret_command "$token")"
  if [ "$token" != "-" ]; then
    copy_plugin "$home" || { echo "profiles: $name: REQUIRED Claude plugin copy failed"; boundary_failed=1; }
    req_key plugins.entries.claude-subscription-directsdk-experimental.settings.claude_config_dir "$claude_dir"
  fi
  if [ -n "$delegation" ]; then
    copy_task_tiers "$home" || { echo "profiles: $name: REQUIRED task-tiers copy failed"; boundary_failed=1; }
  fi
  # The memini namespace of the profile. memini_hermes forwards it, and
  # memini adds the parent `hermes` and the personal namespace.
  req_key mcp_servers.Litellm.headers.X-Memini-Namespace "hermes/$name"
  # The MCP servers decide what the profile can reach, so git owns them.
  req_key mcp_servers.Litellm.headers.x-mcp-servers "$mcp"

  # Seeded once. Delete the marker file to seed the profile again.
  [ -e "$home/.seeded-from-git" ] && return 0
  cp "$SEEDS/soul-$name.md" "$home/SOUL.md" || { echo "profiles: $name: SOUL copy failed"; failed=1; }
  case $model in
    sonnet | opus | haiku)
      set_key model.provider claude-subscription-directsdk-experimental
      set_key model.default "$model"
      set_key model.base_url ""
      set_key fallback_model.provider litellm
      set_key fallback_model.model opr/deepseek-v4.1-flash
      set_key fallback_model.base_url "$LITELLM"
      set_key fallback_model.key_env LITELLM_API_KEY
      ;;
    *)
      set_key model.provider litellm
      set_key model.default "$model"
      set_key model.base_url "$LITELLM"
      ;;
  esac
  if [ -n "$delegation" ]; then
    "$delegation" "$name"
  else
    # A clone copies the delegation settings of default.
    req_key delegation.backend default
    req_key plugins.enabled '[]'
    req_key delegation.backends.task-tiers '{}'
  fi
  hermes profile describe "$name" --text "$description" >/dev/null 2>&1 || echo "profiles: $name: describe failed"
  if [ "$failed" = 0 ]; then
    touch "$home/.seeded-from-git"
    echo "seeded profile $name"
  else
    echo "profiles: $name: not marked as seeded; the next start tries again"
  fi
}

T1=/mnt/secrets/claude/token
T2=/mnt/secrets/claude/token-2
FLASH=opr/deepseek-v4.1-flash

profile default "$T1" "$HERMES_HOME/.claude" opus \
  memini_hermes,notes \
  "Chief of staff: plans, routes work to the other profiles, morning brief" \
  seed_agents
# No URL-fetch tool here: mail is untrusted text, and with web_search an agent
# could send mail or memory data to any URL.
profile personal "$T1" "$HERMES_HOME/.claude" sonnet \
  memini_hermes,notes,outlook,paperless \
  "Personal assistant: mail, calendar, documents and personal tasks"
profile dev "$T2" "$HERMES_HOME/.claude-2" opus \
  memini_hermes,notes,context7,kubesearch,web_search \
  "Software engineering in the sandbox, PRs, tests"
profile infra "$T1" "$HERMES_HOME/.claude" opus \
  memini_hermes,notes,flux,victorialogs,kubectl,unifi_network \
  "Read-only cluster and network health; plans on opus, subagents on LiteLLM" \
  seed_tiers
profile research - - opr-free-strong \
  memini_hermes,notes,web_search,context7 \
  "Research and lessons with sources"
# No memory: a page that tricks web finds no private data here.
profile web - - opr-free-strong \
  web_search \
  "Web search for default: short answers with sources"
profile house - - "$FLASH" \
  memini_hermes,notes,ha_mcp \
  "Home Assistant state, energy and automation proposals"
# memini next to a browser breaks the rule "no URL-fetch tool next to memini":
# Jaime accepted that risk for kid on 2026-11-24.
profile kid - - "$FLASH" \
  memini_hermes,browser_colegio \
  "School portal digest for the kids" \
  seed_kid_agents

if [ "$boundary_failed" != 0 ]; then
  echo "profiles: a REQUIRED setting failed (see above); Hermes does not start"
  exit 1
fi
