# StoatChat Platform

Self-host [Stoatchat](https://github.com/stoatchat) on Kubernetes using Helmfile. The same charts also generate a Docker Compose setup for single-machine deployments — one source of truth for all targets.

> **No Kubernetes cluster?** See [Deploy with Compose](docs/compose-deployment.md).

> **Breaking change (14 February 2026):** cert-manager, Reflector and HAProxy have moved to non-prefixed namespaces (`cert-manager`, `reflector`, `haproxy-controller`). They should never have had `stoatchat-` in their namespace names — these are cluster-wide components. See [migration guide](docs/migrate-namespaces.md). (This doesn't impact docker-compose users)

The [official self-hosted repo](https://github.com/stoatchat/self-hosted/issues/176) is awaiting updates, so I built this Helmfile alternative [as suggested there](https://github.com/stoatchat/self-hosted/issues/176#issuecomment-2668227771). This is a **reference implementation** — monitoring, GitOps, and security policies are left to operators. Architecture adapted from [lasuite-platform](https://github.com/baptisterajaut/lasuite-platform) (La Suite Numérique).

## Architecture

All services run behind a single domain with path-based routing via HAProxy
Ingress. LiveKit uses a separate subdomain.

```
stoatchat.local
  /api/*      →  api (REST)
  /ws         →  events (WebSocket)
  /autumn/*   →  file-server (uploads)
  /january/*  →  proxy (embeds/metadata)
  /gifbox/*   →  gifbox (GIF proxy)
  /*          →  client (web UI)

  /livekit/*  →  livekit-server (WebRTC)
```

Backend services share a single `Revolt.toml` configuration file, generated
as a Kubernetes ConfigMap by the `stoatchat-config` chart and replicated across
namespaces via Reflector.

## Prerequisites

- Kubernetes cluster (tested on k3s, any conformant distribution works)
- [Helm](https://helm.sh/) v3
- [Helmfile](https://github.com/helmfile/helmfile) v0.169+
- `kubectl` configured for the target cluster
- `openssl` (for secret generation)

## Quick Start

```bash
git clone git@github.com:baptisterajaut/stoatchat-platform.git && cd stoatchat-platform

# 1. Generate configuration and deploy
./init.sh
```

`init.sh` offers two modes:

1. **Local development** — deploys everything on a local cluster with
   self-signed TLS
2. **Remote deployment** — scaffolds an environment file for an external
   cluster with Let's Encrypt TLS and external infrastructure

For local mode, `init.sh`:

1. Checks that `helm`, `kubectl`, `helmfile`, and `openssl` are installed
2. Copies `environments/local.yaml.example` → `environments/local.yaml`
   and generates a random `secretSeed`
3. Generates VAPID keypair → `environments/vapid.secret.yaml`
4. Generates file encryption key → `environments/files.secret.yaml`
5. Pauses for you to review `environments/local.yaml`
6. Runs `helmfile -e local sync` (deploys all releases)
7. Prints the LoadBalancer IP and `/etc/hosts` entry
8. Exports the self-signed CA certificate to `stoatchat-ca.pem`

After the script completes:

```bash
# Add to /etc/hosts (use the IP printed by init.sh)
<LB_IP>  stoatchat.local

# Trust the CA certificate (see TLS section below)
```

Open `https://stoatchat.local` and create an account.

### Post-deploy only

If you need to re-extract the hosts entry and CA certificate after a
redeployment without re-running the full setup:

```bash
./init.sh --post-deploy
```

### Remote deployment

For remote mode, `init.sh` generates `environments/<name>.yaml` from
`remote.yaml.example` and prints instructions for registering the
environment in `helmfile.yaml.gotmpl`. A commented-out template is
already provided there:

```yaml
# my-instance:
#   values:
#     - versions/infra-versions.yaml
#     - versions/stoatchat-versions.yaml
#     - environments/_defaults.yaml
#     - versions/infra-versions.yaml
#     - versions/stoatchat-versions.yaml
#     - environments/my-instance.yaml
#     - environments/my-instance.secret-overrides.yaml  # optional
#     - environments/vapid.secret.yaml
#     - environments/files.secret.yaml
```

See [Advanced deployment](docs/advanced-deployment.md) for external
infrastructure, secret overrides, and production configuration.

## Manual Installation

```bash
# 1. Create environment file
cp environments/local.yaml.example environments/local.yaml

# 2. Set a random seed
SEED=$(openssl rand -hex 24)
# Edit environments/local.yaml, set secretSeed: "<seed>"

# 3. Generate VAPID keys (push notifications)
TMPKEY=$(mktemp)
openssl ecparam -name prime256v1 -genkey -noout -out "$TMPKEY"
VAPID_PRIVATE=$(base64 < "$TMPKEY" | tr -d '\n' | tr -d '=')
VAPID_PUBLIC=$(openssl ec -in "$TMPKEY" -pubout -outform DER 2>/dev/null \
  | tail -c 65 | base64 | tr '/+' '_-' | tr -d '\n' | tr -d '=')
rm -f "$TMPKEY"

cat > environments/vapid.secret.yaml <<EOF
vapid:
  privateKey: "$VAPID_PRIVATE"
  publicKey: "$VAPID_PUBLIC"
EOF

# 4. Generate file encryption key
cat > environments/files.secret.yaml <<EOF
files:
  encryptionKey: "$(openssl rand -base64 32)"
EOF

# 5. Review local.yaml, then deploy
helmfile -e local sync
```

## Configuration

### `environments/local.yaml`

Primary configuration file. Created from `local.yaml.example` by `init.sh`.

| Key | Default | Description |
|-----|---------|-------------|
| `domain` | `stoatchat.local` | Base domain for all services |
| `secretSeed` | (generated) | Master seed for deterministic secret derivation |
| `apps.<name>.enabled` | `true`/`false` | Toggle individual services |
| `apps.api.webhooks` | `true` | Enable incoming webhooks (upstream defaults to `false`) |
| `apps.gifbox.tenorKey` | `""` | Tenor API key (see [known limitation](docs/known-limitations.md#gif-picker-cannot-be-disabled) — gifbox is currently unusable in self-hosted) |
| `livekit.enabled` | `false` | Enable LiveKit voice/video (requires extra config) |
| `livekit.rtcPortRangeStart` | `50000` | First UDP port for WebRTC media |
| `livekit.rtcPortRangeEnd` | `60000` | Last UDP port for WebRTC media |
| `tls.issuer` | `selfsigned` | TLS issuer: `selfsigned` or `letsencrypt` |
| `smtp.host` | `""` | SMTP server for email verification (empty = disabled) |

### App toggles

All apps default to enabled except `gifbox`, `voiceIngress` (requires LiveKit), and `livekit` itself.

> **Note**: `gifbox` is disabled by default and should stay that way. The client uses the official Stoatchat gifbox instance (`api.gifbox.me`) regardless of whether a local gifbox is deployed. See [known limitations](docs/known-limitations.md#gif-picker-cannot-be-disabled).

```yaml
apps:
  voiceIngress:
    enabled: true     # enable after livekit is enabled
```

### Webhooks

Webhooks are **enabled by default** (`apps.api.webhooks: true`). This diverges from upstream Stoatchat, which defaults to `false` — there may be a reason for that we're not aware of, so disable them if you run into issues:

```yaml
apps:
  api:
    webhooks: false
```

### LiveKit (voice/video)

To enable voice and video calls:

```yaml
livekit:
  enabled: true

apps:
  voiceIngress:
    enabled: true
```

LiveKit requires host-network access for WebRTC media. The UDP port range
defaults to 50000–60000 (configurable via `livekit.rtcPortRangeStart` /
`rtcPortRangeEnd`). TCP port 7881 must also be open. LiveKit is exposed
at `/livekit` on the main domain via an Ingress created by the
`stoatchat-config` chart.

### SMTP

Without SMTP configured, email verification is skipped entirely (see
[Known limitations](docs/known-limitations.md#smtp-disabled--no-email-verification)).
To enable it:

```yaml
smtp:
  host: "smtp.example.com"
  port: 587
  username: "user"
  password: "pass"
  fromAddress: "noreply@stoatchat.example.com"
  useTls: false
  useStarttls: true
```

### TLS

Two issuers are supported:

- **`selfsigned`** (default) — cert-manager generates a local CA. Suitable
  for development. Requires trusting the CA certificate (see below).
- **`letsencrypt`** — production certificates via ACME HTTP-01 challenge.
  Requires `adminEmail` to be set and the domain to be publicly reachable.

### Secret derivation

All infrastructure credentials (MongoDB, Redis, RabbitMQ, MinIO, LiveKit)
are deterministically derived from `secretSeed` using
`sha256(seed:identifier)`. This means a single seed reproduces all
passwords — no separate credential management needed.

Non-derivable secrets (VAPID keypair, file encryption key) are generated
once by `init.sh` and stored in gitignored `*.secret.yaml` files.

## Client Image

The web client (`for-web`, SolidJS) has no upstream Docker image suitable
for self-hosting (upstream bakes env vars at build time). A custom
Dockerfile in `docker/client/` clones the repo, builds with placeholder
env vars, and serves via nginx with runtime `sed` replacement at startup.

Build settings are in `docker/client/build.conf`:

```bash
WEB_REPO="https://github.com/Dadadah/stoat-for-web"   # web client git repo
WEB_REF="patch/enablevideo"                            # branch or tag to build
ASSETS_REPO="https://github.com/stoatchat/assets.git"  # assets git repo
WEB_IMAGE="baptisterajaut/stoatchat-web"               # destination image name
```

Build and push:

```bash
# Uses values from build.conf
docker/client/build.sh

# Custom tag (first argument, default: dev)
docker/client/build.sh v1.0.0
```

Environment variables still override `build.conf` for CI usage:

```bash
STOATCHAT_WEBCLIENT_IMAGE_PUBLISHNAME=myuser/stoatchat-web \
  STOATCHAT_WEB_REF=v1.0.0 \
  docker/client/build.sh v1.0.0
```

The script auto-detects `nerdctl` or `docker` and prompts before pushing.

> PR [stoatchat/for-web#522](https://github.com/stoatchat/for-web/pull/522)
> tracks an official upstream Dockerfile. It doesn't seem to include runtime
> env replacement so far, so this custom build remains necessary for self-hosting in the meantime.

## Access

| URL | Service |
|-----|---------|
| `https://stoatchat.local` | Web client |
| `https://stoatchat.local/api` | REST API |
| `https://stoatchat.local/ws` | WebSocket events |
| `https://stoatchat.local/autumn` | File server |
| `https://stoatchat.local/january` | Metadata proxy |
| `https://stoatchat.local/gifbox` | GIF proxy |
| `wss://stoatchat.local/livekit` | LiveKit (if enabled) |

Create an account at the web client URL. Without SMTP configured, email
verification is skipped and accounts are immediately usable.

## Infrastructure

| Component | Chart | Namespace | Notes |
|-----------|-------|-----------|-------|
| MongoDB | bitnami/mongodb | `stoatchat-mongodb` | Primary database |
| Redis | bitnami/redis | `stoatchat-redis` | Event broker and KV store |
| RabbitMQ | stoatchat-app (official image) | `stoatchat-rabbitmq` | Message broker |
| MinIO | minio/minio | `stoatchat-minio` | S3-compatible object storage |
| LiveKit | livekit/livekit-server | `stoatchat-livekit` | WebRTC server (optional) |
| cert-manager | jetstack/cert-manager | `cert-manager` | TLS certificate management |
| HAProxy | haproxytech/kubernetes-ingress | `haproxy-controller` | Ingress controller |
| Reflector | emberstack/reflector | `reflector` | Cross-namespace secret replication |

All Stoatchat application services (api, events, file-server, etc.) deploy into
the `stoatchat` namespace using the generic `helm/stoatchat-app` chart.

## TLS / CA Certificate

With `tls.issuer: selfsigned`, cert-manager generates a local CA. Browsers
will show certificate warnings until the CA is trusted.

The CA certificate is exported to `stoatchat-ca.pem` by `init.sh`. You can also
extract it manually:

```bash
kubectl get secret stoatchat-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > stoatchat-ca.pem
```

### macOS

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain stoatchat-ca.pem
```

### Linux (Debian/Ubuntu)

```bash
sudo cp stoatchat-ca.pem /usr/local/share/ca-certificates/stoatchat-ca.crt
sudo update-ca-certificates
```

### Windows

PowerShell (requires admin):

```powershell
Import-Certificate -FilePath "stoatchat-ca.pem" -CertStoreLocation Cert:\LocalMachine\Root
```

Or with certutil:

```cmd
certutil.exe -addstore root stoatchat-ca.pem
```

You can also import via the GUI: Chrome → Settings → Privacy and security →
Security → Manage certificates, or search "Manage computer certificates" in
the Start menu.

### Firefox

Firefox uses its own certificate store. Import `stoatchat-ca.pem` via
Settings → Privacy & Security → Certificates → View Certificates →
Authorities → Import.

## Documentation

- [Deploy with Compose](docs/compose-deployment.md) — run without Kubernetes using `generate-compose.sh`
- [Advanced deployment](docs/advanced-deployment.md) — external infrastructure, secret overrides, production guide
- [Architecture decisions](docs/decisions.md)
- [Known limitations](docs/known-limitations.md)

## Acknowledgments

This project is inspired by the official
[stoatchat/self-hosted](https://github.com/stoatchat/self-hosted) Docker
Compose setup and adapts it for Kubernetes. I am not affiliated with the
Stoatchat/Revolt project.

The Helmfile structure, infrastructure charts, secret derivation pattern,
and deployment tooling are directly adapted from
[lasuite-platform](https://github.com/baptisterajaut/lasuite-platform)
(La Suite Numérique). See [docs/decisions.md](docs/decisions.md) for a
detailed breakdown of what was reused and what was adapted.

Feedback, bug reports, and contributions are welcome — feel free to open
an issue.
