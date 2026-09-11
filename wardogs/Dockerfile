# Shadow Haven Hosting - WARDOGS dedicated server image (Pterodactyl / Pelican yolk style)
#
# Build:  docker build -t ghcr.io/shadowhaven/wardogs:latest .
# The game itself is NOT baked in: it is installed by SteamCMD into /home/container
# at install time by the egg, and kept up to date by entrypoint.sh at every boot.

FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="WARDOGS Dedicated Server" \
      org.opencontainers.image.vendor="Shadow Haven Hosting" \
      org.opencontainers.image.source="https://github.com/shadowhaven/wardogs-egg"

ENV DEBIAN_FRONTEND=noninteractive \
    USER=container HOME=/home/container \
    STEAMCMD_DIR=/home/container/steamcmd

RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl wget tar unzip bzip2 gzip jq gettext-base \
      procps iproute2 tini locales tzdata \
      # steamcmd is 32-bit
      lib32gcc-s1 lib32stdc++6 libc6:i386 \
      # UE5 Linux server runtime
      libc6 libstdc++6 libgcc-s1 libatomic1 zlib1g \
      libssl3 libcurl4 libicu72 libtinfo6 \
 && sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

RUN useradd -d /home/container -m container

USER container
WORKDIR /home/container

COPY --chown=container:container entrypoint.sh /entrypoint.sh
COPY --chown=container:container wardogs-console.sh /usr/local/bin/wardogs-console
RUN chmod +x /entrypoint.sh /usr/local/bin/wardogs-console

STOPSIGNAL SIGINT
ENTRYPOINT ["/usr/bin/tini", "--", "/bin/bash", "/entrypoint.sh"]
