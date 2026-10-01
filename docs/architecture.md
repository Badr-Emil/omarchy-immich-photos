# Architecture

## Data path

```text
phone ── Immich mobile app ──Wi-Fi──▶ Immich server (Docker) ──▶ UPLOAD_LOCATION
```

The plugin is not part of this path. It transfers no photos, keeps no database
of its own and reads no Immich tables. If the plugin fails, the backup keeps
running unchanged.

## Layers

```text
Panel.qml  (Quickshell, inside the running omarchy-shell)
   │  starts a process, reads JSON
   ▼
backend/immich-photos  (Python, standard library only)
   ├── HTTP ─▶ Immich API   http://127.0.0.1:2283/api
   ├── docker compose        directly, or through sudo / pkexec
   └── statvfs / findmnt     free space, filesystem
```

QML contains presentation only. It runs `immich-photos status --json` and
shows what comes back. The API key never leaves the backend.

## Locations

| What | Path | Mode |
|---|---|---|
| Plugin (this repository) | `~/.config/omarchy/plugins/io.github.badr-emil.immich-photos` | |
| `immich-photos` command | `~/.local/bin/immich-photos` → `backend/immich-photos` | symlink |
| Compose file, `.env` | `~/.local/share/omarchy-immich-photos/immich/` | directory 700, `.env` 600 |
| Database | `~/.local/share/omarchy-immich-photos/postgres/` | managed by the container |
| Plugin configuration | `~/.config/omarchy-immich-photos/config.json` | 600 |
| API key | `~/.config/omarchy-immich-photos/api-key` | 600 |
| Media | `UPLOAD_LOCATION`, default `~/Pictures/Immich` | |

The truth about the media and database paths is Immich's `.env`. The backend
reads it there and does not store it a second time. `config.json` only says
where the compose project lives.

## Capabilities instead of assumptions

What the backend can show depends on what is reachable. Every status answer
says so explicitly:

```json
{
  "capabilities": {
    "dockerDirect": false,
    "apiKey": true,
    "adminApi": true
  }
}
```

| Information | Source | Requires |
|---|---|---|
| Server online | `GET /server/ping` | nothing |
| Version | `GET /server/version` | nothing |
| Initialized, maintenance mode | `GET /server/config` | nothing |
| Photos / videos (own account) | `GET /assets/statistics` | API key `asset.statistics` |
| Photos / videos / usage (server) | `GET /server/statistics` | API key, admin |
| Queues | `GET /queues` | API key, admin |
| Devices, last seen | `GET /sessions` | API key `session.read` |
| Free space | `statvfs` on `UPLOAD_LOCATION` | nothing |
| Docker daemon | `systemctl is-active docker` | nothing |
| Container state | `docker compose ps` | `docker` group, or a password prompt |

If the requirement is missing, the field is `null` and the panel hides the
row. There are no placeholder values.

### What Immich does not provide

- **"The phone is syncing right now"** does not exist in the API. The panel
  shows when the Immich mobile app last talked to the server (`updatedAt` of
  the newest session that reports an app version, on iOS or Android; browser
  sessions do not count). Immich refreshes that timestamp at most once an
  hour.
- **"Photos still to upload"** is known only to the phone. The number in the
  bar is the number of jobs the server still has to process (thumbnails,
  metadata, videos), that is, work after the upload. If it is zero or cannot
  be determined, the bar shows the icon alone.
- **Database status** has no endpoint of its own. If the server answers, the
  database is reachable; the panel marks this as inferred.

## Bar states

| State | Condition |
|---|---|
| online | ping succeeds |
| busy | online and jobs pending |
| not set up | no compose installation found |
| stopped | installation present, ping fails, Docker daemon off or port closed |
| problem | port open but the API does not answer, or maintenance mode |

Colors come from `Color` and the bar (`bar.foreground`, `bar.urgent`).

## Plugin structure

Omarchy loads one entry point per bar widget. As with the built-in panels
(`omarchy.tailscale`, `omarchy.audio`) that is a single file, `Panel.qml`,
which extends `qs.Ui.Panel` and contains the bar icon (`BarIconButton`) and
the popup (`KeyboardPanel`). The API would need a separate `BarWidget.qml` and
`Service.qml` only if the panel were loaded lazily or its state were shared by
several widgets; neither applies here. The backend plays the role of the
service.

The plugin runs inside the existing `omarchy-shell` process; no second
Quickshell is started. Pages of the panel can be opened directly:

```bash
omarchy-shell io.github.badr-emil.immich-photos toggle
omarchy-shell io.github.badr-emil.immich-photos.page go setup   # storage, backup, settings
```

## Photo browser

`Gallery.qml` is the plugin's second entry point, an `overlay` that
`omarchy-shell shell toggle io.github.badr-emil.immich-photos` opens as a
full-screen layer with exclusive keyboard focus, like Omarchy's own image
picker. It follows the same rule as the panel: QML shows, the backend talks.

| Backend command | Immich API |
|---|---|
| `gallery list <page>` | `POST /search/metadata`, thumbnails from `GET /assets/{id}/thumbnail` |
| `gallery preview <id>…` | `GET /assets/{id}/thumbnail?size=preview` |
| `gallery trash <id>…` | `DELETE /assets` with `force: false` |
| `gallery restore <id>…` | `POST /trash/restore/assets` |
| `gallery favorite\|archive on\|off <id>…` | `PUT /assets` |
| `gallery albums`, `album-add`, `album-create` | `GET /albums`, `PUT /albums/{id}/assets`, `POST /albums` |
| `gallery play <id>` | `GET /assets/{id}`, then the original file from `UPLOAD_LOCATION` |

Images reach QML as files in `~/.cache/omarchy-immich-photos/` (directory 700,
files 600), so the API key never appears in a URL or in QML. Ids are accepted
only if they are UUIDs, because they become part of URLs and file names.
Deleting always means Immich's trash; the backend has no code path for
permanent deletion or for emptying the trash.

## Privileges

Docker actions that change something go through one function that first
checks whether the socket is accessible to the user. If it is not, the same
command runs with `sudo` in a terminal and with `pkexec` from the panel, where
there is no terminal for the password prompt. The command is always
`docker compose --project-directory <dir> <up -d|stop|restart|logs|ps>`,
without a shell and without freely composed arguments.

## Changing the storage location

`UPLOAD_LOCATION` is set only during the first installation. If the media
folder already contains files, the plugin does not change it and points to the
migration steps in `storage.md` (stop, copy, verify, switch, start, test).
There is no automatic `mv` and no `rsync --delete`.

## Backup (prepared, not implemented)

In version 0.1, `immich-photos backup status` reports only what can be
established: whether Immich writes database dumps to `UPLOAD_LOCATION/backups`
and whether a backup target is configured. A target cannot be configured yet,
so the honest answer is "not configured".

## Tests

`tests/` exercises the backend without Docker and without a running Immich:
path checks, space calculation, the `.env` parser, state derivation, the LAN
address and API errors against a local test HTTP server.
