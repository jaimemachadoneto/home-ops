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
    # $* names the key also after --force. Cut it: a value can be long JSON.
    echo "profiles: $prof: REQUIRED config set $(printf '%s' "$*" | cut -c1-80) failed: $out"
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

# copy_memini HOME: the memory provider memini (resources/memini). It recalls from memini
# before a turn and saves the built-in memory writes there.
copy_memini() {
  mkdir -p "$1/plugins/memini"
  cp /etc/hermes/memini-plugin.yaml "$1/plugins/memini/plugin.yaml"
  cp /etc/hermes/memini.py "$1/plugins/memini/__init__.py"
}

# seed_tiers NAME: the subagents use LiteLLM models, by the difficulty of the
# task. Seeded once, so a change in the Dashboard stays.
seed_tiers() {
  t=delegation.backends.task-tiers
  hset "$1" $t.default standard
  hset "$1" $t.tiers.light.model opr-free-light
  hset "$1" $t.tiers.light.use "one read or one query, then a short summary"
  hset "$1" $t.tiers.standard.model opr-free-strong
  hset "$1" $t.tiers.standard.use "a diagnosis with several steps and tools"
  hset "$1" $t.tiers.strong.model opr-free-strong
  hset "$1" $t.tiers.strong.use "a long analysis of large logs or many resources, when time is not important"
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

# profile NAME TOKEN CLAUDE_DIR MODEL MCP_SERVERS DESCRIPTION [SEED_TIERS]
# MODEL is a Claude model (sonnet, opus, haiku) on the subscription with
# LiteLLM as the fallback, or a LiteLLM model. SEED_TIERS (seed_tiers) seeds
# the model tiers of the subagents once.
profile() {
  # No dollar-brace expansion in this file: Flux substitutes it in the ConfigMap.
  name=$1 token=$2 claude_dir=$3 model=$4 mcp=$5 description=$6 delegation=
  [ $# -ge 7 ] && delegation=$7
  if [ "$name" = default ]; then home=$HERMES_HOME; else home=$HERMES_HOME/profiles/$name; fi
  set_key() { hset "$name" "$@"; }
  req_key() { hreq "$name" "$@"; }
  failed=0

  if [ ! -d "$home" ]; then
    # A clone also copies the skills of default; hermes does not allow
    # --no-skills with --clone-from.
    if ! out=$(hermes profile create "$name" --clone-from default --no-alias 2>&1); then
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
  copy_task_tiers "$home" || { echo "profiles: $name: REQUIRED task-tiers copy failed"; boundary_failed=1; }
  # web has no memory on purpose: a page that tricks it finds no private data.
  # The provider calls memini_hermes itself, past the x-mcp-servers list, so
  # this setting is the boundary for web: a failure stops Hermes. A copied
  # plugins/memini folder does nothing while the setting is builtin.
  if [ "$name" = web ]; then
    req_key memory.provider builtin
  else
    copy_memini "$home" || { echo "profiles: $name: memini copy failed"; failed=1; }
    set_key memory.provider memini
  fi
  # Whisper detects the language. With `en`, it translates a Portuguese voice note to English.
  set_key stt.language ""
  # The SOUL holds the rules for relayed requests and approvals, so git owns
  # it: the agent part, then the shared parts. web has no memory and gives
  # no tasks, and kid has its own memory part.
  case $name in
    web) parts= ;;
    kid) parts=$SEEDS/shared-agents.md ;;
    *) parts="$SEEDS/shared-memory.md $SEEDS/shared-agents.md" ;;
  esac
  # shellcheck disable=SC2086 # parts is a list of paths without spaces.
  if ! (cat "$SEEDS/soul-$name.md" && for p in $parts; do echo && cat "$p" || exit 1; done) >"$home/SOUL.md.new" ||
    ! mv "$home/SOUL.md.new" "$home/SOUL.md"; then
    echo "profiles: $name: REQUIRED SOUL copy failed"
    boundary_failed=1
  fi
  # The memini namespace of the profile. memini_hermes forwards it, and
  # memini adds the parent `hermes` and the personal namespace.
  req_key mcp_servers.Litellm.headers.X-Memini-Namespace "hermes/$name"
  # The MCP servers decide what the profile can reach, so git owns them.
  req_key mcp_servers.Litellm.headers.x-mcp-servers "$mcp"

  # Seeded once. Delete the marker file to seed the profile again.
  [ -e "$home/.seeded-from-git" ] && return 0
  case $model in
    sonnet | opus | haiku)
      set_key model.provider claude-subscription-directsdk-experimental
      set_key model.default "$model"
      set_key model.base_url ""
      set_key fallback_model.provider litellm
      set_key fallback_model.model "$FLASH"
      set_key fallback_model.base_url "$LITELLM"
      set_key fallback_model.key_env LITELLM_API_KEY
      ;;
    *)
      set_key model.provider litellm
      set_key model.default "$model"
      set_key model.base_url "$LITELLM"
      # A clone copies the fallback of default: set it here too.
      set_key fallback_model.provider litellm
      set_key fallback_model.model "$FLASH"
      set_key fallback_model.base_url "$LITELLM"
      set_key fallback_model.key_env LITELLM_API_KEY
      ;;
  esac
  [ -n "$delegation" ] && "$delegation" "$name"
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
FLASH=opr/deepseek-v4.1-flash-1017

