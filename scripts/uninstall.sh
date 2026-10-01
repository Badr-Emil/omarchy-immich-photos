#!/bin/bash

# Removes what the installer of this plugin created, and nothing else.
#
# Photos, videos and the database are never deleted. An Immich installation
# that existed before the plugin and was only integrated is not touched at all.

set -euo pipefail

PLUGIN_ID="io.github.badr-emil.iphone-photos"
REPO_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd -P)
BACKEND="$REPO_DIR/backend/iphone-photos"
PLUGIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$PLUGIN_ID"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-iphone-photos"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-iphone-photos"
OWN_COMPOSE_DIR="$DATA_DIR/immich"
BIN_LINK="$HOME/.local/bin/iphone-photos"
APP_NAME="iPhone Photos"
LAUNCHER="${XDG_DATA_HOME:-$HOME/.local/share}/applications/$APP_NAME.desktop"

ask() {
  local answer default=$2
  read -r -p "$1 [$([[ $default == y ]] && echo Y/n || echo y/N)] " answer
  answer=${answer:-$default}
  [[ $answer =~ ^[YyJj] ]]
}

field() { "$BACKEND" status --json | python3 -c 'import json,sys; d=json.load(sys.stdin); v=d
for k in sys.argv[1].split("."): v=(v or {}).get(k)
print(v if v is not None else "")' "$1"; }

compose_dir=$(field composeDir)
media=$(field storage.path)
database=""
if [[ -n $compose_dir && -f $compose_dir/.env ]]; then
  database=$(sed -n 's/^DB_DATA_LOCATION=//p' "$compose_dir/.env")
fi

if ask "Remove the plugin from the Omarchy bar?" y; then
  omarchy plugin disable "$PLUGIN_ID" 2>/dev/null || true
  if [[ -L $PLUGIN_DIR ]]; then
    rm "$PLUGIN_DIR"
  elif [[ -d $PLUGIN_DIR ]]; then
    echo "The plugin folder is a git checkout; remove it with: omarchy plugin remove $PLUGIN_ID"
  fi
  # Only the command and the launcher that the installer created.
  if [[ -L $BIN_LINK && $(readlink -f "$BIN_LINK") == "$BACKEND" ]]; then
    rm "$BIN_LINK"
  fi
  if [[ -f $LAUNCHER ]] && grep -qx "X-Omarchy-Plugin=$PLUGIN_ID" "$LAUNCHER"; then
    omarchy-webapp-remove "$APP_NAME" >/dev/null
  fi
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  echo "Plugin removed."
fi

containers_removed=false
if [[ -z $compose_dir ]]; then
  :
elif [[ $compose_dir != "$OWN_COMPOSE_DIR" ]]; then
  echo "Immich in $compose_dir was not installed by this plugin and is left running."
elif ask "Stop and remove the Immich containers? (photos and database stay)" n; then
  # `down` without -v: named volumes and all bind-mounted data are kept.
  if [[ -r /var/run/docker.sock && -w /var/run/docker.sock ]]; then
    docker compose --project-directory "$compose_dir" down
  else
    sudo docker compose --project-directory "$compose_dir" down
  fi
  containers_removed=true
  echo "Containers removed. Images and the model cache remain; see README for how to remove them."
fi

if [[ -f $CONFIG_DIR/enabled-docker-at-boot ]]; then
  echo
  echo "The installer enabled docker.service at boot. Other containers on this"
  echo "machine may rely on that by now."
  if ask "Disable Docker at boot again?" n; then
    sudo systemctl disable docker.service
    rm -f "$CONFIG_DIR/enabled-docker-at-boot"
  fi
fi

if ask "Remove the plugin configuration and the stored API key?" n; then
  rm -f "$CONFIG_DIR/api-key" "$CONFIG_DIR/config.json" "$CONFIG_DIR/enabled-docker-at-boot"
  rmdir "$CONFIG_DIR" 2>/dev/null || true
  echo "Configuration removed."
  if $containers_removed; then
    echo
    echo "$compose_dir/.env holds the database password. Without it the existing"
    echo "database cannot be opened by a later installation."
    if ask "Remove the Immich compose folder including .env anyway?" n; then
      rm -f "$compose_dir/docker-compose.yml" "$compose_dir/.env"
      rmdir "$compose_dir" 2>/dev/null || true
      echo "Compose folder removed."
    fi
  fi
fi

cat <<EOF

Kept, and never deleted by this script:
  Photos and videos: ${media:-not configured}
  Database:          ${database:-not configured}
EOF
