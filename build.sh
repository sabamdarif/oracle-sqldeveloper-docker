#!/usr/bin/env bash
set -euo pipefail

FALLBACK_URL="https://download.oracle.com/otn_software/java/sqldeveloper/sqldeveloper-26.2.0.186.2220-x64.zip"
DOWNLOAD_PAGE="https://www.oracle.com/database/sqldeveloper/technologies/download/"

export HOST_UID="$(id -u)"
export HOST_GID="$(id -g)"

echo "Checking Oracle for the latest SQL Developer release..."

DETECTED_URL="$(
    curl -fsSL --retry 3 \
        -A "Mozilla/5.0" \
        "$DOWNLOAD_PAGE" |
        grep -Eo 'https://download\.oracle\.com/otn_software/java/sqldeveloper/sqldeveloper-[^"[:space:]]+-x64\.zip' |
        sort -Vu |
        tail -n 1 || true
)"

if [[ -n "$DETECTED_URL" ]]; then
    export SQLDEVELOPER_URL="$DETECTED_URL"
    echo "Detected SQL Developer archive:"
else
    export SQLDEVELOPER_URL="$FALLBACK_URL"
    echo "Could not detect the latest release; using fallback:"
fi

echo "$SQLDEVELOPER_URL"

docker compose build --pull sqldeveloper

echo
echo "Image built successfully:"
echo "  oracle-sqldeveloper:latest"
