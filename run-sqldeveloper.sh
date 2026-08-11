#!/usr/bin/env bash
set -e

IMAGE="oracle-sqldeveloper:latest"

mkdir -p \
    "$HOME/.local/share/oracle-sqldeveloper/sqldeveloper" \
    "$HOME/.local/share/oracle-sqldeveloper/java"

xhost +SI:localuser:"$(whoami)" >/dev/null

if docker container inspect oracle-xe >/dev/null 2>&1; then
    docker start oracle-xe >/dev/null
else
    docker run -d \
        --name oracle-xe \
        --pull always \
        --restart unless-stopped \
        -p 1521:1521 \
        -e ORACLE_PASSWORD=9732 \
        -v oracle-xe-data:/opt/oracle/oradata \
        gvenzl/oracle-xe:latest
fi

DOCKER_ARGS=(
    --rm
    --name oracle-sqldeveloper
    --network host
    -e "DISPLAY=$DISPLAY"
    -e "XAUTHORITY=${XAUTHORITY:-$HOME/.Xauthority}"
    -v /tmp/.X11-unix:/tmp/.X11-unix:rw
    -v "${XAUTHORITY:-$HOME/.Xauthority}:${XAUTHORITY:-$HOME/.Xauthority}:ro"
    -v "$HOME/.local/share/oracle-sqldeveloper/sqldeveloper:/home/sqldev/.sqldeveloper"
    -v "$HOME/.local/share/oracle-sqldeveloper/java:/home/sqldev/.java"
)

if [[ -e /dev/dri ]]; then
    DOCKER_ARGS+=(--device /dev/dri:/dev/dri)
fi

exec docker run "${DOCKER_ARGS[@]}" "$IMAGE"
