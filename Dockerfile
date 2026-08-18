# Oracle XE 21c + SQL Developer in one image.
#
# The base image is what oci-oracle-xe/ builds: Oracle XE on Oracle Linux 8
# with the database already created at build time, so a container starts in
# seconds instead of running `oracle-xe-21c configure` for 20 minutes.
#
#   docker build -t sqldev-xe .
#   xhost +local:
#   docker run --rm -it --init --shm-size=1g -p 1521:1521 \
#       -e DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix sqldev-xe
#
# Connect inside SQL Developer with SYSTEM / password on localhost:1521,
# service XEPDB1 (or XE for the CDB). Needs >=2 GB of container memory.
FROM gvenzl/oracle-xe:21-slim-faststart

ARG HOST_UID=1000
ARG HOST_GID=1000
# This ARG is replaced by build-latest.sh when a newer version is found.
ARG SQLDEVELOPER_URL="https://download.oracle.com/otn_software/java/sqldeveloper/sqldeveloper-26.2.0.186.2220-x64.zip"

USER root

# -----------------------------------------------------------------
# 1. GUI libraries and fonts (the base image is headless).
#    gtk3 pulls in the rest of the X client libraries; libXtst and
#    mesa-libGL are what the JDK needs on top of it.
# -----------------------------------------------------------------
RUN microdnf -y install \
    alsa-lib \
    dejavu-sans-fonts \
    fontconfig \
    gtk3 \
    libXtst \
    mesa-libGL \
    shadow-utils \
    sudo \
    unzip \
    && microdnf clean all

# -----------------------------------------------------------------
# 2. BellSoft Liberica JDK 17 Full (includes LibericaFX / JavaFX,
#    required by SQL Developer)
# -----------------------------------------------------------------
RUN rpm --import https://download.bell-sw.com/pki/GPG-KEY-bellsoft \
    && printf '[BellSoft]\nname=BellSoft Repository\nbaseurl=https://yum.bell-sw.com\nenabled=1\ngpgcheck=1\ngpgkey=https://download.bell-sw.com/pki/GPG-KEY-bellsoft\n' \
    > /etc/yum.repos.d/bellsoft.repo \
    && microdnf -y install bellsoft-java17-full \
    && microdnf clean all

# -----------------------------------------------------------------
# 3. Re-point java to BellSoft's full JDK
# -----------------------------------------------------------------
RUN JAVA_HOME=$(readlink -f /usr/lib/jvm/bellsoft-java17-full*) \
    && ln -sf "${JAVA_HOME}/bin/java" /usr/bin/java \
    && echo "${JAVA_HOME}/lib" > /etc/ld.so.conf.d/java.conf \
    && echo "${JAVA_HOME}/lib/server" >> /etc/ld.so.conf.d/java.conf \
    && ldconfig \
    && ln -sf "${JAVA_HOME}/lib/libjli.so" /usr/lib/libjli.so \
    && java -version

# -----------------------------------------------------------------
# 4. GUI user, matched to the host UID so the X11 socket and any
#    mounted directories stay usable. It may become `oracle` (and
#    only `oracle`) to start and check the database.
# -----------------------------------------------------------------
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

# Point SQL Developer's bundled jdk at the BellSoft JDK.
RUN JAVA_HOME=$(readlink -f /usr/lib/jvm/bellsoft-java17-full*) \
    && ln -s "${JAVA_HOME}" /opt/java \
    && rm -rf /opt/sqldeveloper/jdk \
    && ln -s /opt/java /opt/sqldeveloper/jdk

# Workaround required by the SQL Developer launcher on some Linux systems.
RUN LAUNCHER=/opt/sqldeveloper/ide/bin/launcher.sh \
    && test -f "${LAUNCHER}" \
    && if ! grep -q '^AddWindowsVM11OrHigherOption()' "${LAUNCHER}"; then \
    sed -i '2i AddWindowsVM11OrHigherOption() { :; }' "${LAUNCHER}"; \
    fi

COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chown -R sqldev:sqldev /home/sqldev \
    && chmod -R a+rX /opt/sqldeveloper

ENV HOME=/home/sqldev
ENV JAVA_HOME=/opt/java
ENV PATH="/opt/java/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/java/lib:/opt/java/lib/server"
ENV _JAVA_AWT_WM_NONREPARENTING=1
ENV _JAVA_OPTIONS="-Dsun.java2d.pmoffscreen=false"
# SYS and SYSTEM password, set on the first container start. Override with -e.
ENV ORACLE_PASSWORD=password

EXPOSE 1521

# The inherited healthcheck authenticates to the database as the OS user, so it
# has to run as `oracle` now that the container runs as `sqldev`.
HEALTHCHECK CMD sudo -iu oracle healthcheck.sh >/dev/null || exit 1

USER sqldev
WORKDIR /opt/sqldeveloper
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
