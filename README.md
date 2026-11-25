# Oracle Database Free + SQL Developer in one image

The base image is [gvenzl/oracle-free](https://github.com/gvenzl/oci-oracle-free)
`23-slim-faststart`. Upstream creates and expands the database at build time, so
the first run only configures and starts it; it does not run the full Oracle
installer. This project extends the published image, not an upstream checkout.

The `23` tag follows upstream's current release (currently Oracle AI Database
26ai Free, version `23.26.4`). Pin a version or digest with `BASE_IMAGE` if you
need reproducible builds. The default slim flavor omits components such as
Oracle Text, Spatial and the in-database JVM; choose a regular or full Oracle
Free image if you need them.

## Requirements

- [chroot-distro](https://github.com/sabamdarif/chroot-distro)

```bash
sudo pip install chroot-distro
```

- At least 2 GB of free memory for Oracle alone, plus memory for SQL Developer;
  allow additional disk space for the Free database, GUI, downloads and build cache.
- The default SQL Developer download is an x64 archive. The Oracle Free base
  supports native AMD64 and ARM64 starting with version 23.5, but the complete
  GUI image has not been validated on ARM64. An ARM build needs a compatible
  SQL Developer archive and native JDK/JavaFX libraries; changing the base image
  alone does not guarantee ARM GUI support.

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
- **`BASE_IMAGE`** — an Oracle Free image reference, to select a different flavor
  or pin a version/digest. Defaults to `gvenzl/oracle-free:23-slim-faststart`;
  `ghcr.io/gvenzl/oracle-free:23-slim-faststart` is the alternative registry.

`--install-as` will not overwrite an existing container. Back up/export any data
you need before removing it with `chroot-distro remove oracle-sqldeveloper`.
For an XE-to-Free migration, keep the old container and install under a different
name instead (see below).

## Migrating from Oracle XE

Changing the base image does **not** upgrade an existing XE database. Do not
reuse its `/opt/oracle/oradata` directory with Oracle Free. The entrypoint refuses
to start if it detects the old `dbconfig/XE` directory, without changing that data.

1. Export the schemas/data you need from XE, for example with Oracle Data Pump.
   Keep the old container and a backup until the migration is verified.
2. Build/install the Free image under a separate name, such as
   `--install-as oracle-free-sqldeveloper`, using a fresh data directory.
3. Stop the XE database so port 1521 is free, then run the new container:
   `CD_USE_NS=1 chroot-distro run --shared-display oracle-free-sqldeveloper`.
4. Import your schemas into `FREEPDB1` and update saved SQL Developer connections
   from service `XEPDB1` to `FREEPDB1`.

Pinning or changing Oracle Free versions also does not provide an automatic
database upgrade; follow Oracle's supported migration/upgrade procedure.

## Run

```sh
CD_USE_NS=1 chroot-distro run --shared-display oracle-sqldeveloper
```

`--shared-display` wires up X11/Wayland, audio and D-Bus. Quitting SQL Developer
ends the run. Arguments after `--` are passed on to SQL Developer.

`CD_USE_NS=1` gives Oracle separate IPC resources. Without it, a previous run can
leave shared memory/semaphores on the host, causing the initial SQL*Plus health
check to hang silently. Namespaces avoid attaching to those leftovers.

Only one Oracle can own port 1521 and the guest shares the host's network, so stop a
Docker or host database first; the entrypoint says so instead of failing halfway. A
listener this container left behind on an earlier run is cleared automatically.

## Connecting

### Saved connection with automatic credentials (recommended)

On the first launch with a fresh SQL Developer profile, the entrypoint creates
**Oracle Free (SYSTEM)** in the **Connections** panel. Double-click it to connect:
the hostname, port, service, username and password are already saved.

| Setting  | Automatic value                                  |
| -------- | ------------------------------------------------ |
| Host     | `localhost:1521`                                 |
| Service  | `FREEPDB1` (or the configured `ORACLE_DATABASE`) |
| Username | `system`                                         |
| Password | The configured `ORACLE_PASSWORD`                 |
| Role     | `default`                                        |

The setup runs after successful database startup/password reset and uses SQL
Developer's own credential-encryption and connection-storage APIs. Each fresh
profile receives its own random encryption key; connection and key files are
created with owner-only permissions. The connection uses JDBC Thin, so it does
not need an OCI client configuration.

Existing connection stores, older profiles awaiting settings migration, and
existing preferences without a credential key are left untouched. The setup
does not replace, merge or update your saved connections. If you later change
`ORACLE_PASSWORD`, update the saved password in SQL Developer once. An existing
profile can still use the TNS aliases below.

To disable automatic saved credentials:

```sh
CD_USE_NS=1 chroot-distro run --shared-display \
    --env SQLDEVELOPER_AUTO_CONNECTION=false oracle-sqldeveloper
```

This uses the same local protection as SQL Developer's **Save Password** option,
not a separate secret vault: someone who can read the profile and its key can
recover the password. `ORACLE_PASSWORD` is also already present in this image's
configuration. The setup writes no plaintext password to connection files.
The entrypoint prints the password in its connection banner for manual setup,
so anyone who can read the terminal output or startup logs can see it.

This feature is included in newly built images and tested against SQL Developer
26.2's bundled libraries. Rebuilding does not change an already installed
container or its saved profile. If setup fails, the GUI still starts and you can
use a TNS or Basic connection.

### TNS discovery (no saved credentials)

The image includes a client `tnsnames.ora` file with two aliases:

| Alias      | Host / port      | Service    |
| ---------- | ---------------- | ---------- |
| `FREEPDB1` | `localhost:1521` | `FREEPDB1` |
| `FREE`     | `localhost:1521` | `FREE`     |

SQL Developer discovers these through
`TNS_ADMIN=/opt/sqldeveloper/network/admin`. On the welcome page, look under
**Databases Detected** and click the `FREEPDB1` entry to add a connection.
Alternatively, open **New / Select Database Connection**, select
**Connection Type: TNS**, and choose **Network Alias: FREEPDB1**. You do not need
to type the hostname, port or service name.

Enter username `system`, your configured `ORACLE_PASSWORD`, and leave the role
as `default`. Click **Test**, then save/connect. You can select **Save Password**
if you want SQL Developer to remember the credentials. The TNS file contains
only connection addresses, not usernames or passwords.

These aliases are included in newly built images; rebuilding does not modify an
already installed container. Do not remove an existing container just to add
them. To use them without rebuilding, copy this repository's `tnsnames.ora`
into an accessible directory **inside the container**, then set that directory
under **Tools → Preferences → Database → Advanced → Tnsnames Directory** and
restart SQL Developer. For example, use `/home/sqldev/tns-admin/tnsnames.ora`
and select `/home/sqldev/tns-admin` as the directory.

If **No TNS entries found** still appears in a new image, check for a previously
saved **Tnsnames Directory** preference pointing elsewhere. Set it to
`/opt/sqldeveloper/network/admin` and restart SQL Developer. An existing
`/home/sqldev/.tnsnames.ora` can also take precedence over `TNS_ADMIN`.

The client aliases use an explicit `HOST = localhost`. Oracle's own listener
and database network configuration are left unchanged.

### Manual Basic connection

In SQL Developer's **New / Select Database Connection** dialog:

1. Choose **Connection Type: Basic**.
2. Select the **Service name** radio button below **SID**, and enter `FREEPDB1`.
3. Use these settings:

   | Setting      | Value                                     |
   | ------------ | ----------------------------------------- |
   | Hostname     | `localhost`                               |
   | Port         | `1521`                                    |
   | Service name | `FREEPDB1`, or `FREE` for the CDB         |
   | Username     | `system`                                  |
   | Password     | whatever `ORACLE_PASSWORD` was built with |
   | Role         | `default`                                 |

4. Click **Test**, then **Connect** if successful. Save the corrected connection
   settings for future use.

The entrypoint also prints the connection details just before the GUI appears.

### ORA-12505: SID xe is not registered with the listener

This error means the connection is still using the old XE SID. Oracle Free uses
`FREE` / `FREEPDB1`, not `XE` / `XEPDB1`. Select **Service name** (not **SID**),
enter `FREEPDB1`, then test again. No image rebuild or database recreation is
needed to correct this connection setting.

The welcome page's **No TNS entries found** message does not prevent a **Basic**
connection. TNS aliases are not required when entering the hostname, port and
service name directly.

## Tests

```sh
./test-entrypoint.sh

# Credential setup tests need an unpacked SQL Developer installation and JDK 17+:
SQLDEVELOPER_HOME=/path/to/sqldeveloper JAVA_HOME=/path/to/jdk \
    ./test-connection-setup.sh
```

The entrypoint tests check TNS settings, startup/setup ordering, password resets,
listener handling and the XE-data guard with stubs. Credential tests use the
installed SQL Developer libraries to save/reload and decrypt a connection, check
file permissions, and verify that existing profiles stay unchanged. Neither
suite builds the image or starts a real Oracle database or GUI.
