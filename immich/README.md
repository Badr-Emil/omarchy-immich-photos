# Immich configuration

This repository deliberately contains **no** `docker-compose.yml` of its own.
During installation, `iphone-photos setup` downloads the two files of a pinned
Immich release (`IMMICH_RELEASE` in `backend/iphone-photos`, currently v3.2.4):

```text
https://github.com/immich-app/immich/releases/download/v3.2.4/docker-compose.yml
https://github.com/immich-app/immich/releases/download/v3.2.4/example.env
```

Both are checked against SHA-256 hashes stored in the plugin. If a file
differs, nothing is installed. That way only the compose file that belongs to
this state of the plugin runs as root; a newer release arrives with a new
plugin commit. The files are placed in
`~/.local/share/omarchy-iphone-photos/immich/`. The compose file stays
unchanged; in `.env` only these values are set:

| Variable | Value |
|---|---|
| `UPLOAD_LOCATION` | the chosen media folder |
| `DB_DATA_LOCATION` | `~/.local/share/omarchy-iphone-photos/postgres` |
| `TZ` | the system time zone |
| `DB_PASSWORD` | 40 random characters from `A-Za-z0-9` |

If a future release no longer knows one of these variables, setup stops
instead of writing a line that has no effect.

`.env.example` here is a copy of Immich v3.2.4's `example.env` for reference.
The real `.env` holds the database password, has mode 600 and does not belong
in Git.

## Updating Immich

Read the release notes first: https://github.com/immich-app/immich/releases

```bash
cd ~/.local/share/omarchy-iphone-photos/immich
sudo docker compose pull
sudo docker compose up -d
```
