#!/bin/bash

# Installs Immich with the official Docker Compose files and adds the
# Immich Photos plugin to the Omarchy bar. An existing Immich installation is
# detected and integrated, never replaced.
#
#   ./scripts/install.sh                  interactive
#   ./scripts/install.sh --media PATH     skip the storage question
#   ./scripts/install.sh --yes            accept the defaults

set -euo pipefail

PLUGIN_ID="io.github.badr-emil.immich-photos"
REPO_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd -P)
BACKEND="$REPO_DIR/backend/immich-photos"
PLUGIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$PLUGIN_ID"
BIN_LINK="$HOME/.local/bin/immich-photos"
APP_NAME="Immich Photos"
LAUNCHER="${XDG_DATA_HOME:-$HOME/.local/share}/applications/$APP_NAME.desktop"
STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-immich-photos"

MEDIA=""
ASSUME_YES=false

while (($#)); do
  case $1 in
    --media) MEDIA=${2:?--media needs a path}; shift 2 ;;
    --yes | -y) ASSUME_YES=true; shift ;;
    -h | --help) sed -n '3,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
done

step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\nError: %s\n' "$*" >&2; exit 1; }

confirm() {
  local answer
  $ASSUME_YES && return 0
  read -r -p "$1 [Y/n] " answer
  [[ -z $answer || $answer =~ ^[YyJj] ]]
}

state() { "$BACKEND" status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }

step "1/9  Omarchy"
command -v omarchy >/dev/null && grep -q '^ID=omarchy$' /etc/os-release \
  || fail "This installer is made for Omarchy."
echo "Omarchy $(omarchy version)"
command -v python3 >/dev/null || fail "python3 is missing: omarchy pkg add python"

step "2/9  System requirements"
ram_gb=$(awk '/MemTotal/ {printf "%d", $2 / 1024 / 1024 + 0.5}' /proc/meminfo)
cores=$(nproc)
echo "Memory: ${ram_gb} GB (Immich needs 6, recommends 8)"
echo "CPU:    ${cores} cores (Immich needs 2, recommends 4)"
((ram_gb >= 4)) || fail "Less than 4 GB of memory is not enough for Immich."
((ram_gb >= 6)) || echo "Warning: below 6 GB, uploads can be slow. Consider disabling machine learning in Immich."
if [[ $(uname -m) == x86_64 ]] && ! grep -qw sse4_2 /proc/cpuinfo; then
  fail "Immich 3 needs a CPU with x86-64-v2 (SSE4.2). This CPU is too old."
fi
if ! command -v qrencode >/dev/null; then
  pacman -Si qrencode >/dev/null 2>&1 || fail "The package qrencode was not found in the repositories."
  echo "qrencode (official Arch package) draws the QR code for the phone."
  confirm "Install qrencode?" && omarchy pkg add qrencode
fi

step "3/9  Docker"
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  for package in docker docker-compose; do
    pacman -Si "$package" >/dev/null 2>&1 || fail "The package $package was not found in the repositories."
  done
  echo "Docker Engine and the Compose plugin are missing (official Arch packages docker, docker-compose)."
  confirm "Install them now?" || fail "Immich needs Docker."
  omarchy pkg add docker docker-compose
fi
echo "Docker Engine $(docker --version | sed -E 's/.*version ([^,]+).*/\1/')"
echo "Docker Compose $(docker compose version --short)"

step "4/9  Existing Immich"
if [[ $(state installed) == True ]]; then
  compose_dir=$(state composeDir)
  echo "Found an Immich installation in $compose_dir."
  echo "It is used as it is. Nothing is reinstalled or overwritten."
  "$BACKEND" integrate "$compose_dir"
