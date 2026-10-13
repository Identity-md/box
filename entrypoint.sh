#!/bin/sh
# Runs as root for one reason: to set the firewall before anything else starts. Then it hands
# the command to the `imd` user with every capability gone and no way to get one back, so
# nothing the worker or an agent runs can change these rules.
set -eu

# The internet only. Allowed: this container's own loopback, and DNS to the resolvers Docker
# gave it. Refused: every private, link-local and carrier-grade range (this Mac through
# host.docker.internal, the home network, Tailscale, cloud metadata) and Docker's own addresses.
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
ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
for net in fc00::/7 fe80::/10; do
  ip6tables -A OUTPUT -d "$net" -j REJECT 2>/dev/null || true
done

# A fresh volume is owned by root; the user's home must be the user's.
chown imd:imd /home/imd

exec setpriv --reuid=imd --regid=imd --init-groups --no-new-privs \
  --inh-caps=-all --ambient-caps=-all --bounding-set=-all -- "$@"
