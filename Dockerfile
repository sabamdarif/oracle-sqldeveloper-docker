FROM debian:bookworm-slim
ARG DEBIAN_FRONTEND=noninteractive
ARG HOST_UID=1000
ARG HOST_GID=1000
# This ARG is replaced by build-latest.sh when a newer version is found.
ARG SQLDEVELOPER_URL="https://download.oracle.com/otn_software/java/sqldeveloper/sqldeveloper-26.2.0.186.2220-x64.zip"

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    file \
    fontconfig \
    gnupg \
    ksh \
    libasound2 \
    libfreetype6 \
    libfontconfig1 \
    libgl1 \
    libgtk-3-0 \
    libx11-6 \
    libxcomposite1 \
    libxcursor1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxi6 \
    libxinerama1 \
    libxrandr2 \
    libxrender1 \
    libxtst6 \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Oracle JDK 17 via linuxuprising PPA, followed by BellSoft's full JDK
# (needed for JavaFX support, since Oracle's build lacks it).
RUN echo "deb http://ppa.launchpad.net/linuxuprising/java/ubuntu bionic main" \
    > /etc/apt/sources.list.d/java.list \
    && echo "deb-src http://ppa.launchpad.net/linuxuprising/java/ubuntu bionic main" \
    >> /etc/apt/sources.list.d/java.list \
    && curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xEA8CACC073C3DB2A" \
    | gpg --dearmor -o /usr/share/keyrings/linuxuprising-java.gpg \
    && sed -i 's|^deb |deb [signed-by=/usr/share/keyrings/linuxuprising-java.gpg] |; s|^deb-src |deb-src [signed-by=/usr/share/keyrings/linuxuprising-java.gpg] |' \
    /etc/apt/sources.list.d/java.list \
    && echo "oracle-java17-installer shared/accepted-oracle-license-v1-3 select true" \
    | debconf-set-selections \
    && apt-get update \
    && apt-get install -y --no-install-recommends oracle-java17-installer oracle-java17-set-default \
    && curl -fsSL https://download.bell-sw.com/pki/GPG-KEY-bellsoft \
    | gpg --dearmor -o /usr/share/keyrings/bellsoft.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/bellsoft.gpg] https://apt.bell-sw.com/ stable main" \
    > /etc/apt/sources.list.d/bellsoft.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends bellsoft-java17-full \
    && rm -rf /var/lib/apt/lists/*

# oracle-java17-set-default switches the active java to Oracle's build, which has
# no JavaFX. Re-point java back at BellSoft's full JDK so SQL Developer still works,
# and register its shared libraries (libjli.so etc.) with the dynamic linker.
RUN update-alternatives --set java /usr/lib/jvm/bellsoft-java17-full-amd64/bin/java \
    && echo "/usr/lib/jvm/bellsoft-java17-full-amd64/lib" > /etc/ld.so.conf.d/java.conf \
    && echo "/usr/lib/jvm/bellsoft-java17-full-amd64/lib/server" >> /etc/ld.so.conf.d/java.conf \
    && ldconfig \
    && ln -sf /usr/lib/jvm/bellsoft-java17-full-amd64/lib/libjli.so /usr/lib/libjli.so \
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
RUN ln -s /usr/lib/jvm/bellsoft-java17-full-amd64 /opt/java \
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

USER sqldev
WORKDIR /opt/sqldeveloper
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
