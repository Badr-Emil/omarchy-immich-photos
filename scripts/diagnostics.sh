#!/bin/bash

# Full report about Omarchy, Docker, Immich, storage and network. No secrets.

exec "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../backend/immich-photos" diagnostics
