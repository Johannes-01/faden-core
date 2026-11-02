#!/bin/bash
# Compares the public API of FadenCore and FadenTranscription with the latest release tag and reports
# breaking changes as a GitHub warning and in the job summary. Exits 0 either way, so it never blocks a merge.
# Locally: scripts/api-check.sh [tag]
set -uo pipefail

base="${1:-$(git tag --merged HEAD --sort=-v:refname | head -1)}"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
if [ -z "$base" ]; then
    echo "No release tag to compare with."
    exit 0
fi

out="$(mktemp)"
swift package diagnose-api-breaking-changes "$base" --products FadenCore FadenTranscription 2>&1 | tee "$out"
status=${PIPESTATUS[0]}

if grep -q "💔" "$out"; then
    count=$(grep -c "💔" "$out")
    echo "::warning title=Public API::$count breaking change(s) against $base. If they are intended, describe them in CHANGELOG.md; the next release then needs a new minor version."
    {
        echo "### Public API: $count breaking change(s) against $base"
        echo '```'
        grep "💔" "$out"
        echo '```'
    } >> "$summary"
elif [ "$status" -ne 0 ]; then
    echo "::warning title=Public API::The API check against $base could not run (exit $status); see the step log."
else
    echo "### Public API: no breaking changes against $base" >> "$summary"
fi
exit 0