else
  # Containers are only visible to root on Omarchy, so ask once.
  echo "Checking Docker for Immich containers (needs your password)."
  if sudo docker ps -a --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -qi immich; then
    echo "Docker already has Immich containers, but their compose folder was not found."
    echo "Find it with:  sudo docker compose ls -a"
    echo "Then run:      $BACKEND integrate <folder>   and start this installer again."
    exit 3
  fi
  echo "None found."

  step "5/9  Storage location"
  default_media="$HOME/Pictures/Immich"
  while true; do
    if [[ -z $MEDIA ]]; then
      if $ASSUME_YES; then
        MEDIA=$default_media
      else
        read -r -e -p "Where should photos and videos be stored? [$default_media] " MEDIA
        MEDIA=${MEDIA:-$default_media}
      fi
    fi
    MEDIA=${MEDIA/#\~/$HOME}
    if "$BACKEND" storage check "$MEDIA"; then
      confirm "Use $MEDIA?" && break
    else
      $ASSUME_YES && fail "The storage location $MEDIA is not usable."
    fi
    MEDIA=""
  done

  step "6/9  Immich configuration"
  echo "Downloading docker-compose.yml and example.env of the pinned Immich release (checksum verified)."
  "$BACKEND" setup --media "$MEDIA"
fi

step "7/9  Start"
if ! systemctl is-enabled --quiet docker.service; then
  cat <<'EOF'
Docker currently starts only when something uses it. For Immich to come back
after a reboot, the Docker service has to start at boot.

  Change:  sudo systemctl enable --now docker.service
  File:    /etc/systemd/system/multi-user.target.wants/docker.service (symlink)
  Undo:    sudo systemctl disable docker.service
EOF
  if confirm "Enable Docker at boot?"; then
    sudo systemctl enable --now docker.service
    # Remembered so the uninstaller can offer to undo exactly this change.
    mkdir -p "$STATE_DIR" && touch "$STATE_DIR/enabled-docker-at-boot"
  else
    echo "Skipped. After a reboot, start Immich with: immich-photos server start"
  fi
fi
if [[ $(state state) == online || $(state state) == busy ]]; then
  echo "Immich is already running."
else
  echo "Starting Immich. The first start downloads about 3 GB of images."
  "$BACKEND" server start
fi

step "8/9  Firewall"
if systemctl is-active --quiet ufw; then
  if grep -q 'BEGIN UFW AND DOCKER' /etc/ufw/after.rules 2>/dev/null; then
    cat <<'EOF'
ufw is active with Omarchy's Docker rules. They let devices in your home
network (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16) reach port 2283/tcp and
drop everything else, including the internet. No rule needs to be changed.
EOF
  else
    cat <<'EOF'
ufw is active, but without the ufw-docker rules. Docker publishes port
2283/tcp past ufw, so it is reachable from every network this PC is in.
Nothing was changed. To restrict it to private networks: sudo ufw-docker install
EOF
  fi
elif systemctl is-active --quiet firewalld; then
  echo "firewalld is active. If the phone cannot connect, allow 2283/tcp in the zone of your home network."
else
  echo "No active firewall found. Port 2283/tcp is reachable from every network this PC is in."
fi

step "9/9  Omarchy plugin"
if [[ $(readlink -f "$PLUGIN_DIR" 2>/dev/null) != "$REPO_DIR" ]]; then
  [[ ! -e $PLUGIN_DIR ]] || fail "$PLUGIN_DIR exists and belongs to something else."
  mkdir -p "$(dirname "$PLUGIN_DIR")"
  ln -s "$REPO_DIR" "$PLUGIN_DIR"
fi
omarchy plugin validate "$REPO_DIR"
echo "Plugin manifest is valid."
mkdir -p "$(dirname "$BIN_LINK")"
# Never replace a command of the same name that belongs to something else.
if [[ ! -e $BIN_LINK && ! -L $BIN_LINK ]]; then
  ln -s "$BACKEND" "$BIN_LINK"
elif [[ $(readlink -f "$BIN_LINK") != "$BACKEND" ]]; then
  echo "$BIN_LINK already exists and is left alone. Use $BACKEND directly."
fi
if omarchy-shell shell ping >/dev/null 2>&1; then
  omarchy-shell shell rescanPlugins >/dev/null
  if ! omarchy plugin list --json | grep -q "\"$PLUGIN_ID\"" \
    || ! grep -q "\"$PLUGIN_ID\"" "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json"; then
    omarchy plugin enable "$PLUGIN_ID"
  fi
  echo "The plugin is in the bar."
else
  echo "The Omarchy shell is not running. Enable the plugin later with: omarchy plugin enable $PLUGIN_ID"
fi

# Launcher entry that opens the gallery in its own window, like any other app.
# An existing launcher of that name is kept; ours is marked so the uninstaller
# removes only what was created here.
if [[ ! -e $LAUNCHER ]]; then
  port=$("$BACKEND" status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["server"]["port"])')
  if omarchy-webapp-install "$APP_NAME" "http://localhost:$port" "http://localhost:$port/apple-icon-180.png" >/dev/null; then
    echo "X-Omarchy-Plugin=$PLUGIN_ID" >>"$LAUNCHER"
    echo "\"$APP_NAME\" is in the app launcher."
  fi
fi

step "Status"
"$BACKEND" status || true

step "Connect your phone"
if url=$("$BACKEND" address --qr); then
  cat <<EOF

  1. On this PC, open http://localhost:${url##*:} and create your account
     (the first account becomes the administrator).
  2. Install the Immich app on your phone (App Store or Google Play).
  3. Enter the server address above or scan the QR code in the app.
     It contains only the address, no password.
  4. Log in, open Backup, choose the albums, turn Backup on.

The phone has to be in the same Wi-Fi. iOS and Android decide when apps may work in the
background; the backup is reliable while the Immich app is open.

Your photos are stored on a single disk. Read docs/backup.md.
EOF
fi
