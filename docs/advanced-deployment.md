# Advanced Deployment

This guide explains how to deploy Stoatchat with existing infrastructure (MongoDB, Redis, RabbitMQ, S3).

## Table of Contents

- [Ingress Controller](#ingress-controller)
- [How Secrets Work](#how-secrets-work)
- [Using Custom Secrets](#using-custom-secrets)
- [Using an Existing MongoDB](#using-an-existing-mongodb)
- [Using an Existing Redis](#using-an-existing-redis)
- [Using an Existing RabbitMQ](#using-an-existing-rabbitmq)
- [Using an Existing S3](#using-an-existing-s3)
- [Using an Existing LiveKit](#using-an-existing-livekit)
- [Webhooks](#webhooks)
- [Production Deployment](#production-deployment)
- [Troubleshooting](#troubleshooting)

---

## Ingress Controller

**Only HAProxy is supported as an ingress controller.** All Ingress resources use `haproxy.org/*` annotations. Disabling the bundled HAProxy deployment is supported (`ingress.enabled: false`), but the annotations on all Ingress manifests remain HAProxy-specific.

If you want to use a different ingress controller (nginx, Traefik, etc.), fork the repository and replace all HAProxy annotations with your controller's equivalents. No support will be provided for any controller other than HAProxy.

---

## How Secrets Work

All secrets (DB passwords, S3 keys, LiveKit credentials...) are **automatically derived** from a single `secretSeed`. The formula is:

```
secret = sha256(secretSeed + ":" + identifier)[:50]
```

This means that using the same `secretSeed` will always produce the same secrets. This is useful for:
- Regenerating secrets without storing them
- Having consistent secrets between helmfile and your external infrastructure

To compute a specific secret:

```bash
SEED=$(grep secretSeed environments/<env>.yaml | cut -d'"' -f2)
echo -n "${SEED}:mongo-user" | shasum -a 256 | cut -c1-50
```

Identifiers used:

| Identifier | Usage | Length |
|------------|-------|--------|
| `mongo-root` | MongoDB root password | 50 |
| `mongo-user` | MongoDB application user password | 50 |
| `redis` | Redis password | 50 |
| `rabbit-user` | RabbitMQ password | 50 |
| `s3-access` | S3/MinIO access key | 50 |
| `s3-secret` | S3/MinIO secret key | 50 |
| `livekit-key` | LiveKit API key | 12 |
| `livekit-secret` | LiveKit API secret | 50 |

---

## Using Custom Secrets

If you have existing credentials that you cannot change (e.g., existing database passwords, S3 keys from your cloud provider), you can override individual secrets.

### Method 1: Secret Overrides File

Create a file `environments/my-env.secret-overrides.yaml`:

```yaml
secretOverrides:
  mongo-user: "my_existing_mongo_password"
  redis: "my_redis_password"
  s3-access: "AKIAIOSFODNN7EXAMPLE"
  s3-secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
```

Then add this file to your environment in `helmfile.yaml.gotmpl`:

```yaml
environments:
  my-env:
    values:
      - environments/_defaults.yaml
      - versions/infra-versions.yaml
      - versions/stoatchat-versions.yaml
      - environments/my-env.yaml
      - environments/my-env.secret-overrides.yaml  # Add this
      - environments/vapid.secret.yaml
      - environments/files.secret.yaml
```

### Method 2: Inline in environment file

You can also add overrides directly in your environment file:

```yaml
secretSeed: "your_seed_here"

secretOverrides:
  mongo-user: "my_custom_password"
  s3-access: "AKIA..."
  s3-secret: "..."
```

### How It Works

The `getSecret` helper checks for overrides:

1. If `secretOverrides.<identifier>` exists, use that value as-is
2. Otherwise, derive from `secretSeed` using SHA256

This means you can mix derived and custom secrets:
- Use derived secrets for in-cluster components
- Use custom secrets for external services

### K8s Secret Resources

The `stoatchat-config` chart also creates standalone K8s `Secret` resources
(`mongodb-credentials`, `redis-credentials`, `rabbitmq-credentials`,
`s3-credentials`, `livekit-credentials`) that are replicated via Reflector
to the relevant namespaces. These respect `secretOverrides` and can be
consumed by external tools (backup scripts, monitoring, operators).

---

## Using an Existing MongoDB

### 1. Create the database and user

```js
use revolt
db.createUser({
  user: "stoatchat",
  pwd: "your_mongo_password",
  roles: [{ role: "readWrite", db: "revolt" }]
})
```

### 2. Configure the environment

```yaml
# environments/my-env.yaml

mongodb:
  enabled: false  # Do not deploy MongoDB
  host: mongo.example.com
  port: 27017
```

### 3. Set the password

In `environments/my-env.secret-overrides.yaml`:

```yaml
secretOverrides:
  mongo-user: "your_mongo_password"
```

---

## Using an Existing Redis

### 1. Configure the environment

```yaml
# environments/my-env.yaml

redis:
  enabled: false  # Do not deploy Redis
  host: redis.example.com
  port: 6379
```

### 2. Set the password

In `environments/my-env.secret-overrides.yaml`:

```yaml
secretOverrides:
  redis: "your_redis_password"
```

> **Note**: LiveKit also uses Redis. If you use an external Redis, the same
> password is used for both Stoatchat services and LiveKit.

---

## Using an Existing RabbitMQ

### 1. Create the user and vhost

```bash
rabbitmqctl add_user stoatchat your_rabbit_password
rabbitmqctl set_permissions -p / stoatchat ".*" ".*" ".*"
```

### 2. Configure the environment

```yaml
# environments/my-env.yaml

rabbitmq:
  enabled: false  # Do not deploy RabbitMQ
  host: rabbitmq.example.com
  port: 5672
```

### 3. Set the password

In `environments/my-env.secret-overrides.yaml`:

```yaml
secretOverrides:
  rabbit-user: "your_rabbit_password"
```

---

## Using an Existing S3

For production, use a real S3 storage (AWS, OOS/Outscale, Scaleway, OVH, external MinIO).

### 1. Create bucket and credentials

On your S3 provider:
1. Create an IAM user or access key
2. Create the bucket: `revolt-uploads`
3. Grant the user read/write permissions on that bucket

### 2. Configure the environment

**For AWS S3:**

```yaml
# environments/my-env.yaml

minio:
  enabled: false  # Do not deploy MinIO

s3:
  provider: aws
  region: eu-west-1
  endpoint: https://s3.eu-west-1.amazonaws.com
  host: s3.eu-west-1.amazonaws.com
  port: 443
```

**For OOS (Outscale Object Storage):**

```yaml
s3:
  provider: oos
  endpoint: https://oos.eu-west-2.outscale.com
  host: oos.eu-west-2.outscale.com
  port: 443
```

Setting `provider: oos` adds `AWS_REQUEST_CHECKSUM_CALCULATION=WHEN_REQUIRED`
and `AWS_RESPONSE_CHECKSUM_VALIDATION=WHEN_REQUIRED` to S3-consuming services
(file-server, crond). This is required for newer AWS SDK versions that use
checksum algorithms not yet supported by OOS.

### S3 Provider Support

| Provider | Value | Region | Notes |
|----------|-------|--------|-------|
| MinIO | `minio` | Auto-set to `"minio"` | Local development only |
| AWS S3 | `aws` | Set `s3.region` (e.g. `eu-west-1`) | Production |
| OOS (Outscale) | `oos` | Default `us-east-1` | Adds checksum compatibility env vars |

### 3. Set the credentials

In `environments/my-env.secret-overrides.yaml`:

```yaml
secretOverrides:
  s3-access: "AKIAIOSFODNN7EXAMPLE"
  s3-secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
```

---

## Using an Existing LiveKit

If you already have a LiveKit server (self-hosted or LiveKit Cloud):

### 1. Configure the environment

```yaml
# environments/my-env.yaml

livekit:
  enabled: false  # Do not deploy LiveKit
```

The LiveKit internal URL in `Revolt.toml` defaults to the in-cluster service.
For an external LiveKit, you will need to override the `[api.livekit.nodes.worldwide]`
section. Currently this requires modifying `values/stoatchat-config.yaml.gotmpl`
to pass through the external LiveKit URL.

### 2. Set the credentials

In `environments/my-env.secret-overrides.yaml`:

```yaml
secretOverrides:
  livekit-key: "your_api_key"
  livekit-secret: "your_api_secret"
```

---

## Webhooks

Webhooks are enabled by default. Upstream Stoatchat defaults to `false` — there may be a reason for that we're not aware of. If you experience issues, disable them in your environment file:

```yaml
apps:
  api:
    webhooks: false
```

A commented-out line is already present in `remote.yaml.example` for quick toggling.

If you know why upstream defaults to disabled, please open an issue or a PR to change the default behaviour.

---

## Production Deployment

### 1. Run the init script

```bash
./init.sh
# Choose option 2 (Remote deployment)
# Enter: environment name, domain, admin email
```

This creates:
- `environments/<name>.yaml` — environment configuration (includes secretSeed)
- `environments/vapid.secret.yaml` — VAPID keys for push notifications
- `environments/files.secret.yaml` — file encryption key

### 2. Review the configuration

Edit `environments/<name>.yaml` to adjust:

```yaml
# Infrastructure - set to false if using external services
mongodb:
  enabled: true   # false if external MongoDB
  host: stoatchat-mongodb.stoatchat-mongodb.svc.cluster.local

redis:
  enabled: true   # false if external Redis

rabbitmq:
  enabled: true   # false if external RabbitMQ

minio:
  enabled: false  # Use real S3 in production

livekit:
  enabled: false  # true if you want in-cluster LiveKit

certManager:
  enabled: true   # false if already installed in your cluster

ingress:
  className: haproxy  # only supported controller — see Ingress Controller section

smtp:
  host: smtp.example.com  # Required for email verification
  port: 587
  username: noreply@example.com
  password: your_smtp_password
  fromAddress: noreply@example.com
  useTls: true
```

### 3. Add environment to helmfile

Add the environment block shown by `init.sh` to `helmfile.yaml.gotmpl`.

### 4. Configure DNS

Point your domain to your ingress controller IP.
Let's Encrypt requires valid DNS for certificate issuance.

### 5. Deploy

```bash
helmfile -e <name> sync
```

---

## Troubleshooting

### Pods stuck in CrashLoopBackOff

Check if the service can reach its dependencies:

```bash
# Test MongoDB connectivity
kubectl run test --rm -it --image=mongo:latest -- \
  mongosh "mongodb://stoatchat:<password>@<host>:27017/revolt"

# Test Redis connectivity
kubectl run test --rm -it --image=redis:alpine -- \
  redis-cli -h <host> -p 6379 -a <password> ping

# Test RabbitMQ connectivity
kubectl run test --rm -it --image=curlimages/curl -- \
  curl -u stoatchat:<password> http://<host>:15672/api/overview
```

### Retrieve a derived secret

```bash
SEED=$(grep secretSeed environments/<env>.yaml | cut -d'"' -f2)
echo -n "${SEED}:<identifier>" | shasum -a 256 | cut -c1-50
```

### Client shows blank page after rebuild

See [Known limitations — Client PWA service worker](known-limitations.md#client-pwa-service-worker).

### SMTP disabled = no email verification

See [Known limitations](known-limitations.md#smtp-disabled--no-email-verification).
