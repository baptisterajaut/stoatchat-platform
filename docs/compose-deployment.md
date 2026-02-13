# Deploy with Docker Compose

Run Stoatchat without a Kubernetes cluster. The `generate-compose.sh` script
converts the same Helmfile output into a `compose.yml` + `Caddyfile`, using
the unholy script [helmfile2compose](https://github.com/baptisterajaut/helmfile2compose).

## What you need

- Docker or a compatible runtime (`nerdctl`, `podman`) with compose support
- [Helm](https://helm.sh/) v3 and [Helmfile](https://github.com/helmfile/helmfile) v0.169+
- Python 3 with `pyyaml` (`pip install pyyaml`)
- `openssl`

> **Bind mount permissions:** MongoDB (Bitnami) runs as UID 1001 and may fail with `permission denied` on host-mounted data directories owned by your user (UID 1000). This is handled automatically on first run.

> **Windows:** native Windows (PowerShell / cmd) is not supported. Use WSL 2 with Docker Desktop's WSL backend.

> **Docker Desktop:** fine for testing, not recommended beyond that. LiveKit (WebRTC) has been reported to fail with "ICE failed" errors under Docker Desktop — likely related to the NAT/bridge layer between the VM and the host. For anything beyond testing, deploy on bare metal, a dedicated server, or a VPS with its own public IP.

## Quick start

```bash
git clone git@github.com:baptisterajaut/stoatchat-platform.git && cd stoatchat-platform
./generate-compose.sh
docker compose up -d   # or: nerdctl compose up -d
```

On the first run, the script asks a few questions:

1. **Domain** (default: `stoatchat.local`)
2. **Voice/video** — enable LiveKit? (default: no)
3. **Data directory** — where to store persistent data (default: `~/stoat-data`)
4. **Let's Encrypt email** — only asked for public domains (skipped for `.local` and `localhost`)

It then generates all secrets, renders Helmfile templates, and produces the
final `compose.yml` and `Caddyfile`.

Subsequent runs skip the interactive setup and just re-render — useful after
pulling chart updates or changing environment values.

## What gets generated

| File | Description |
|------|-------------|
| `environments/compose.yaml` | Helmfile environment values (domain, seed, toggles) |
| `environments/vapid.secret.yaml` | VAPID keypair for push notifications |
| `environments/files.secret.yaml` | File encryption key |
| `helmfile2compose.yaml` | Conversion config (volumes, overrides, custom services) |
| `compose.yml` | Docker Compose service definitions |
| `Caddyfile` | Reverse proxy config (TLS, path routing) |
| `configmaps/` | Generated config files (e.g. `Revolt.toml`) |
| `secrets/` | Generated secret files (e.g. MinIO credentials) |

All generated files are gitignored.

## TLS and DNS

**TLS is always on.** Stoatchat URLs use `https://` and `wss://`, and Caddy
handles certificates automatically. Plain HTTP is not supported.

| Domain type | TLS provider | Action needed |
|-------------|-------------|---------------|
| `.local` / `localhost` | Caddy internal CA | Accept the certificate warning, or extract and trust the root CA (see below) |
| Public domain | Let's Encrypt (automatic) | Point DNS to the host, Caddy handles the rest |

To trust the Caddy root CA (avoids browser certificate warnings for `.local` domains):

```bash
# After first start, the CA cert is at:
cp data/caddy/pki/authorities/local/root.crt caddy-root-ca.pem
# Then trust it the same way as the K8s self-signed CA (see main README TLS section)
```

If you're not exposing to the internet, use a `.local` domain (the default)
and add an `/etc/hosts` entry:

```
127.0.0.1  <domain> livekit.<domain>
```

For public domains, point your domain (and `livekit.<domain>` if voice is
enabled) to the host running compose.

## Credentials

All infrastructure passwords are derived from `secretSeed` via
`sha256(seed:identifier)`. The script prints them at the end:

```
Credentials (derived from secretSeed):
  MongoDB:  stoatchat / <derived>
  RabbitMQ: stoatchat / <derived>
  MinIO:    <derived> / <derived>
```

To retrieve them later, re-run `./generate-compose.sh` — it prints
credentials every time (and also regenerates compose from the current charts).

## Configuration

### Disabling services

Toggle services in `environments/compose.yaml`:

```yaml
apps:
  gifbox:
    enabled: false
  voiceIngress:
    enabled: false

livekit:
  enabled: false
```

Then re-run `./generate-compose.sh && docker compose up -d`.

### Webhooks

Webhooks are enabled by default. See [Webhooks](../README.md#webhooks) for details and how to disable.

### SMTP

Without SMTP, email verification is skipped and accounts are immediately
usable. To enable it, edit `environments/compose.yaml`:

```yaml
smtp:
  host: "smtp.example.com"
  port: 587
  username: "user"
  password: "pass"
  fromAddress: "noreply@example.com"
  useTls: false
  useStarttls: true
```

### LiveKit port range

Kubernetes defaults to 50000-60000 (10,000 ports) for WebRTC media because
LiveKit uses host networking — ports are opened directly on the node without
any iptables overhead. Docker publishes ports via iptables rules, and
10,000 port mappings will bring iptables to its knees (extremely slow
`docker compose up`, high CPU on rule evaluation). The compose environment
defaults to 50000-50100 (100 ports) to avoid this.

Increase the range only if you actually need more concurrent media streams:

```yaml
livekit:
  rtcPortRangeStart: 50000
  rtcPortRangeEnd: 50500
```

### Voice

When LiveKit is enabled in compose, `voice-ingress` is also enabled by
default (both use the same toggle in `compose.yaml.example`). On Kubernetes,
`apps.voiceIngress.enabled` must be set separately.

Voice functionality may be incomplete upstream — `voice-ingress` is missing
from the official [stoatchat/self-hosted](https://github.com/stoatchat/self-hosted)
Docker Compose setup.

## Day-to-day operations

For regenerating, data management, troubleshooting, and architecture details, see the [helmfile2compose usage guide](https://github.com/baptisterajaut/helmfile2compose/blob/main/docs/usage-guide.md) and [architecture](https://github.com/baptisterajaut/helmfile2compose/blob/main/docs/architecture.md).
