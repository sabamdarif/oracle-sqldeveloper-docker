FROM fedora:40
ARG HOST_UID=1000
ARG HOST_GID=1000
# This ARG is replaced by build-latest.sh when a newer version is found.
ARG SQLDEVELOPER_URL="https://download.oracle.com/otn_software/java/sqldeveloper/sqldeveloper-26.2.0.186.2220-x64.zip"
# Oracle XE 21c RPM download URL.  The CDN URL below often works without
# authentication.  If it fails, download the RPM from
#   https://www.oracle.com/database/technologies/xe-downloads.html
# place it in this directory, and pass the filename via:
#   --build-arg ORACLE_DB_RPM_URL=oracle-database-xe-21c-1.0-1.ol8.x86_64.rpm
# (curl treats a plain filename as a local path relative to /, so for local
# files use COPY instead — see the COPY fallback comment below).
ARG ORACLE_DB_RPM_URL="https://download.oracle.com/otn-pub/otn_software/db-express/oracle-database-xe-21c-1.0-1.ol8.x86_64.rpm"

# -----------------------------------------------------------------
# 1. Core system packages + GUI libraries (Fedora equivalents of the
#    Debian packages from the original image, plus Oracle DB prereqs)
# -----------------------------------------------------------------
RUN dnf update -y && dnf install -y \
    alsa-lib \
    bc \
    ca-certificates \
    curl \
    file \
    fontconfig \
    freetype \
    gtk3 \
    initscripts \
    ksh \
    libaio \
    libnsl \
    libX11 \
    libXcomposite \
    libXcursor \
    libXdamage \
    libXext \
    libXfixes \
    libXi \
    libXinerama \
    libXrandr \
    libXrender \
    libXtst \
    lsof \
    mesa-libGL \
    net-tools \
    numactl \
    procps-ng \
    sysstat \
    unzip \
    && dnf clean all

# -----------------------------------------------------------------
# 2. Oracle Database XE 21c — preinstall RPM
#    Creates the oracle user/groups and configures security limits.
#    The sysctl kernel-parameter changes it attempts are silently
#    skipped in Docker (expected; pass --privileged at runtime if
#    you need them, or set them on the host before starting the
#    container).
# -----------------------------------------------------------------
RUN curl -fsSL \
    "https://yum.oracle.com/repo/OracleLinux/OL8/appstream/x86_64/getPackage/oracle-database-preinstall-21c-1.0-1.el8.x86_64.rpm" \
    -o /tmp/oracle-preinstall.rpm \
    && rpm -ivh --nodeps /tmp/oracle-preinstall.rpm \
    && rm /tmp/oracle-preinstall.rpm

# -----------------------------------------------------------------
# 3. Oracle Database XE 21c — software install
#    The database is NOT configured here; run
#      /etc/init.d/oracle-xe-21c configure
#    on first container start to create the XE / XEPDB1 instances.
# -----------------------------------------------------------------
RUN curl -fL --retry 5 --retry-delay 3 "${ORACLE_DB_RPM_URL}" \
    -o /tmp/oracle-xe.rpm \
    && dnf install -y /tmp/oracle-xe.rpm \
    && rm /tmp/oracle-xe.rpm

# -----------------------------------------------------------------
# 4. BellSoft Liberica JDK 17 Full (includes LibericaFX / JavaFX,
#    required by SQL Developer)
# -----------------------------------------------------------------
RUN rpm --import https://download.bell-sw.com/pki/GPG-KEY-bellsoft \
    && printf '[BellSoft]\nname=BellSoft Repository\nbaseurl=https://yum.bell-sw.com\nenabled=1\ngpgcheck=1\ngpgkey=https://download.bell-sw.com/pki/GPG-KEY-bellsoft\npriority=1\n' \
    > /etc/yum.repos.d/bellsoft.repo \
    && dnf install -y bellsoft-java17-full \
    && dnf clean all

# -----------------------------------------------------------------
# 5. Re-point java to BellSoft's full JDK
#    BellSoft Full includes JavaFX, required by SQL Developer.
# -----------------------------------------------------------------
RUN JAVA_HOME=$(readlink -f /usr/lib/jvm/bellsoft-java17-full*) \
    && ln -sf "${JAVA_HOME}/bin/java" /usr/bin/java \
    && echo "${JAVA_HOME}/lib" > /etc/ld.so.conf.d/java.conf \
    && echo "${JAVA_HOME}/lib/server" >> /etc/ld.so.conf.d/java.conf \
    && ldconfig \
    && ln -sf "${JAVA_HOME}/lib/libjli.so" /usr/lib/libjli.so \
    && java -version

RUN groupadd --gid "${HOST_GID}" sqldev \
    && useradd \
    --uid "${HOST_UID}" \
    --gid "${HOST_GID}" \
    --create-home \
    --shell /bin/bash \
    sqldev

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
ENV LD_LIBRARY_PATH="/opt/java/lib:/opt/java/lib/server:${LD_LIBRARY_PATH}"
ENV _JAVA_AWT_WM_NONREPARENTING=1
ENV _JAVA_OPTIONS="-Dsun.java2d.pmoffscreen=false"
ENV ORACLE_BASE=/opt/oracle
ENV ORACLE_SID=XE

USER sqldev
WORKDIR /opt/sqldeveloper
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