profile default "$T1" "$HERMES_HOME/.claude" opus \
  memini_hermes,notes \
  "Chief of staff: plans, routes work to the other profiles, morning brief"
# No URL-fetch tool here: mail is untrusted text, and with web_search an agent
# could send mail or memory data to any URL.
profile personal "$T1" "$HERMES_HOME/.claude" sonnet \
  memini_hermes,notes,outlook,paperless \
  "Personal assistant: mail, calendar, documents and personal tasks"
profile dev "$T2" "$HERMES_HOME/.claude-2" opus \
  memini_hermes,notes,context7,kubesearch,web_search,flux,kubectl,victorialogs \
  "Software engineering in the sandbox, PRs, tests"
profile infra "$T1" "$HERMES_HOME/.claude" opus \
  memini_hermes,notes,flux,flux_ops,victorialogs,kubectl,unifi_network \
  "Cluster and network health and urgent actions; plans on opus, subagents on LiteLLM" \
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
# browser_colegio is the Outlook driver of browser-sessions, not a browser: it
# cannot open links, so it is no URL-fetch tool next to memini.
profile kid - - "$FLASH" \
  memini_hermes,browser_colegio \
  "School mailbox of the kids"

# The built-in tools of each profile, on every platform. A platform without an
# entry gets all tools, so the list names each platform that Hermes knows.
# MCP tools are not in this list: x-mcp-servers above sets them.
PLATFORMS="a2a api_server bluebubbles buzz cli cron dingtalk discord email feishu google_chat irc line matrix mattermost ntfy photon qqbot raft signal simplex slack sms teams telegram webhook wecom wecom_callback weixin whatsapp whatsapp_cloud"
# No tool here reaches the internet. `connections` is not in the list: it
# manages connections to outside services.
BASE="clarify cronjob delegation image_gen memory session_search skills todo tts vision"
# The shell runs in the sandbox, which reaches the internet only with the
# allowance "internet" (config.yaml). A child of a hand-off gets only the
# built-in tools of its parent, so a profile that hands work to dev keeps the shell.
SHELL_TOOLS="$BASE terminal file code_execution"

# toolsets PROFILE TOOLSET...: a boundary setting, so a failure stops Hermes.
toolsets() {
  prof=$1
  shift
  list= sep=
  for t in "$@"; do list="$list$sep\"$t\"" sep=,; done
  map= sep=
  for p in $PLATFORMS; do map="$map$sep\"$p\":[$list]" sep=,; done
  # --force: a profile already has this section, and config set replaces a
  # whole section only with --force.
  hreq "$prof" --force platform_toolsets "{$map}"
}

# shellcheck disable=SC2086 # Each list is one toolset for each word.
{
  toolsets default $SHELL_TOOLS
  toolsets infra $SHELL_TOOLS
  toolsets dev $SHELL_TOOLS web browser
  toolsets personal $BASE
  toolsets research $BASE
  toolsets web $BASE
  toolsets house $BASE
  toolsets kid $BASE
}

# handoffs PROFILE AGENTS_JSON: the agents that the profile can give a task
# to, a boundary setting at each start. Each agent decides in its SOUL what it
# does on a relayed request. A child runs as its own profile and reads its own
# list, and max_spawn_depth 2 stops a chain after two steps, so a loop such as
# personal, kid, personal cannot go on. A profile with no agents and no tiers
# gives its subagents its own model.
handoffs() {
  hreq "$1" plugins.enabled '["task-tiers"]'
  hreq "$1" delegation.backend task-tiers
  hreq "$1" --force delegation.backends.task-tiers.agents "$2"
  hreq "$1" delegation.max_spawn_depth 2
}

handoffs default '{
  "personal": {"use": "mail, calendar and documents of Jaime: read, drafts, add an event; with an approval, a reply on a thread or a change of an event"},
  "kid": {"use": "the school mailbox: open items, messages, draft replies; with an approval, a message to the school"},
  "house": {"use": "lights, scenes and media; the state of the house (sensors, temperature, presence); with an approval, a lock, the alarm or the heating"},
  "infra": {"use": "the cluster and the network: diagnosis, health, the check of a rollout, a reconcile or a pod restart; with an approval, a suspend or a resume"},
  "dev": {"use": "code, fixes and deployments as a PR in the sandbox; with an approval, a release tag"},
  "research": {"use": "research and lessons with sources"},
  "web": {"use": "a web search: a short answer with the links"}
}'
handoffs personal '{"kid": {"use": "school information: dates, tasks, what a school message says (read only)"}}'
handoffs kid '{"personal": {"use": "add a school date, task or note about the kids to the calendar or the notes"}}'
# No dev to infra: a child gets the built-in tools of its parent, so infra
# would run with the web tools of dev next to the cluster and network data.
handoffs dev '{}'
handoffs infra '{"dev": {"use": "a lasting fix as a PR in git, with the diagnosis and the proposed change"}}'
handoffs research '{}'
handoffs web '{}'
handoffs house '{}'

if [ "$boundary_failed" != 0 ]; then
  echo "profiles: a REQUIRED setting failed (see above); Hermes does not start"
  exit 1
fi
