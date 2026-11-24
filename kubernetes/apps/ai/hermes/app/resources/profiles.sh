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

# profile NAME TOKEN CLAUDE_DIR MODEL MCP_SERVERS DESCRIPTION
# MODEL is a Claude model (sonnet, opus, haiku) on the subscription with
# LiteLLM as the fallback, or a LiteLLM model.
profile() {
  name=$1 token=$2 claude_dir=$3 model=$4 mcp=$5 description=$6
  if [ "$name" = default ]; then home=$HERMES_HOME; else home=$HERMES_HOME/profiles/$name; fi
  set_key() { hermes -p "$name" config set "$@" >/dev/null; }

  if [ ! -d "$home" ]; then
    hermes profile create "$name" --clone-from default --no-alias >/dev/null
  fi

  # Set at each start: these keys point at files and Secrets of the cluster.
  set_key secrets.command.command "$(secret_command "$token")"
  if [ "$token" != "-" ]; then
    copy_plugin "$home"
    set_key plugins.entries.claude-subscription-directsdk-experimental.settings.claude_config_dir "$claude_dir"
  fi

  # Seeded once. Delete the marker file to seed the profile again.
  [ -e "$home/.seeded-from-git" ] && return 0
  cp "$SEEDS/soul-$name.md" "$home/SOUL.md"
  set_key mcp_servers.Litellm.headers.x-mcp-servers "$mcp"
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
  hermes profile describe "$name" --text "$description" >/dev/null
  touch "$home/.seeded-from-git"
  echo "seeded profile $name"
}

T1=/mnt/secrets/claude/token
T2=/mnt/secrets/claude/token-2
FLASH=opr/deepseek-v4.1-flash

profile default "$T1" "$HERMES_HOME/.claude" sonnet \
  memini,notes,web_search,paperless,outlook \
  "John, chief of staff: plans, routes work to the other profiles, morning brief"
profile dev "$T2" "$HERMES_HOME/.claude-2" opus \
  memini,notes,context7,kubesearch,web_search \
  "Dev: software engineering in the sandbox, PRs, tests"
profile jeff - - "$FLASH" \
  memini,notes,flux,victorialogs,kubectl,unifi_network \
  "Jeff, chief IT: read-only cluster and network health"
profile jena - - "$FLASH" \
  memini,notes,web_search,context7 \
  "Jena, tutor: daily lessons with sources"
profile home - - "$FLASH" \
  memini,notes,ha_mcp \
  "Home: Home Assistant state, energy and automation proposals"
profile laura - - "$FLASH" \
  memini,notes,outlook,browser_colegio \
  "Laura: school mail and portal digest for the kids"
