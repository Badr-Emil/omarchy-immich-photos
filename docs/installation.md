# Installation

## Requirements

- Omarchy 4 with the Omarchy shell running
- 6 GB of memory (8 recommended), 2 CPU cores (4 recommended), x86-64-v2
- Docker Engine and the Compose plugin (Arch packages `docker`, `docker-compose`)
- `python`, `qrencode` (both in the official repositories)

Nothing comes from the AUR.

## Steps

```bash
omarchy plugin add https://github.com/Badr-Emil/omarchy-immich-photos
omarchy plugin enable io.github.badr-emil.immich-photos
~/.config/omarchy/plugins/io.github.badr-emil.immich-photos/scripts/install.sh
```

The panel's "Set up Immich" button starts the same installer in a terminal.
It explains every system change and asks before making it:

1. detects Omarchy, checks memory and CPU
2. checks Docker and Compose and offers to install the packages
3. looks for an existing Immich installation; if there is one, it is
   integrated and nothing is installed again
4. asks for the storage location and checks it (see `storage.md`)
5. downloads the official compose file and `example.env` of the Immich release
   pinned in the plugin and checks both against stored SHA-256 hashes
6. writes `.env` with a random database password (mode 600)
7. on request, enables `docker.service` at boot
8. starts Immich and waits until the server answers
9. explains the firewall situation without changing any rule
10. links the plugin, validates it, enables it in the bar
11. adds the "Immich Photos" launcher entry
12. shows the address and QR code for the phone

Without questions: `./scripts/install.sh --yes --media ~/Pictures/Immich`

## What needs root

| Action | When | Undo |
|---|---|---|
| `sudo docker ps -a` | looking for existing Immich containers | read-only |
| `sudo systemctl enable --now docker.service` | start at boot | `sudo systemctl disable docker.service` |
| `sudo docker compose up -d` | start Immich | `immich-photos server stop` |

The user is not added to the `docker` group. If you want that:
`omarchy-setup-security-sudoless-docker` (equivalent to passwordless root).

## Afterwards

1. Open `http://localhost:2283` and create the first account. It becomes the
   administrator.
2. Connect your phone: `phone-setup.md`
3. For photo and job counts in the panel, add an API key: Immich → Account
   Settings → API Keys, permissions `asset.statistics`, `server.statistics`,
   `queue.read`, `session.read`. Paste it under Settings in the panel or run
   `immich-photos api-key set`.

## Command line

```bash
immich-photos status            # overview, --json for scripts
immich-photos server start      # also stop, restart, status, logs
immich-photos storage status
immich-photos storage check /mnt/photos/Immich
immich-photos backup status
immich-photos address --qr
immich-photos open
immich-photos diagnostics
```

## Removal

```bash
./scripts/uninstall.sh
```

| Question | Default |
|---|---|
| Remove the plugin | yes |
| Remove the containers (only if this plugin installed them) | no |
| Disable Docker at boot again (only if the installer enabled it) | no |
| Remove configuration and API key | no |
| Delete photos, videos, database | never offered |
