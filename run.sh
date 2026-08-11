#!/usr/bin/env bash
set -euo pipefail

export HOST_UID="$(id -u)"
export HOST_GID="$(id -g)"
export DISPLAY="${DISPLAY:-:0}"

mkdir -p \
    "$HOME/.local/share/oracle-sqldeveloper/sqldeveloper" \
    "$HOME/.local/share/oracle-sqldeveloper/java"

# Determine the X11 authorization file.
if [[ -n "${XAUTHORITY:-}" && -f "$XAUTHORITY" ]]; then
    export XAUTHORITY
elif [[ -f "$HOME/.Xauthority" ]]; then
    export XAUTHORITY="$HOME/.Xauthority"
else
    export XAUTHORITY="$HOME/.Xauthority"
    touch "$XAUTHORITY"
fi

# Allow containers running as the current UID to access X11/XWayland.
if command -v xhost >/dev/null 2>&1; then
    xhost "+SI:localuser:$(id -un)" >/dev/null
fi

echo "Starting Oracle XE..."
docker compose up -d oracle-xe

echo "Waiting for Oracle XE to become healthy..."

while true; do
    STATUS="$(
        docker inspect \
            --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}starting{{end}}' \
            oracle-xe 2>/dev/null || echo "starting"
    )"

    case "$STATUS" in
    healthy)
        echo "Oracle XE is ready."
        break
        ;;
    unhealthy)
        echo "Oracle XE failed its health check." >&2
        docker compose logs oracle-xe
        exit 1
        ;;
    *)
        printf '.'
        sleep 5
        ;;
    esac
done

echo
echo "SQL Developer connection details:"
echo "  Hostname: oracle-xe"
echo "  Port:     1521"
echo "  Service:  XEPDB1"
echo "  Username: system"
echo "  Password: ${ORACLE_PASSWORD:-9732}"
echo

exec docker compose run --rm --no-deps sqldeveloper
