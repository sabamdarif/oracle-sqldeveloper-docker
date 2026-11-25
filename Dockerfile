# Oracle Database Free + SQL Developer in one image. See README.md for build and run.
#
# Use the published Oracle Free image in its `slim-faststart` flavor: upstream
# creates and expands the database at build time, leaving only configuration
# and startup for the first run. Needs >=2 GB of memory for the database alone.
ARG BASE_IMAGE="gvenzl/oracle-free:23-slim-faststart"
FROM ${BASE_IMAGE}

ARG HOST_UID=1000
ARG HOST_GID=1000
ARG SQLDEVELOPER_URL="https://download.oracle.com/otn_software/java/sqldeveloper/sqldeveloper-26.2.0.186.2220-x64.zip"
ARG ORACLE_PASSWORD="password"

USER root

# GUI libraries and fonts; the base image is headless. gtk3 pulls in the X client
# libraries, libXtst and mesa-libGL are what the JDK needs on top, and `file` is
# what the SQL Developer launcher shells out to when sizing up the JDK it found.
RUN microdnf -y install \
    alsa-lib \
    dejavu-sans-fonts \
    file \
    fontconfig \
    gtk3 \
    libXtst \
    mesa-libGL \
    mesa-dri-drivers \
    shadow-utils \
    sudo \
    unzip \
    && microdnf clean all

# BellSoft Liberica JDK 17 Full, for the LibericaFX (JavaFX) SQL Developer needs.
RUN rpm --import https://download.bell-sw.com/pki/GPG-KEY-bellsoft \
    && printf '[BellSoft]\nname=BellSoft Repository\nbaseurl=https://yum.bell-sw.com\nenabled=1\ngpgcheck=1\ngpgkey=https://download.bell-sw.com/pki/GPG-KEY-bellsoft\n' \
    > /etc/yum.repos.d/bellsoft.repo \
    && microdnf -y install bellsoft-java17-full \
    && microdnf clean all

# Re-point java at it. libjli.so goes in /usr/lib64, not /usr/lib: on x86_64 that
# is what the dynamic loader searches by default.
RUN JAVA_HOME=$(readlink -f /usr/lib/jvm/bellsoft-java17-full*) \
    && ln -s "${JAVA_HOME}" /opt/java \
    && ln -sf "${JAVA_HOME}/bin/java" /usr/bin/java \
    && echo "${JAVA_HOME}/lib" > /etc/ld.so.conf.d/java.conf \
    && echo "${JAVA_HOME}/lib/server" >> /etc/ld.so.conf.d/java.conf \
    && ldconfig \
    && ln -sf "${JAVA_HOME}/lib/libjli.so" /usr/lib64/libjli.so \
    && java -version

# GUI user, matched to the host UID so the X11 socket and any mounted directories
# stay usable. It may become `oracle` (and only `oracle`) to start the database.
RUN groupadd --gid "${HOST_GID}" sqldev \
    && useradd \
    --uid "${HOST_UID}" \
    --gid "${HOST_GID}" \
    --create-home \
    --shell /bin/bash \
    sqldev \
    && echo 'sqldev ALL=(oracle) NOPASSWD: ALL' > /etc/sudoers.d/sqldev-oracle \
    && chmod 440 /etc/sudoers.d/sqldev-oracle

WORKDIR /opt
RUN echo "Downloading: ${SQLDEVELOPER_URL}" \
    && curl -fL --retry 5 --retry-delay 3 \
    "${SQLDEVELOPER_URL}" \
    -o /tmp/sqldeveloper.zip \
    && unzip -q /tmp/sqldeveloper.zip -d /opt \
    && rm /tmp/sqldeveloper.zip \
    && test -x /opt/sqldeveloper/sqldeveloper.sh

# Point SQL Developer at the BellSoft JDK. `SetJavaHome` is the directive the
# launcher documents for this; a symlink in place of the bundled `jdk` is not,
# since the whiteouts for that directory land on the symlink's target once the
# image is unpacked. The bundled runtime still has to go, because the launcher
# looks for `../../jdk/bin/java` ahead of any conf file.
RUN CONF=/opt/sqldeveloper/sqldeveloper/bin/sqldeveloper.conf \
    && test -f "${CONF}" \
    && printf '\n# Use the JDK this image installs, not a bundled or system one.\nSetJavaHome /opt/java\n' >> "${CONF}" \
    && rm -rf /opt/sqldeveloper/jdk

# Workaround required by the SQL Developer launcher on some Linux systems.
RUN LAUNCHER=/opt/sqldeveloper/ide/bin/launcher.sh \
    && test -f "${LAUNCHER}" \
    && if ! grep -q '^AddWindowsVM11OrHigherOption()' "${LAUNCHER}"; then \
    sed -i '2i AddWindowsVM11OrHigherOption() { :; }' "${LAUNCHER}"; \
    fi

COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
# Give the GUI its own client aliases. Do not change the database network files
# that upstream manages under ORACLE_HOME and moves into oradata on first start.
COPY --chmod=644 tnsnames.ora /opt/sqldeveloper/network/admin/tnsnames.ora
RUN chown -R sqldev:sqldev /home/sqldev \
    && chmod -R a+rX /opt/sqldeveloper

ENV HOME=/home/sqldev
ENV TNS_ADMIN=/opt/sqldeveloper/network/admin
ENV JAVA_HOME=/opt/java
ENV PATH="/opt/java/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/java/lib:/opt/java/lib/server"
ENV _JAVA_AWT_WM_NONREPARENTING=1
ENV _JAVA_OPTIONS="-Dsun.java2d.pmoffscreen=false"
# Carried into the image config, which is where the entrypoint reads it from.
ENV ORACLE_PASSWORD="${ORACLE_PASSWORD}"

EXPOSE 1521

# The inherited healthcheck authenticates as the OS user, so it has to run as
# `oracle` now that the container runs as `sqldev`.
HEALTHCHECK CMD sudo -iu oracle healthcheck.sh >/dev/null || exit 1

USER sqldev
WORKDIR /opt/sqldeveloper
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
