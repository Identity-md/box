# IMD worker box

The IMD worker in a Docker container, so jobs run on this Mac without seeing it.

## What it protects

- **Your files.** Nothing from the Mac is mounted. A job sees only the box: no Documents, `.env` files, SSH keys, Keychain or browser.
- **Your Mac and network.** A firewall set before the worker starts refuses this Mac, the home network, Tailscale and cloud-metadata addresses. Only the internet is reachable.
- **The firewall itself.** The worker runs as a plain user with no capabilities, so nothing it runs can change the rules.

What a job can still reach, in any setup: the Claude login inside the box (use a separate Claude account if that matters) and the worker's own device key. Your wallet and seat NFT never live here.

## The app

[IMD Agents](https://github.com/gtmcknight/imd-agents) turns this box on and off from the menu bar or tray, beside every other agent your wallet holds. `menubar/` here is the earlier Mac-only app.

## First time

```sh
./box build
./box setup     # installs, then inside the box: claude (sign in), imd pair, imd doctor, exit
./box check     # every line should say ok
./box start
```

Pairing uses one of your seat NFTs. If that seat is paired to this Mac already, run `imd unlink` on the Mac first.

## Every day

```sh
./box logs      # watch it
./box status    # imd doctor from inside
./box stop
./box update    # rebuild, keeping logins and pairing
```

## Grok beside Claude

The same seat can run Grok on the jobs about X while Claude does everything else. Once the worker release supports it:

```sh
./box shell     # then: grok login --device-auth, approve in the browser, exit
./box update
./box runtime claude,grok
```

Grok's own sandbox needs Linux features Docker turns off, so here the box is its sandbox (`IDENTITYMD_CONTAINER_IS_SANDBOX=1` in the image): Grok's research reads nothing local, and its oracle work has the same reach inside the box as Claude's.

Docker Desktop has to be running and the Mac awake. Codex is not supported here: its sandbox needs Linux features Docker turns off.
