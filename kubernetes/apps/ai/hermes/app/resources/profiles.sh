#!/bin/sh
# Runs in the init container `profiles` before each start of Hermes.
# A persona is seeded once: the app owns it after that, so a Dashboard edit
# survives a redeploy. Only the keys that point at cluster paths are set at
# each start (see README.md, "Profiles from git").
set -eu

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
  hermes -p "$1" config set plugins.enabled '["task-tiers"]' >/dev/null
  hermes -p "$1" config set delegation.backend task-tiers >/dev/null
  # A clone copies the agents and tiers of default: start from an empty block.
  hermes -p "$1" config set delegation.backends.task-tiers '{}' >/dev/null
}

# seed_tiers NAME: the subagents use LiteLLM models, by the difficulty of the task.
seed_tiers() {
  t=delegation.backends.task-tiers
  use_task_tiers "$1"
  hermes -p "$1" config set $t.default standard >/dev/null
  hermes -p "$1" config set $t.tiers.light.model opr-free-light >/dev/null
  hermes -p "$1" config set $t.tiers.light.use "one read or one query, then a short summary" >/dev/null
  hermes -p "$1" config set $t.tiers.standard.model opr-free-strong >/dev/null
  hermes -p "$1" config set $t.tiers.standard.use "a diagnosis with several steps and tools" >/dev/null
  hermes -p "$1" config set $t.tiers.strong.model opr-free-strong >/dev/null
  hermes -p "$1" config set $t.tiers.strong.use "a long analysis of large logs or many resources, when time is not important" >/dev/null
}

# seed_agents NAME: the orchestrator gives tasks to these agents only. Each
# agent decides in its SOUL what it may do on a relayed request. Not personal:
# default has web_search, so mail that personal reads could leave in a URL.
seed_agents() {
  a=delegation.backends.task-tiers.agents
  use_task_tiers "$1"
  hermes -p "$1" config set $a.house.use "lights, scenes and media; the state of the house (sensors, temperature, presence)" >/dev/null
  hermes -p "$1" config set $a.research.use "research a topic with sources" >/dev/null
  hermes -p "$1" config set $a.infra.use "the health of the cluster and the network (read-only)" >/dev/null
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
  name=$1 token=$2 claude_dir=$3 model=$4 mcp=$5 description=$6 delegation=${7:-}
  if [ "$name" = default ]; then home=$HERMES_HOME; else home=$HERMES_HOME/profiles/$name; fi
  set_key() { hermes -p "$name" config set "$@" >/dev/null; }

  if [ ! -d "$home" ]; then
    # --no-skills: the skills that default wrote are its own.
    hermes profile create "$name" --clone-from default --no-alias --no-skills >/dev/null
  fi

  # Set at each start: these keys point at files and Secrets of the cluster.
  set_key secrets.command.command "$(secret_command "$token")"
  if [ "$token" != "-" ]; then
    copy_plugin "$home"
    set_key plugins.entries.claude-subscription-directsdk-experimental.settings.claude_config_dir "$claude_dir"
  fi
  [ -n "$delegation" ] && copy_task_tiers "$home"
  # The memini namespace of the profile. memini_hermes forwards it, and
  # memini adds the parent `hermes` and the personal namespace.
  set_key mcp_servers.Litellm.headers.X-Memini-Namespace "hermes/$name"
  # The MCP servers decide what the profile can reach, so git owns them.
  set_key mcp_servers.Litellm.headers.x-mcp-servers "$mcp"

  # Seeded once. Delete the marker file to seed the profile again.
  [ -e "$home/.seeded-from-git" ] && return 0
  cp "$SEEDS/soul-$name.md" "$home/SOUL.md"
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
    set_key delegation.backend default
    set_key plugins.enabled '[]'
    set_key delegation.backends.task-tiers '{}'
  fi
  hermes profile describe "$name" --text "$description" >/dev/null
  touch "$home/.seeded-from-git"
  echo "seeded profile $name"
}

T1=/mnt/secrets/claude/token
T2=/mnt/secrets/claude/token-2
FLASH=opr/deepseek-v4.1-flash

profile default "$T1" "$HERMES_HOME/.claude" opus \
  memini_hermes,notes,web_search \
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
profile house - - "$FLASH" \
  memini_hermes,notes,ha_mcp \
  "Home Assistant state, energy and automation proposals"
# memini next to a browser breaks the rule "no URL-fetch tool next to memini":
# Jaime accepted that risk for kid on 2026-11-24.
profile kid - - "$FLASH" \
  memini_hermes,browser_colegio \
  "School portal digest for the kids"
