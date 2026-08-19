# vps-infra

Infrastructure for a single Debian 13 host, expressed as code.

Two layers, deliberately separate:

- **`bootstrap/`** — everything the host needs before it can run anything.
  Plain shell and nftables. No dependencies beyond a stock Debian install.
- **`stack/`** — everything that serves traffic. Docker Compose behind a
  Traefik reverse proxy.

The split matters: bootstrap has to work on a machine where nothing is
installed yet, so it cannot assume Docker, Python or a package manager
that has already been configured.

## Bootstrap

```sh
bash bootstrap/harden.sh            # report only, changes nothing
bash bootstrap/harden.sh --apply    # make the changes
bash bootstrap/harden.sh --confirm  # cancel the firewall auto-rollback
```

The script is idempotent, so running it again is also a drift check: on an
already-configured host every section reports `[ok]` and nothing is written.

What it does:

| | |
|---|---|
| SSH | key-only, no password auth, root login restricted to keys |
| Firewall | nftables, default-deny inbound, SSH + ICMP + tailnet only |
| Updates | unattended security upgrades, no automatic reboot |
| Hygiene | LLMNR off, journal capped, base tooling installed |

`bootstrap/docker.sh` follows the same shape and installs Docker Engine from
the upstream repository, because Debian's own `docker.io` package lags and
ships no compose plugin. It also caps container logs: the default `json-file`
driver has no size limit at all, so a chatty container can fill a disk.

```sh
bash bootstrap/docker.sh          # report only
bash bootstrap/docker.sh --apply  # install
```

### The dead man's switch

Activating a firewall over the same SSH connection it might block is the
classic way to lock yourself out of a remote machine. So when the ruleset
goes live, `harden.sh` schedules its own removal ten minutes later:

```sh
systemd-run --unit=fw-rollback --on-active=600 /usr/sbin/nft flush ruleset
```

You then open a *second* session to prove the rules let you in, and only
then run `--confirm`, which cancels the timer. Do nothing, and the host
returns to its previous state on its own. There is no sequence of events
where a mistake here costs you the machine.

### Why the ruleset does not flush globally

The obvious first line of an nftables config is `flush ruleset`. It is also
wrong on any host running Tailscale or Docker, because both install tables
of their own at runtime. A global flush deletes them, and nothing notices —
until the next reboot, when the tailnet is silently gone.

So the config replaces only its own table:

```
table inet filter
delete table inet filter
table inet filter { ... }
```

Creating the table first makes the delete safe on a fresh host where it does
not exist yet.

### Why the forward chain is not simply closed

A `policy drop` on the forward chain looks like the obvious default for a
host that is not a router. It also breaks every Docker container's network
access — because a drop in *any* table hooked at forward ends the packet,
regardless of what Docker's own rules in `table ip filter` would have said.
Verified on a live daemon: with a bare drop policy, a container cannot reach
the internet at all.

The chain therefore keeps default-deny but accepts traffic on Docker's
bridges explicitly. Docker's own `DOCKER-USER` and isolation chains still
filter, so this does not weaken container isolation — it only stops two
tables from fighting over the same hook.

Two more details that are easy to get wrong:

- `iifname "tailscale0"`, not `iif`. `iif` resolves the name to an interface
  index when the ruleset loads — and `tailscale0` does not exist yet at that
  point. `iifname` compares at runtime.
- Drop-in files in `/etc/ssh/sshd_config.d/` are read in lexical order and
  OpenSSH keeps the **first** value it sees. The hardening drop-in is named
  `00-hardening.conf` so it wins over the `50-cloud-init.conf` that ships
  with the cloud image and enables password authentication.

## Stack

```sh
cp .env.example .env    # fill in, never committed
cd stack
touch traefik/acme.json && chmod 600 traefik/acme.json
docker compose up -d
```

Traefik terminates TLS and obtains certificates over the ACME TLS-ALPN
challenge, which needs only port 443 — so the HTTP-to-HTTPS redirect cannot
interfere with certificate renewal the way an HTTP-01 challenge would.

Services opt in to routing with `traefik.enable=true`. Nothing is exposed by
accident just because it listens on a port.

### Adding a site

Add a service block with a `Host()` rule. The proxy is not touched:

```yaml
  another-site:
    build: ./another-site
    networks: [edge]
    labels:
      traefik.enable: "true"
      traefik.http.routers.another.rule: "Host(`example.org`)"
      traefik.http.services.another.loadbalancer.server.port: "8080"
```

## What is not in here

No secrets, and no values specific to one machine. Hostnames, contact
addresses and credentials live in `.env`, which is gitignored. This
repository describes the shape of a host, not a particular instance of one —
which is what makes it safe to publish.

## Note on Docker and the firewall

Docker publishes ports by writing its own nat and filter rules, which are
evaluated *before* the input chain in this repository's ruleset. A published
container port is therefore reachable even though the policy here is
default-deny. That is intended for 80 and 443, but it is worth knowing
before publishing anything else: binding to `127.0.0.1:PORT` in the compose
file is what actually keeps a port private.
