# Coolify Garage

> Self-hosted S3-compatible object storage (Garage + garage-webui) with automatic cluster
> initialization — ready for one-click deploy on Coolify.

- [Prerequisites](#prerequisites)
- [Features](#features)
- [Installation](#installation)
- [Deploy on Coolify](#deploy-on-coolify)
- [Domains and exposed ports](#domains-and-exposed-ports)
- [Configuration](#configuration)
- [Changing capacity later](#changing-capacity-later)
- [Removing the stack](#removing-the-stack)
- [License](#license)

## Prerequisites

- [Coolify](https://coolify.io/) instance with access to a VPS/server
- [Docker](https://docs.docker.com/get-started/get-docker/) (Coolify manages this on the target
  server automatically)
- Two subdomains pointed at your server — one for the S3 API, one for garage-webui
  (see [Domains and exposed ports](#domains-and-exposed-ports))

## Features

- **Zero manual config** — `garage.toml` is generated at container start from environment
  variables, no SSH or file prep on the host required
- **Automatic cluster init** — the `garage` entrypoint assigns and applies the cluster layout on
  first deploy (idempotent — skips if this node already has a role)
- **Real healthchecks** — `garage` reports healthy only when the admin API says the cluster can
  actually serve requests, and `garage-webui` waits for that before starting
- **garage-webui included** — browse buckets/objects and manage access keys from a web UI
- **S3-compatible** — works with any standard S3 client/SDK (`aws-cli`, `rclone`, `s3cmd`, ...)
- **Configurable capacity** — set initial cluster capacity and zone via environment variables

## Installation

1. Fork or clone this repository
2. Push it to your own Git remote (Coolify deploys from a Git source)

## Deploy on Coolify

1. New Resource → **Docker Compose** → source: this Git repository
2. Set environment variables (see [Configuration](#configuration))
3. Deploy
4. Fill in exactly two of the per-service **Domains** fields, each with the container port
   appended — neither service listens on port 80, so the port is required:
   - **Domains for garage** → `https://s3.<your-domain>:3900` (S3 API)
   - **Domains for garage-webui** → `https://s3-admin.<your-domain>:3909` (web UI)

   Leave ports **3902** and **3903** without a domain — see
   [Domains and exposed ports](#domains-and-exposed-ports).

The `garage` entrypoint handles cluster layout setup automatically on first run — no manual
`docker exec` needed.

Both services expose a healthcheck, so Coolify waits for the cluster to be serving before it
finishes the deploy. `garage` polls the admin API's `/health`, which returns `200` only when
enough nodes are up to answer requests and `503` otherwise — a node whose layout was never
applied reports unhealthy instead of silently accepting traffic. `garage-webui` starts only once
`garage` is healthy.

## Domains and exposed ports

Only **two** domains are needed, and only two should be configured:

| Port | Service      | Domain              | Why                                                         |
| ---- | ------------ | ------------------- | ----------------------------------------------------------- |
| 3900 | garage       | `s3.<domain>`       | S3 API — the endpoint every S3 client talks to              |
| 3909 | garage-webui | `s3-admin.<domain>` | the web UI                                                  |
| 3902 | garage       | —                   | S3 website hosting, intentionally left unrouted (see below) |
| 3903 | garage       | —                   | Admin API, reachable only from inside the compose network   |

**S3 website hosting (port 3902) is intentionally not exposed.** Garage serves buckets as
websites under `<bucket>.<root_domain>`, so making it public requires a wildcard DNS record
_and_ a wildcard TLS certificate (Let's Encrypt DNS-01, or Cloudflare Advanced Certificate
Manager). Without one of those you get a certificate per subdomain at best, which does not scale
to per-bucket hostnames. Since no domain is ever attached, `root_domain` is a fixed placeholder
(`.s3-web.internal`) in `garage/garage.toml.template` rather than an environment variable — edit
it there if you add wildcard certs. Object storage over the S3 API is unaffected.

**The Admin API (port 3903) gets no domain.** `garage-webui` reaches it inside the compose
network at `http://garage:3903`, so routing it publicly would only widen the attack surface — it
is the endpoint that can create buckets and access keys.

**Nothing is published on the host.** Both services declare their ports with `expose:`, not
`ports:`, because on Coolify a published host port bypasses domain-based proxy routing and would
put the S3 API straight on the server's public interface without TLS. The compose file also
defines no network of its own, so the stack uses the per-resource network Coolify creates and its
proxy can reach both containers.

That means a plain `docker compose up -d` on a laptop publishes nothing. For local testing, drop
a `docker-compose.override.yml` next to the compose file — Compose merges it automatically and it
is gitignored:

```yaml
services:
  garage:
    ports:
      - "3900:3900"
      - "3903:3903"
  garage-webui:
    ports:
      - "3909:3909"
```

## Configuration

| Description       | Values                                                                                                                                                        |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Ports:**        | 3900 (S3 API, domain), 3909 (garage-webui, domain), 3902 (S3 website, no domain), 3903 (Admin API, internal only) — all `expose:`, none published on the host |
| **Technologies:** | Garage v2.3.0, garage-webui                                                                                                                                   |
| **URL:**          | http://localhost:3900 (S3 API)                                                                                                                                |
| **Env:**          | `RPC_SECRET`, `ADMIN_TOKEN`, `AUTH_USER_PASS`, `GARAGE_CAPACITY`, `GARAGE_ZONE`, `GARAGE_STARTUP_TIMEOUT`                                                     |

`RPC_SECRET` and `ADMIN_TOKEN` — generate with `openssl rand -hex 32`. `RPC_SECRET` must be
exactly 64 hex characters; the entrypoint validates it and aborts with a clear message otherwise.
Both are declared `${VAR:?...}` in the compose file, so a deploy with either one missing fails at
parse time instead of starting a container that dies seconds later.
`AUTH_USER_PASS` — garage-webui login, `user:<bcrypt hash>` (see [garage-webui README](https://github.com/khairul169/garage-webui) for the expected format).
**Escape every `$` in the bcrypt hash as `$$`.** Docker Compose interpolates env-file values, so
`admin:$2b$12$abcdef…` reaches the container as `admin:$2b$12` — the hash is silently truncated and
login can never succeed. Written as `admin:$$2b$$12$$abcdef…` it arrives intact.
`GARAGE_CAPACITY` / `GARAGE_ZONE` — initial cluster layout capacity and zone (defaults: `64G`, `dc1`).
`GARAGE_STARTUP_TIMEOUT` — seconds the entrypoint waits for the server before giving up (default: `60`).
`ADMIN_TOKEN` is passed to `garage-webui` as `API_ADMIN_KEY`. garage-webui normally reads the
admin token from a mounted `garage.toml`, which does not exist in its container here, so without
that variable it sends an empty bearer token and the admin API rejects every call
(`Forbidden: Invalid Authorization header`) — the UI cannot list buckets or keys.

## Changing capacity later

Automatic init only runs once, against an empty layout. To resize the cluster afterward:

```bash
# `node id -q` prints <node_id>@<address>:<port>; layout assign wants only the id part
docker exec -it <garage_container> sh -c '/garage layout assign -z dc1 -c <new_capacity> $(/garage node id -q | cut -d@ -f1)'
docker exec -it <garage_container> /garage layout show   # read "Current cluster layout version: <n>"
docker exec -it <garage_container> /garage layout apply --version <n+1>
```

## Removing the stack

**`GARAGE_CAPACITY` does not reserve disk space.** It declares how much this node advertises to
the cluster layout, nothing more — a fresh cluster set to `64G` occupies a few megabytes:

```
$ /garage status
ID                ...  Capacity  DataAvail
4f2ad52f5398922e  ...  59.6 GiB  76.1 GiB (77.7%)

$ du -sh /var/lib/garage/data /var/lib/garage/meta
8.0K    /var/lib/garage/data
1.2M    /var/lib/garage/meta
```

What grows is the objects you actually store, and they live in two named Docker volumes,
`garage-meta` and `garage-data`. Named volumes deliberately survive `docker compose down`,
container removal and every redeploy — otherwise a deploy would wipe your buckets.

**Deleting the Coolify resource does not delete them by default.** Coolify's delete dialog has a
**Delete Volumes** action: tick it and the data goes with the resource, leave it clear and the
volumes stay on the VPS taking up space with nothing attached to them. Coolify does not reconnect
preserved volumes to a future resource, so note their real Docker names first if you might want
them back.

To find and reclaim leftovers — the prefix is Coolify's project name, not `coolify-garage`:

```bash
docker volume ls | grep garage       # real names
docker system df -v | grep garage    # how much they hold
docker volume ls -f dangling=true    # volumes with nothing attached

docker volume rm <prefix>_garage-meta <prefix>_garage-data
```

**Leave Coolify's automated volume cleanup off.** Its advanced cleanup can "delete every Docker
volume that is not currently attached to a container". It is disabled by default, and it should
stay that way: if it runs while this stack happens to be stopped — mid-redeploy, after a crash,
after a manual stop — it takes every object in `garage-data` with it.

## License

> This software is developed by **Petr Kašpar** and is licensed under the MIT License.  
> For more details, please refer to the [LICENSE](./LICENSE) file.
