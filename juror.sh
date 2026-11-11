#!/bin/sh
# The juror in this box (`imd jury`), for a seat whose holder turned it on: what imd-juror.service is on a
# server with systemd. Root runs this beside the worker: the entrypoint at each start of the box, once
# `imd jury enable` has set a juror up here, and IMD Agents right after it has. One runs at a time.
#
# Each round, as root: `imd jury sync` with root's own copy of the worker, which takes the latest published
# release (held to its checksum) and the worker's RPC endpoints. Then the jury loop as imd-juror, with every
# capability gone, for six hours. Root here can't signal another user's process, so the loop ends itself, and
# the next round starts it on what sync brought. Its lines go to /run/imd-juror-box.log, not the box's log,
# whose last line the app reads as the worker's.
set -u

install=/opt/imd-juror/install.json
cli=/opt/imd-juror/lib/node_modules/@identitymd/worker/dist/cli.js
log=/run/imd-juror-box.log

exec 9>/run/imd-juror-box.lock
flock -n 9 || exit 0
exec >>"$log" 2>&1 </dev/null

say() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

while [ -f "$install" ]; do
  # a log of its own, kept short: the last megabyte or so
  if [ "$(wc -c <"$log")" -gt 1048576 ]; then tail -c 262144 "$log" >"$log.tmp" && cat "$log.tmp" >"$log"; rm -f "$log.tmp"; fi
  say "sync"
  env -i HOME=/root PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/foundry/bin \
    /opt/imd-juror/bin/imd jury sync --yes --worker-user imd || say "sync failed; the juror runs on what it has"
  [ -f "$install" ] || break
  node=$(/usr/local/bin/node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).node))' "$install") || node=/usr/local/bin/node
  say "juror starts"
  setpriv --reuid=imd-juror --regid=imd-juror --init-groups --no-new-privs \
    --inh-caps=-all --ambient-caps=-all --bounding-set=-all -- \
    /usr/bin/env -i HOME=/var/lib/imd-juror IDENTITYMD_HOME=/var/lib/imd-juror PATH=/usr/local/bin:/usr/bin:/bin USER=imd-juror LOGNAME=imd-juror \
    timeout --kill-after=60 6h "$node" "$cli" jury run
  code=$?
  case $code in
    124) say "juror's six hours are up" ;;
    0) say "juror has nothing to do (turned off, or no seat); looking again in ten minutes"; sleep 600 ;;
    *) say "juror stopped (exit $code); again in a minute"; sleep 60 ;;
  esac
done
say "no juror set up here; stopped"
