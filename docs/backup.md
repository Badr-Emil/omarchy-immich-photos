# Backup

## Where things stand

Unless you set up something yourself, photos, videos and the database live on
one disk and there is no second copy. **Version 0.1 does not set up a
backup**; it only reports honestly what exists:

```bash
immich-photos backup status
```

| Line | Meaning |
|---|---|
| Media backup | whether a backup target for photos and videos is configured (not possible yet, so "not configured") |
| Database dumps | dumps Immich itself writes every night to `UPLOAD_LOCATION/backups` |
| Last verified | the last verified backup (never, so far) |

## What the database dump is not

Immich writes a dump of its database every night. The dump contains albums,
people and metadata, **but no photos**, and it sits on the same disk. It helps
with a damaged database, not with a failed disk.

A complete backup needs both, on another disk:

1. all of `UPLOAD_LOCATION` (in it `library/`, `upload/`, `profile/` and
   `backups/` with the database dumps)
2. optionally `thumbs/` and `encoded-video/`; they can be regenerated

## By hand, until the plugin can do it

Mount an external disk or a NAS, then:

```bash
immich-photos storage check /mnt/hdd/Immich-Backup
sudo rsync -aHAX --info=progress2 ~/Pictures/Immich/ /mnt/hdd/Immich-Backup/
```

Without `--delete`: what was deleted in the original stays in the backup. That
costs space and protects against accidental deletion.

## Planned for 0.3

```text
Main storage  /mnt/ssd/Immich      or   internal SSD
Backup        /mnt/hdd/Immich-Backup    NAS
```

- configure a backup target, with the same storage check as the main location
- copy without deleting by default
- verification by checksum, with the time shown as "Last verified"
- a notification when the last verified backup is too old

The backend is prepared for this with `backupTarget` in the configuration and
`backup_status()`; a deleting sync will not be the default.
