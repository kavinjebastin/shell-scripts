#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKSUM_FILE="$REPO_ROOT/checksums/SHA256SUMS"

: > "$CHECKSUM_FILE"

while IFS= read -r -d '' script; do
    relative="${script#"$REPO_ROOT"/}"
    sha256sum "$script" | sed "s|$REPO_ROOT/||" >> "$CHECKSUM_FILE"
done < <(find "$REPO_ROOT/scripts" "$REPO_ROOT/lib" -name '*.sh' -print0 | sort -z)

echo "Checksums written to $CHECKSUM_FILE"
cat "$CHECKSUM_FILE"
