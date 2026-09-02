# Oracle XE + SQL Developer in one image

The base image is [gvenzl/oracle-xe](https://github.com/gvenzl/oci-oracle-xe) `21-slim-faststart`,
which creates the database at build time: a start takes seconds instead of the twenty minutes
`oracle-xe-21c configure` needs. `oci-oracle-xe/` is a checkout of that project,
kept as a reference for its entrypoint — nothing builds from it.

## Requirements

- [chroot-distro](https://github.com/sabamdarif/chroot-distro)

```bash
sudo pip install chroot-distro
```

- 2 GB of free memory, ~7 GB of disk,

## Build

```sh
chroot-distro build \
    --build-arg HOST_UID="$(id -u)" \
    --build-arg HOST_GID="$(id -g)" \
    --build-arg ORACLE_PASSWORD=password \
    -t oracle-sqldeveloper:latest \
    --install-as oracle-sqldeveloper \
    .
```

- **`ORACLE_PASSWORD`** — the SYS and SYSTEM password, re-applied on every start,
  so a rebuild is all it takes to change it. Defaults to `password`.
- **`HOST_UID`, `HOST_GID`** — the GUI runs as this uid, so make it yours or the
  X11 socket and any bind mounts will not be usable. Both default to 1000.
- **`SQLDEVELOPER_URL`** — a newer release from Oracle's [download page](https://www.oracle.com/database/sqldeveloper/technologies/download/).
- **`BASE_IMAGE`** — to pin the base image to a digest.

`--install-as` will not overwrite an existing container, so a rebuild starts with
`chroot-distro remove oracle-sqldeveloper`.

## Run

```sh
chroot-distro run --shared-display oracle-sqldeveloper
```

`--shared-display` wires up X11/Wayland, audio and D-Bus. Quitting SQL Developer
ends the run. Arguments after `--` are passed on to SQL Developer.

Only one Oracle can own port 1521 and the guest shares the host's network, so stop a
Docker or host database first; the entrypoint says so instead of failing halfway. A
listener this container left behind on an earlier run is cleared automatically.

## Connecting

The entrypoint prints these just before the GUI appears:

|          |                                           |
| -------- | ----------------------------------------- |
| Hostname | `localhost`                               |
| Port     | `1521`                                    |
| Service  | `XEPDB1`, or `XE` for the CDB             |
| Username | `system`                                  |
| Password | whatever `ORACLE_PASSWORD` was built with |
