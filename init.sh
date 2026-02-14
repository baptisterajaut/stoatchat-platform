#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "Error: $1 is not installed"
        exit 1
    fi
}

generate_seed() {
    openssl rand -hex 24
}

read_seed() {
    local env_file="$1"
    grep secretSeed "${env_file}" | cut -d'"' -f2
}

generate_vapid() {
    if [[ -f "${SCRIPT_DIR}/environments/vapid.secret.yaml" ]]; then
        echo "environments/vapid.secret.yaml already exists, skipping."
        return
    fi

    local tmpfile
    tmpfile=$(mktemp)
    openssl ecparam -name prime256v1 -genkey -noout -out "${tmpfile}" 2>/dev/null

    local private public
    private=$(base64 < "${tmpfile}" | tr -d '\n' | tr -d '=')
    public=$(openssl ec -in "${tmpfile}" -pubout -outform DER 2>/dev/null | tail -c 65 | base64 | tr '/+' '_-' | tr -d '\n' | tr -d '=')
    rm -f "${tmpfile}"

    cat > "${SCRIPT_DIR}/environments/vapid.secret.yaml" <<EOF
vapid:
  privateKey: "${private}"
  publicKey: "${public}"
EOF
    echo "Generated environments/vapid.secret.yaml"
}

generate_files_key() {
    if [[ -f "${SCRIPT_DIR}/environments/files.secret.yaml" ]]; then
        echo "environments/files.secret.yaml already exists, skipping."
        return
    fi

    local key
    key=$(openssl rand -base64 32)

    cat > "${SCRIPT_DIR}/environments/files.secret.yaml" <<EOF
files:
  encryptionKey: "${key}"
EOF
    echo "Generated environments/files.secret.yaml"
}

derive_secret() {
    echo -n "${1}:${2}" | shasum -a 256 | cut -c1-${3:-50}
}

