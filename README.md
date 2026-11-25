# Oracle Database Free + SQL Developer

Run Oracle Database Free and the SQL Developer desktop app together with
[chroot-distro](https://github.com/sabamdarif/chroot-distro).

## Requirements

- Linux x64 with a desktop display.
- [chroot-distro](https://github.com/sabamdarif/chroot-distro) installed.
- At least 2 GB of free memory for Oracle, plus memory for SQL Developer.

## Install the latest prebuilt image

Download the archive from the [latest release](https://github.com/sabamdarif/oracle-sqldeveloper-docker/releases/tag/latest),
then install it without building locally:

```sh
chroot-distro install --name oracle-sqldeveloper ./oracle-sqldeveloper-x86_64.tar.xz
CD_USE_NS=1 chroot-distro run --shared-display --env ORACLE_PASSWORD=change-me oracle-sqldeveloper
```

- The prebuilt image uses UID/GID `1000` and the default password `password`.
  Override the password as shown above.
- Installing a new release does not update an existing container. Use a new name
  or back up your database before removing the old container.

## Build and install

Run from this repository's directory. Replace `password` with your own password.

```sh
chroot-distro build \
    --build-arg HOST_UID="$(id -u)" \
    --build-arg HOST_GID="$(id -g)" \
    --build-arg ORACLE_PASSWORD=password \
    -t oracle-sqldeveloper:latest \
    --install-as oracle-sqldeveloper \
    .
```

- If that container name already exists, use a different `--install-as` name.
- Rebuilding does not update an already installed container.

## Run

```sh
CD_USE_NS=1 chroot-distro run --shared-display oracle-sqldeveloper
```

- Use the name you chose during installation.
- Wait for SQL Developer to open. Closing it ends the run.
- Stop any other database using port `1521` before starting.

## Connect

- Double-click **Oracle Free (SYSTEM)** in the **Connections** panel.
  On a fresh profile, the username and password are already saved.
- The welcome page's detected `FREE` / `FREEPDB1` entries still ask for credentials.
- For a manual connection, choose **Basic** and **Service name**:
  - Host: `localhost`; port: `1521`; service: `FREEPDB1`.
  - Username: `system`; password: your `ORACLE_PASSWORD`; role: `default`.

## Notes

- The password is printed at startup, so keep terminal output and logs private.
- Existing profiles are not changed. Save a connection manually if needed.
- If you change the database password, update your saved connection's password too.
- Old Oracle XE databases cannot be reused directly. Export your data and import
  it into a fresh Free database; keep a backup before replacing any container.
