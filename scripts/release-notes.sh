#!/bin/bash
# Prints the CHANGELOG.md section of a version, without its heading. Fails if the version has no section,
# so a tag without changelog entries is not released.
# Usage: scripts/release-notes.sh 0.4.0
set -euo pipefail
version="$1"
notes="$(awk -v v="$version" '
    /^## / { if (found) exit; if ($2 == v) { found = 1; next } }
    found { print }
' "$(dirname "$0")/../CHANGELOG.md" | sed -e '/./,$!d')"
if [ -z "$notes" ]; then
    echo "CHANGELOG.md has no section for $version" >&2
    exit 1
fi
printf '%s\n' "$notes"
