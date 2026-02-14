# Known Limitations

Current gotchas and limitations of the stoatchat-platform deployment.

## Client PWA service worker

The for-web client ships a service worker that precaches ~380 JS assets.
After rebuilding the client image, **hard refresh alone is not enough**.
Users must either:

- Unregister the service worker: DevTools → Application → Service Workers
  → Unregister
- Use private/incognito browsing
- Clear site data: DevTools → Application → Storage → Clear site data

This affects every client image rebuild, not just version bumps.

## Revolt API versioning

Auth routes (`/auth/*`) have no version prefix, but API routes use `/0.8/*`.
The client SDK handles this transparently. If you're making direct API calls,
be aware of the inconsistency.

## SMTP disabled = no email verification

When `smtp.host` is empty in the environment file, the `[api.smtp]` section is
omitted from `Revolt.toml` entirely. The API then skips email verification
and accounts are immediately usable after creation.

This is convenient for development but means anyone with network access to
the instance can create accounts without verification.

## Bitnami image removal from Docker Hub

Bitnami regularly removes specific image tags from Docker Hub with no
advance notice:

- **RabbitMQ:** all `bitnami/rabbitmq` tags removed. I switched to the
  official `rabbitmq:4-management` image deployed via the generic stoatchat-app
  chart.
- **MongoDB:** specific tags (`-debian-XX-rN` variants) removed. Only
  `latest` works reliably. The chart forces `image.tag: latest`.

Avoid adding new bitnami dependencies. Existing ones (MongoDB, Redis) should
be monitored and ideally migrated long-term.

## ConfigMap propagation requires pod restart

Changes to `Revolt.toml` (via Helmfile values) update the ConfigMap, but
running pods don't pick up the new configuration automatically. After any
configuration change:

```bash
# Re-deploy to update the ConfigMap
helmfile -e local sync

# Restart app pods to pick up the new Revolt.toml
kubectl rollout restart deployment -n stoatchat
```

## LiveKit host network

LiveKit requires host-network access for WebRTC media transport. The
following ports must be open on the node firewall:

| Port | Protocol | Purpose |
|------|----------|---------|
| 7881 | TCP | LiveKit signaling |
| 50000–60000 | UDP | WebRTC media (configurable via `livekit.rtcPortRangeStart` / `rtcPortRangeEnd`) |

In cloud environments, ensure security groups allow this traffic. On k3s
with a single node, this typically works out of the box.

## No admin panel

The `stoatchat/service-admin-panel` project exists but is not included in
this deployment. It requires Authentik for authentication and has private
submodule dependencies, making it impractical for self-hosting.

Administrative tasks (user management, instance configuration) must be done
directly via the API or MongoDB.

## Web client (`for-web`) upstream issues

These are upstream limitations in the `for-web` codebase, not deployment issues.

### Video/screen sharing (experimental)

Video and screen sharing are disabled in the upstream `for-web` client
(hardcoded `isDisabled` in `VoiceCallCardActions.tsx`). The default
`build.conf` uses a non-mainline patch (`Dadadah/stoat-for-web`,
branch `patch/enablevideo`) that re-enables these buttons. This is
experimental and may break with upstream updates (if it works at all)

### GIF picker cannot be disabled

The GIF picker calls the official Stoatchat gifbox instance (`api.gifbox.me`)
— not any self-hosted proxy. Deploying `gifbox` locally is useless: the client
ignores it entirely.

A `gif_picker` experiment is defined in `Experiments.ts` but is **never
checked** before rendering the picker. The GIF button is always visible
regardless of the experiment's state. There is no client-side setting to hide
it or point it at a custom gifbox URL.

`apps.gifbox.enabled` is set to `false` by default for this reason.

### Image pull policy

The client image uses tag `dev` (mutable) and `imagePullPolicy: Always` to
ensure the latest build is always pulled. Other Stoatchat services use immutable
GHCR tags with `IfNotPresent`.

If you switch the client to an immutable tag, you can change the pull policy
to `IfNotPresent` to avoid unnecessary pulls.

## Voice upstream status

The `voice-ingress` daemon (LiveKit webhook → MongoDB/RabbitMQ bridge) is
included in this deployment but missing from the official
[stoatchat/self-hosted](https://github.com/stoatchat/self-hosted) Docker
Compose setup. Voice functionality may be incomplete or broken upstream.

`voice-ingress` is disabled by default (`apps.voiceIngress.enabled: false`).
See [Compose differences](compose-deployment.md#voice) for compose-specific
behavior.
