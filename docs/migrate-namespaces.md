# Migrate cluster-wide namespaces (14 February 2026)

cert-manager, Reflector and HAProxy were previously deployed in `stoatchat-*` namespaces. These are cluster-wide components and should not be tied to a project name. The new namespaces match lasuite-platform:

| Old namespace | New namespace |
|---------------|---------------|
| `stoatchat-cert-manager` | `cert-manager` |
| `stoatchat-ingress` | `haproxy-controller` |
| `stoatchat-reflector` | `reflector` |

## Impact

- **Kubernetes deployments** need to uninstall the old releases before running `helmfile sync` with the new namespaces. The script below handles this.
- **Compose deployments** are not affected (no Kubernetes namespaces involved).

## Migration script

Run this before pulling the new version and running `helmfile sync`:

```bash
#!/bin/bash
set -e

echo "=== Uninstalling old releases ==="

# Uninstall releases from old namespaces
helm uninstall cert-manager -n stoatchat-cert-manager 2>/dev/null && echo "Uninstalled cert-manager" || echo "cert-manager not found (skipping)"
helm uninstall haproxy-ingress -n stoatchat-ingress 2>/dev/null && echo "Uninstalled haproxy-ingress" || echo "haproxy-ingress not found (skipping)"
helm uninstall reflector -n stoatchat-reflector 2>/dev/null && echo "Uninstalled reflector" || echo "reflector not found (skipping)"

echo ""
echo "=== Cleaning up cert-manager CRDs ==="

# cert-manager CRDs are not removed by helm uninstall
kubectl delete crd \
  certificaterequests.cert-manager.io \
  certificates.cert-manager.io \
  challenges.acme.cert-manager.io \
  clusterissuers.cert-manager.io \
  issuers.cert-manager.io \
  orders.acme.cert-manager.io \
  2>/dev/null && echo "Deleted cert-manager CRDs" || echo "CRDs not found (skipping)"

echo ""
echo "=== Cleaning up ClusterRoles and ClusterRoleBindings ==="

# These are cluster-scoped and not cleaned up by namespace deletion
kubectl delete clusterrole,clusterrolebinding -l app.kubernetes.io/instance=cert-manager 2>/dev/null || true
kubectl delete clusterrole,clusterrolebinding -l app.kubernetes.io/instance=haproxy-ingress 2>/dev/null || true
kubectl delete clusterrole,clusterrolebinding -l app.kubernetes.io/instance=reflector 2>/dev/null || true
echo "Cleaned up cluster-scoped RBAC resources"

echo ""
echo "=== Deleting old namespaces ==="

kubectl delete namespace stoatchat-cert-manager 2>/dev/null && echo "Deleted stoatchat-cert-manager" || echo "Namespace not found (skipping)"
kubectl delete namespace stoatchat-ingress 2>/dev/null && echo "Deleted stoatchat-ingress" || echo "Namespace not found (skipping)"
kubectl delete namespace stoatchat-reflector 2>/dev/null && echo "Deleted stoatchat-reflector" || echo "Namespace not found (skipping)"

echo ""
echo "=== Done ==="
echo ""
echo "Now pull the latest version and run:"
echo "  helmfile -e <your-env> sync"
echo ""
echo "cert-manager, HAProxy and Reflector will be reinstalled in the new namespaces."
echo "TLS certificates will be re-issued automatically by cert-manager."
```

## Notes

- **Downtime**: there will be a brief period without an ingress controller or TLS issuer between uninstall and `helmfile sync`. Plan accordingly.
- **TLS certificates**: cert-manager will re-issue all certificates after reinstall. For Let's Encrypt, this counts against rate limits (50 certificates per registered domain per week). Self-signed setups are unaffected.
- **Reflector**: secrets replicated by the old Reflector instance remain in their target namespaces. The new instance picks them up.
