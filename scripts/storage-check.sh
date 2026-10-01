#!/bin/bash

# Checks whether a folder is a safe place for the photo library. Changes nothing.
#
#   ./scripts/storage-check.sh /mnt/photos/Immich
#   ./scripts/storage-check.sh               the location Immich uses now

backend="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../backend/iphone-photos"

if (($#)); then
  exec "$backend" storage check "$@"
fi
exec "$backend" storage status
