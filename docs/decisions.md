# Architecture Decisions

This document records the key architecture decisions made for the
stoatchat-platform Helmfile deployment and the reasoning behind them.

## Helmfile structure from lasuite-platform

The entire Helmfile layout — repository definitions, environment layering,
version files, computed values, and release structure — is adapted from
[lasuite-platform](https://github.com/baptisterajaut/lasuite-platform)
(La Suite Numérique), which I authored. This gives me a battle-tested
foundation for multi-namespace Kubernetes deployments with Helmfile.

## Single generic chart (`stoat-app`)

Stoat services have no upstream Helm charts. Rather than creating a chart
per service (which would mean 9 near-identical charts), a single generic
`helm/stoat-app` chart handles all of them. It provides:

- Deployment (with configurable image, ports, env vars, volume mounts)
- Service
- Ingress (optional, with per-service path and rewrite)
- PersistentVolumeClaim (optional)

Each service is configured entirely through its `values/<service>.yaml.gotmpl`
file. This pattern keeps the chart DRY while remaining flexible enough for
the differences between services (some have ingress, some don't; some need
PVCs, some don't).

## Revolt.toml as ConfigMap

La Suite configures each app via environment variables. Stoat (Revolt)
uses a single shared `Revolt.toml` configuration file read by all backend
services.

The `stoat-config` chart generates this TOML from Helmfile values via a Go
template (`revolt-toml-configmap.yaml`) and stores it as a ConfigMap.
Reflector replicates it to the `stoat` namespace where app pods mount it.

This is a fundamental difference from lasuite-platform: one shared config
file vs per-app env vars.

## Secret derivation

Following lasuite-platform's pattern, infrastructure credentials are
deterministically derived from a single `secretSeed` via
`sha256(seed:identifier)`. A single seed reproduces all passwords — no
separate credential management needed.

Two secrets cannot be derived this way and are generated once by `init.sh`:
- **VAPID keypair** (EC prime256v1) — must be a valid EC key, not a hash
- **File encryption key** (32 bytes random base64)

See [Advanced deployment — How secrets work](advanced-deployment.md#how-secrets-work)
for the full identifier table and override mechanism.

## Per-service Ingress with HAProxy merge

Each service defines its own Kubernetes Ingress resource via the `stoat-app`
chart. The HAProxy Ingress controller (haproxytech) merges all Ingress
resources sharing the same host (`stoat.local`) into a single frontend.
Path prefix stripping uses `haproxy.org/path-rewrite` (haproxytech
annotation). Services mapped to `/` (the client) get no rewrite annotation.

The haproxytech and community haproxy-ingress projects use incompatible
annotation prefixes — see
[Known limitations](known-limitations.md#haproxy-annotation-mismatch).

## Namespace split

Infrastructure and application services are isolated in separate namespaces,
matching the lasuite-platform pattern:

| Namespace | Contents |
|-----------|----------|
| `stoat-cert-manager` | cert-manager |
| `stoat-ingress` | HAProxy Ingress controller |
| `stoat-reflector` | Reflector |
| `stoat-mongodb` | MongoDB |
| `stoat-redis` | Redis |
| `stoat-rabbitmq` | RabbitMQ |
| `stoat-minio` | MinIO |
| `stoat-livekit` | LiveKit server + Ingress |
| `stoat-config` | stoat-config chart (ConfigMap, ClusterIssuer, namespace creation) |
| `stoat` | All application services |

The `stoat` namespace is created by the `stoat-config` chart
(`namespaces.yaml`) so it exists before app releases deploy into it.

Cross-namespace resources (TLS secrets, ConfigMap) are replicated by
Reflector using annotations.

## Redis vs KeyDB

lasuite-platform uses bitnami/redis. Revolt originally used KeyDB, which is
API-compatible with Redis. I kept bitnami/redis since it was already in use
in lasuite-platform. The reverse is also viable — if a good KeyDB chart
surfaces, both projects could switch to KeyDB instead. The best candidate
today is enapter/keydb (multimaster, auth, persistence) but it's been
dormant since March 2023. Worth revisiting if that changes or a new chart
appears.

## RabbitMQ — official image via stoat-app

After bitnami removed all `bitnami/rabbitmq` images from Docker Hub,
RabbitMQ is deployed using the generic `stoat-app` chart with the official
`rabbitmq:4-management` image.

## MongoDB — bitnami with `latest` tag

The bitnami chart is kept for its replicaset init and auth setup, but the
image tag is forced to `latest` (specific tags were removed from Docker Hub).
Long-term, MongoDB should migrate to the official `mongo` image with a
custom chart or to an operator (Percona, MongoDB Community Operator).

See [Known limitations — Bitnami image removal](known-limitations.md#bitnami-image-removal-from-docker-hub)
for operational details.

## LiveKit — official chart, custom Ingress

The `stoatchat/livekit-server` fork is just rebranding with minor fixes. I
use the official upstream chart and image (`livekit/livekit-server`).

The official chart has no built-in ingress support, so the `stoat-config`
chart creates a dedicated Ingress resource for `livekit.<domain>` in the
`stoat-livekit` namespace. cert-manager provisions a separate `livekit-tls`
certificate automatically.

## Client web image — custom Dockerfile

The upstream PR
([stoatchat/for-web#522](https://github.com/stoatchat/for-web/pull/522))
bakes environment variables at build time, which doesn't work when the API
URL isn't known until deployment. A custom Dockerfile in `docker/client/`
builds with placeholder env vars and replaces them at container startup via
`sed`, decoupling the build from deployment configuration.

See the [README — Client Image](../README.md#client-image) section for
build instructions.

## Infrastructure reuse from lasuite-platform

| Element | Reuse level |
|---------|-------------|
| `helmfile.yaml.gotmpl` structure | Adapted (different releases) |
| `environments/` layering | Adapted (Stoat URLs, no Keycloak) |
| `versions/` two-file pattern | Same pattern, different versions |
| Secret derivation (`sha256(seed:id)`) | Same pattern, different IDs |
| cert-manager chart + values | Near-identical |
| HAProxy Ingress chart + values | Near-identical |
| Reflector chart | Identical |
| Redis chart + values | Near-identical |
| MinIO chart + values | Near-identical |
| LiveKit chart + values | Near-identical (official upstream image) |
| `init.sh` | Adapted (no Keycloak, no People superuser, added VAPID/file key) |
| Per-app Helm charts | Replaced by generic `stoat-app` |
| Platform configuration chart | Adapted → `stoat-config` (Revolt.toml instead of env vars) |
