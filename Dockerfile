ARG BASE_IMAGE="gvenzl/oracle-free:23-slim-faststart"
FROM ${BASE_IMAGE}

ARG HOST_UID=1000
ARG HOST_GID=1000
ARG SQLDEVELOPER_URL="https://download.oracle.com/otn_software/java/sqldeveloper/sqldeveloper-26.2.0.186.2220-x64.zip"
ARG ORACLE_PASSWORD="password"

USER root

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

RUN rpm --import https://download.bell-sw.com/pki/GPG-KEY-bellsoft \
    && printf '[BellSoft]\nname=BellSoft Repository\nbaseurl=https://yum.bell-sw.com\nenabled=1\ngpgcheck=1\ngpgkey=https://download.bell-sw.com/pki/GPG-KEY-bellsoft\n' \
    > /etc/yum.repos.d/bellsoft.repo \
    && microdnf -y install bellsoft-java17-full \
    && microdnf clean all

RUN JAVA_HOME=$(readlink -f /usr/lib/jvm/bellsoft-java17-full*) \
    && ln -s "${JAVA_HOME}" /opt/java \
    && ln -sf "${JAVA_HOME}/bin/java" /usr/bin/java \
    && echo "${JAVA_HOME}/lib" > /etc/ld.so.conf.d/java.conf \
    && echo "${JAVA_HOME}/lib/server" >> /etc/ld.so.conf.d/java.conf \
    && ldconfig \
    && ln -sf "${JAVA_HOME}/lib/libjli.so" /usr/lib64/libjli.so \
    && java -version

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

RUN CONF=/opt/sqldeveloper/sqldeveloper/bin/sqldeveloper.conf \
    && test -f "${CONF}" \
    && printf '\nSetJavaHome /opt/java\n' >> "${CONF}" \
    && rm -rf /opt/sqldeveloper/jdk

RUN LAUNCHER=/opt/sqldeveloper/ide/bin/launcher.sh \
    && test -f "${LAUNCHER}" \
    && if ! grep -q '^AddWindowsVM11OrHigherOption()' "${LAUNCHER}"; then \
    sed -i '2i AddWindowsVM11OrHigherOption() { :; }' "${LAUNCHER}"; \
    fi

COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --chmod=755 setup-sqldeveloper-connection.sh /usr/local/bin/setup-sqldeveloper-connection
COPY --chmod=644 SeedSqlDeveloperConnection.java /usr/local/lib/sqldeveloper-bootstrap/SeedSqlDeveloperConnection.java
RUN /opt/java/bin/javac -cp '/opt/sqldeveloper/sqldeveloper/lib/*' \
    -d /usr/local/lib/sqldeveloper-bootstrap \
    /usr/local/lib/sqldeveloper-bootstrap/SeedSqlDeveloperConnection.java
COPY --chmod=644 tnsnames.ora /opt/sqldeveloper/network/admin/tnsnames.ora
RUN chown -R sqldev:sqldev /home/sqldev \
    && chmod -R a+rX /opt/sqldeveloper

ENV HOME=/home/sqldev
ENV TNS_ADMIN=/opt/sqldeveloper/network/admin
ENV SQLDEVELOPER_AUTO_CONNECTION=true
ENV JAVA_HOME=/opt/java
ENV PATH="/opt/java/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/java/lib:/opt/java/lib/server"
ENV _JAVA_AWT_WM_NONREPARENTING=1
ENV _JAVA_OPTIONS="-Dsun.java2d.pmoffscreen=false"
ENV ORACLE_PASSWORD="${ORACLE_PASSWORD}"

EXPOSE 1521

HEALTHCHECK CMD sudo -iu oracle healthcheck.sh >/dev/null || exit 1

USER sqldev
WORKDIR /opt/sqldeveloper
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
