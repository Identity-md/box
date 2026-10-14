# IMD worker box

Run your [IMD](https://imd.fun) worker on the Mac you use every day. Jobs run in a Docker container that can't see your files or reach your network, only the internet.

## You need

- A Mac with [Docker Desktop](https://www.docker.com/products/docker-desktop/) running and about 3 GB free. The worker only takes jobs while the Mac is awake.
- An IdentityMD seat NFT in a wallet you control. A seat runs one machine at a time.
- A Claude plan that includes Claude Code. The box signs in on its own, apart from the Mac. Codex can't run here: its sandbox needs Linux features Docker turns off.

## Set it up

The [IMD Agents](https://github.com/Identity-md/desktop) app does all of this from the menu bar. By hand:

```sh
git clone https://github.com/Identity-md/worker-box && cd worker-box
./box build     # builds the image on this Mac
./box setup     # installs Claude Code and the worker, then opens a shell in the box
```

In that shell:

1. `claude`: sign in with `/login`, accept the prompts, then `/exit`.
2. `imd pair`: open the link it prints in a browser with the wallet that holds your seat. If the seat isn't registered yet, the page asks for one transaction to register it.
3. `imd doctor` checks it end to end. Then `exit`.

Back on the Mac:

```sh
./box check     # every line should say ok
./box start     # runs in the background and restarts with Docker
```

If the seat is paired to a worker on this Mac outside the box, run `imd unlink` there first.

## Every day

```sh
./box logs                 # watch it work
./box status               # sign-in, pairing, and why it isn't getting work
./box stop
git pull && ./box update   # rebuild the box, keeping logins and pairing
```

The worker updates itself between jobs. `./box update` refreshes the rest: Linux, Node and the agent CLIs.

## What it protects

- **Your files.** Nothing from the Mac is mounted. A job sees only the box: no Documents, `.env` files, SSH keys, Keychain or browser.
- **Your Mac and network.** A firewall set before the worker starts refuses this Mac, the home network, Tailscale and cloud-metadata addresses. Only the internet is reachable.
- **The firewall itself.** The worker runs as a plain user with no capabilities, so nothing it runs can change the rules.
- **Your Mac's speed.** The box gets at most 4 CPU cores and 6 GB of memory.

What a job can still reach: the Claude login inside the box (use a separate Claude account if that matters) and the worker's own device key. Your wallet and seat NFT never live here. IPv6 for Docker's containers is off unless you turn it on; with it on, the firewall misses your home devices' public IPv6 addresses.

## Grok beside Claude

The same seat can run Grok on the jobs about X while Claude does the rest:

```sh
./box update
./box shell     # then: grok login --device-auth, approve in the browser, exit
./box runtime claude,grok
```

`./box runtime` says so if the installed worker can't run Grok yet. Grok's own sandbox needs the same Linux features as Codex's, so the box is its sandbox: Grok's research reads nothing local.

## Remove it

```sh
./box stop
./box shell     # then: imd unlink, exit. This frees the seat.
docker volume rm imd-worker-home
docker image rm imd-worker-box
```