post_deploy() {
    local seed="$1"

    check_command kubectl

    if ! kubectl cluster-info &> /dev/null; then
        echo "Error: Cannot connect to Kubernetes cluster"
        exit 1
    fi

    echo ""
    echo "Waiting for LoadBalancer IP..."
    LB_IP=""
    for _ in {1..30}; do
        LB_IP=$(kubectl get svc haproxy-ingress-kubernetes-ingress -n haproxy-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
        if [[ -n "${LB_IP}" ]]; then
            break
        fi
        sleep 2
    done

    if [[ -z "${LB_IP}" ]]; then
        LB_IP="127.0.0.1"
        echo "Could not detect LoadBalancer IP, defaulting to ${LB_IP}"
    fi

    DOMAIN=$(grep '^domain:' "${SCRIPT_DIR}/environments/local.yaml" | awk '{print $2}')

    echo ""
    echo "Add to /etc/hosts:"
    echo "${LB_IP}  ${DOMAIN}"

    # Extract CA certificate for self-signed setups
    CA_FILE="${SCRIPT_DIR}/stoatchat-ca.pem"
    kubectl get secret stoatchat-ca-secret -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d > "${CA_FILE}" 2>/dev/null || true
    if [[ -s "${CA_FILE}" ]]; then
        echo ""
        echo "CA certificate saved to: ${CA_FILE}"
    fi

    # Compute derived credentials (same formula as Helm: sha256(seed:id)[:50])
    MONGO_ROOT_PASS=$(derive_secret "${seed}" "mongo-root")
    MONGO_USER_PASS=$(derive_secret "${seed}" "mongo-user")
    RABBIT_PASS=$(derive_secret "${seed}" "rabbit-user")
    S3_ACCESS=$(derive_secret "${seed}" "s3-access")
    S3_SECRET=$(derive_secret "${seed}" "s3-secret")

    echo ""
    echo "=== Credentials ==="
    echo ""
    echo "MongoDB:   stoatchat / ${MONGO_USER_PASS}"
    echo "           root password: ${MONGO_ROOT_PASS}"
    echo "RabbitMQ:  stoatchat / ${RABBIT_PASS}"
    echo "           http://${DOMAIN}:15672 (if port-forwarded)"
    echo "MinIO:     ${S3_ACCESS}"
    echo "           ${S3_SECRET}"
    echo "           http://${DOMAIN}:9001 (if port-forwarded)"
    echo ""
    echo "Done. Access: https://${DOMAIN}"
}

setup_local() {
    check_command helm
    check_command kubectl
    check_command helmfile
    check_command openssl

    if ! kubectl cluster-info &> /dev/null; then
        echo "Error: Cannot connect to Kubernetes cluster"
        exit 1
    fi

    ENV_FILE="${SCRIPT_DIR}/environments/local.yaml"
    TEMPLATE_FILE="${SCRIPT_DIR}/environments/local.yaml.example"

    if [[ -f "${ENV_FILE}" ]]; then
        echo "Using existing ${ENV_FILE}"
        SEED="$(read_seed "${ENV_FILE}")"
    else
        SEED="$(generate_seed)"
        sed "s/^secretSeed: \"\"/secretSeed: \"${SEED}\"/" \
            "${TEMPLATE_FILE}" > "${ENV_FILE}"
        echo "Created ${ENV_FILE} (seed: ${SEED})"
    fi

    generate_vapid
    generate_files_key

    echo ""
    echo "Review ${ENV_FILE} to configure your domain and enabled services."
    echo ""

    read -rp "Press Enter to run helmfile sync..."

    cd "${SCRIPT_DIR}"
    helmfile -e local sync

    post_deploy "${SEED}"
}

setup_remote() {
    check_command openssl

    echo ""
    read -rp "Environment name (e.g. staging, production): " ENV_NAME
    if [[ -z "${ENV_NAME}" ]]; then
        echo "Error: environment name is required"
        exit 1
    fi

    read -rp "Domain (e.g. chat.example.com): " DOMAIN
    if [[ -z "${DOMAIN}" ]]; then
        echo "Error: domain is required"
        exit 1
    fi

    read -rp "Admin email (for Let's Encrypt): " ADMIN_EMAIL
    if [[ -z "${ADMIN_EMAIL}" ]]; then
        echo "Error: admin email is required"
        exit 1
    fi

    ENV_FILE="${SCRIPT_DIR}/environments/${ENV_NAME}.yaml"
    TEMPLATE_FILE="${SCRIPT_DIR}/environments/remote.yaml.example"

    if [[ -f "${ENV_FILE}" ]]; then
        echo "Using existing ${ENV_FILE}"
        SEED="$(read_seed "${ENV_FILE}")"
    else
        SEED="$(generate_seed)"
        sed -e "s/__DOMAIN__/${DOMAIN}/g" \
            -e "s/__ADMIN_EMAIL__/${ADMIN_EMAIL}/g" \
            -e "s/^secretSeed: \"\"/secretSeed: \"${SEED}\"/" \
            "${TEMPLATE_FILE}" > "${ENV_FILE}"
        echo "Created ${ENV_FILE}"
    fi

    generate_vapid
    generate_files_key

    echo ""
    echo "=== Next steps ==="
    echo ""
    echo "1. Register the environment in helmfile.yaml.gotmpl:"
    echo ""
    echo "   ${ENV_NAME}:"
    echo "     values:"
    echo "       - environments/_defaults.yaml"
    echo "       - versions/infra-versions.yaml"
    echo "       - versions/stoatchat-versions.yaml"
    echo "       - environments/${ENV_NAME}.yaml"
    echo "       - environments/vapid.secret.yaml"
    echo "       - environments/files.secret.yaml"
    echo "       # Optional: uncomment if using secret overrides"
    echo "       # - environments/${ENV_NAME}.secret-overrides.yaml"
    echo ""
    echo "2. Edit environments/${ENV_NAME}.yaml:"
    echo "   - Configure infrastructure hosts (MongoDB, Redis, RabbitMQ, S3)"
    echo "   - Enable/disable in-cluster services as needed"
    echo "   - Configure SMTP for email verification"
    echo ""
    echo "3. If using external infrastructure, create secret overrides:"
    echo "   cp environments/secret-overrides.yaml.example environments/${ENV_NAME}.secret-overrides.yaml"
    echo "   # Edit with your external service credentials"
    echo ""
    echo "4. Set up DNS:"
    echo "   ${DOMAIN}  -> your ingress IP"
    echo ""
    echo "5. Deploy:"
    echo "   helmfile -e ${ENV_NAME} sync"
    echo ""
}

# ---------------------------------------------------------------------------
# Main — only runs when executed directly, not when sourced
# ---------------------------------------------------------------------------

[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 0

# --post-deploy: skip config generation and helmfile sync, run post-deploy only
if [[ "${1:-}" == "--post-deploy" ]]; then
    ENV_FILE="${SCRIPT_DIR}/environments/local.yaml"
    if [[ ! -f "${ENV_FILE}" ]]; then
        echo "Error: ${ENV_FILE} not found. Run ./init.sh first."
        exit 1
    fi
    SEED="$(read_seed "${ENV_FILE}")"
    if [[ -z "${SEED}" ]]; then
        echo "Error: secretSeed not set in ${ENV_FILE}"
        exit 1
    fi
    post_deploy "${SEED}"
    exit 0
fi

echo ""
echo "=== Stoatchat Platform - Setup ==="
echo ""
echo "Select deployment mode:"
echo ""
echo "  1) Local development  — single-node cluster, self-signed TLS"
echo "  2) Remote deployment  — scaffold environment for staging/production"
echo ""
read -rp "Choice [1]: " CHOICE
CHOICE="${CHOICE:-1}"

case "${CHOICE}" in
    1) setup_local ;;
    2) setup_remote ;;
    *)
        echo "Invalid choice: ${CHOICE}"
        exit 1
        ;;
esac
