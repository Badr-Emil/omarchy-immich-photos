# Storage

## Two locations

| What | Variable | Requirement |
|---|---|---|
| Photos, videos, thumbnails | `UPLOAD_LOCATION` | Unix filesystem with ownership and permissions, plenty of space |
| PostgreSQL | `DB_DATA_LOCATION` | local SSD, never a network share, 1–3 GB |

Thumbnails and transcoded videos add about 10–20 % to the library.

## The check

```bash
immich-photos storage check /mnt/photos/Immich
immich-photos storage check --database ~/.local/share/omarchy-immich-photos/postgres
```

It creates nothing and answers these questions:

| Question | Rejected when |
|---|---|
| Valid path? | relative, `/`, a system directory (`/etc`, `/boot`, `/tmp`, …), a file instead of a folder |
| Disk mounted? | a path under `/mnt`, `/media`, `/run/media` actually lies on the system disk |
| Suitable filesystem? | vfat, exfat, ntfs (no Unix permissions), tmpfs |
| Writable? | the user may not write, or the mount is read-only |
| Space? | less than 1 GB free; warning below 20 GB |
| Network share? | rejected for the database, warning for media |
| Already a library? | note; the folder is not modified |

"Not mounted" is the most important check: if the disk is missing at start,
Immich would otherwise write to the system disk unnoticed.

## btrfs

On btrfs the database directory gets `chattr +C` (no copy-on-write) before the
first start, because database files fragment badly otherwise. PostgreSQL does
its own checksumming (`--data-checksums` in Immich's compose file).

## Changing the location

With an empty installation it is enough to change `UPLOAD_LOCATION` in `.env`
and restart Immich. Once photos exist, the plugin does not change the path.
Moving is manual work, in this order:

1. **Stop**
   `immich-photos server stop`
2. **Check the source**
   `sudo du -sh ~/Pictures/Immich`
3. **Check the target**
   `immich-photos storage check /mnt/ssd/Immich`
4. **Back up** the source to a third disk if you have one.
5. **Copy**, do not move. Ownership and permissions are preserved:
   `sudo rsync -aHAX --info=progress2 ~/Pictures/Immich/ /mnt/ssd/Immich/`
6. **Verify** with checksums. The output must be empty:
   `sudo rsync -aHAX --checksum --dry-run --itemize-changes ~/Pictures/Immich/ /mnt/ssd/Immich/`
7. **Switch**: set `UPLOAD_LOCATION=/mnt/ssd/Immich` in
   `~/.local/share/omarchy-immich-photos/immich/.env`.
8. **Start**
   `immich-photos server start`
9. **Test**: open the gallery, look at old photos, upload a new one,
   `immich-photos storage status`.

Delete the old copy only after everything has run for a few days, and by hand.
No `mv`, no `rsync --delete`.

Moving the database works the same way with `DB_DATA_LOCATION`. The target
must be local.
