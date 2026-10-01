#!/bin/bash

# Backend tests, shell syntax, plugin manifest and QML lint.

set -euo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."

python3 -B -m unittest discover -s tests
bash -n scripts/*.sh
omarchy plugin validate .

# `qs` is Quickshell's name for the shell's own modules; qmllint needs it as an import path.
qmllint=$(command -v qmllint || echo /usr/lib/qt6/bin/qmllint)
if [[ -x $qmllint && -d ${OMARCHY_PATH:-/usr/share/omarchy}/shell ]]; then
  imports=$(mktemp -d)
  trap 'rm -rf "$imports"' EXIT
  ln -s "${OMARCHY_PATH:-/usr/share/omarchy}/shell" "$imports/qs"
  # Dynamic typing of the bar object produces warnings; import and syntax errors must not occur.
  if "$qmllint" -I "$imports" Panel.qml 2>&1 | grep -E '\[(import|syntax)\]|not found\. Did you add'; then
    echo "qmllint found import or syntax problems" >&2
    exit 1
  fi
  echo "qmllint: no import or syntax problems"
fi
