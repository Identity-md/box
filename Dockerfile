# The IMD worker in a box: a container that sees none of this Mac's files and cannot reach this
# Mac or the home network, only the internet. Everything it keeps lives in one Docker volume.
FROM node:24-bookworm-slim

# git and curl for the worker, iptables for the startup firewall, util-linux for setpriv.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates iptables util-linux \
 && rm -rf /var/lib/apt/lists/*

# Foundry 1.8.3, the version the network's verifier runs, from the release archive checked
# against a pinned SHA-256 (the same script the protocol's CI uses).
COPY install-foundry.sh /tmp/install-foundry.sh
RUN sh /tmp/install-foundry.sh /opt/foundry/bin && rm /tmp/install-foundry.sh

# The worker's own user: no sudo, no password, nothing of the host's.
RUN useradd --create-home --uid 10001 --shell /bin/bash imd

# The worker, the agent CLIs and their logins live in the user's home, which is the volume, so
# they survive a rebuild and the worker's --auto-update can write to its own install.
ENV NPM_CONFIG_PREFIX=/home/imd/.npm-global \
    PATH=/home/imd/.npm-global/bin:/opt/foundry/bin:$PATH \
    HOME=/home/imd

# This box is Grok's sandbox: its own needs Linux user namespaces, which Docker withholds. The
# worker honors this only inside a container, and Grok's research then reads nothing local.
ENV IDENTITYMD_CONTAINER_IS_SANDBOX=1

COPY entrypoint.sh /usr/local/sbin/imd-box-entrypoint
COPY setup.sh /usr/local/bin/imd-box-setup
RUN chmod 0755 /usr/local/sbin/imd-box-entrypoint /usr/local/bin/imd-box-setup

WORKDIR /home/imd
ENTRYPOINT ["/usr/local/sbin/imd-box-entrypoint"]
CMD ["imd", "start", "--runtime", "claude", "--auto-update"]
