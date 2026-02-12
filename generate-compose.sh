#!/usr/bin/env bash
# generate-compose.sh — Generate compose.yml + Caddyfile from helmfile templates
#
# First run:  interactive setup (domain, voice, data root, secrets)
# Next runs:  re-renders helmfile templates + regenerates compose
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Reuse helpers from init.sh (generate_seed, generate_vapid, generate_files_key, derive_secret, read_seed)
source "$SCRIPT_DIR/init.sh"

H2C_VERSION="v1.1.0"
H2C_URL="https://raw.githubusercontent.com/baptisterajaut/helmfile2compose/${H2C_VERSION}/helmfile2compose.py"
H2C_SCRIPT="$(mktemp /tmp/helmfile2compose.XXXXXX.py)"
RENDERED_DIR="generated-platform"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

echo "Checking prerequisites..."
missing=()
for cmd in helmfile helm python3 openssl; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
done
python3 -c "import yaml" 2>/dev/null || missing+=("pyyaml (pip install pyyaml)")

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: missing prerequisites: ${missing[*]}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Download helmfile2compose.py
# ---------------------------------------------------------------------------

echo "Downloading helmfile2compose.py (${H2C_VERSION})..."
curl -fsSL "$H2C_URL" -o "$H2C_SCRIPT"
trap 'rm -f "$H2C_SCRIPT"' EXIT

# ---------------------------------------------------------------------------
# Setup: environments/compose.yaml (domain, voice, secrets)
# ---------------------------------------------------------------------------

if [[ ! -f environments/compose.yaml ]]; then
    echo ""
    echo "=== Stoat Compose Setup ==="
    echo ""

    # -- Domain --
    read -rp "Domain [stoatchat.local]: " DOMAIN
    DOMAIN="${DOMAIN:-stoatchat.local}"

    # -- Voice --
    read -rp "Enable voice/video calls (LiveKit)? [y/N]: " VOICE
    VOICE="${VOICE:-n}"
    VOICE="${VOICE,,}"

    # -- Create environments/compose.yaml from example --
    echo "Creating environments/compose.yaml..."
    SEED="$(generate_seed)"
    VOICE_ENABLED=$( [[ "$VOICE" == "y" ]] && echo "true" || echo "false" )
    sed -e "s|__DOMAIN__|${DOMAIN}|g" \
        -e "s|__SECRET_SEED__|${SEED}|" \
        -e "s|__VOICE_ENABLED__|${VOICE_ENABLED}|g" \
        environments/compose.yaml.example > environments/compose.yaml

    echo "  domain:     ${DOMAIN}"
    echo "  secretSeed: ${SEED:0:8}..."
    echo "  voice:      ${VOICE_ENABLED}"

    # -- Non-derivable secrets --
    generate_vapid
    generate_files_key

    echo ""
fi

# ---------------------------------------------------------------------------
# Setup: helmfile2compose.yaml (data root, caddy email)
# ---------------------------------------------------------------------------

if [[ ! -f helmfile2compose.yaml ]]; then
    # -- Data root --
    DEFAULT_DATA="${HOME}/stoat-data"
    read -rp "Data directory [${DEFAULT_DATA}]: " DATA_ROOT
    DATA_ROOT="${DATA_ROOT:-${DEFAULT_DATA}}"

    # -- Email for Let's Encrypt (real domains only) --
    # Caddy uses its internal CA for .local and localhost — no ACME, no email needed
    DOMAIN=$(grep '^domain:' environments/compose.yaml | awk '{print $2}')
    CADDY_EMAIL=""
    if [[ "$DOMAIN" != *.local && "$DOMAIN" != localhost ]]; then
        read -rp "Email for Let's Encrypt certificates: " CADDY_EMAIL
    fi

    # -- Generate from template --
    sed "s|__VOLUME_ROOT__|${DATA_ROOT}|" helmfile2compose.yaml.template > helmfile2compose.yaml
    if [[ -n "$CADDY_EMAIL" ]]; then
        echo "caddy_email: \"${CADDY_EMAIL}\"" >> helmfile2compose.yaml
    fi

    # -- Data directories --
    mkdir -p "${DATA_ROOT}"/{mongodb,redis,rabbitmq,minio}

    echo ""
fi

# ---------------------------------------------------------------------------
# Render helmfile templates
# ---------------------------------------------------------------------------

echo "Rendering helmfile templates..."
rm -rf "$RENDERED_DIR"
helmfile -e compose template --output-dir "$RENDERED_DIR"

# ---------------------------------------------------------------------------
# Generate compose.yml + Caddyfile
# ---------------------------------------------------------------------------

echo "Generating compose.yml..."
rm -rf configmaps/ secrets/
python3 "$H2C_SCRIPT" --from-dir "$RENDERED_DIR" --output-dir .

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

SEED=$(read_seed environments/compose.yaml)
DOMAIN=$(grep '^domain:' environments/compose.yaml | awk '{print $2}')

echo ""
echo "=== Done ==="
echo ""
echo "Make sure DNS resolves to the host running compose:"
echo "  ${DOMAIN}  livekit.${DOMAIN}"
echo "  (for local testing: 127.0.0.1 in /etc/hosts)"
echo ""
echo "Credentials (derived from secretSeed):"
echo "  MongoDB:  stoatchat / $(derive_secret "$SEED" "mongo-user")"
echo "  RabbitMQ: stoatchat / $(derive_secret "$SEED" "rabbit-user")"
echo "  MinIO:    $(derive_secret "$SEED" "s3-access") / $(derive_secret "$SEED" "s3-secret")"
echo ""
echo "Start:  docker compose up -d"
echo "Regen:  ./generate-compose.sh"
