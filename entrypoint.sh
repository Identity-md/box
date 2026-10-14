#!/bin/sh
# Runs as root for one reason: to set the firewall before anything else starts. Then it hands
# the command to the `imd` user with every capability gone and no way to get one back, so
# nothing the worker or an agent runs can change these rules.
set -eu

# The internet only, over IPv4. Allowed: this container's own loopback, and DNS to the resolvers
# Docker gave it. Refused: every private, link-local and carrier-grade range (this Mac through
# host.docker.internal, the home network, Tailscale, cloud metadata), Docker's own addresses, and
# all of IPv6.
iptables -A OUTPUT -o lo -j ACCEPT
for ns in $(awk '/^nameserver/ {print $2}' /etc/resolv.conf); do
  case "$ns" in *:*) continue ;; esac
  iptables -A OUTPUT -d "$ns" -p udp --dport 53 -j ACCEPT
  iptables -A OUTPUT -d "$ns" -p tcp --dport 53 -j ACCEPT
done
for host in host.docker.internal gateway.docker.internal; do
  for ip in $(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u); do
    iptables -A OUTPUT -d "$ip" -j REJECT
  done
done
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10 0.0.0.0/8; do
  iptables -A OUTPUT -d "$net" -j REJECT
done
# A home device's public IPv6 address looks like any other on the internet, so no range rule can
# refuse it: the box gets no IPv6 beyond loopback. Where the rules cannot be set, the box must have
# no IPv6 to begin with, or it does not start.
if ! { ip6tables -A OUTPUT -o lo -j ACCEPT && ip6tables -A OUTPUT -j REJECT; } 2>/dev/null; then
  if awk '$6 != "lo" { found = 1 } END { exit !found }' /proc/net/if_inet6 2>/dev/null; then
    echo "This box has IPv6 but cannot firewall it, so it is not starting." >&2
    exit 1
  fi
fi

# A fresh volume is owned by root; the user's home must be the user's.
chown imd:imd /home/imd

exec setpriv --reuid=imd --regid=imd --init-groups --no-new-privs \
  --inh-caps=-all --ambient-caps=-all --bounding-set=-all -- "$@"
