#!/usr/bin/env bash
#
# cluster-startup.sh — bring the cluster back up after cluster-shutdown.sh.
#
# Power on the physical hosts by hand first. Everything else is here.
#
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/homelab.yaml}"
export KUBECONFIG

STATE_FILE="${STATE_FILE:-$HOME/.kube/homelab-shutdown-state.json}"
VIP=192.168.29.241

log() { printf '\n=== %s\n' "$*"; }

###############################################################################
log "Waiting for the API server on the VIP"
###############################################################################
# VMs start themselves via on_boot + the Terraform startup order (control
# planes first). This just waits for etcd quorum and the VIP to bind.
#
# RKE2 runs with anonymous-auth=false, so an unauthenticated /livez returns
# 401, not 200. That still proves the API server is listening and serving —
# a down cluster gives a connection refused or a timeout instead. Accept any
# HTTP status; the authenticated check comes next.
api_up=false
for i in $(seq 1 60); do
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
    "https://${VIP}:6443/livez" 2>/dev/null || echo 000)
  case "$code" in
    200|401|403)
      echo "API server responding (HTTP $code)"
      api_up=true
      break
      ;;
  esac
  echo "waiting for API ($i/60, last=$code)"
  sleep 10
done

if [ "$api_up" != true ]; then
  echo "API server never responded on ${VIP}:6443 — check that the VIP is"
  echo "bound (ip addr on a control plane) and that etcd has quorum."
  exit 1
fi

# Authenticated check: confirms the kubeconfig works, not just that something
# is listening on the port.
kubectl get --raw='/livez?verbose' >/dev/null || {
  echo "API reachable but kubeconfig rejected — check ~/.kube credentials."
  exit 1
}

kubectl get nodes

###############################################################################
log "Waiting for all nodes Ready"
###############################################################################
kubectl wait --for=condition=Ready nodes --all --timeout=600s

###############################################################################
log "Waiting for Longhorn"
###############################################################################
if kubectl get ns longhorn-system >/dev/null 2>&1; then
  kubectl -n longhorn-system rollout status daemonset/longhorn-manager --timeout=600s

  # Every storage node must be schedulable before workloads come back, or
  # Longhorn places replicas on whatever subset is ready and rebalances later.
  for i in $(seq 1 30); do
    notready=$(kubectl -n longhorn-system get nodes.longhorn.io \
      -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
      | grep -v '=True$' || true)
    [ -z "$notready" ] && { echo "all Longhorn nodes ready"; break; }
    echo "waiting for Longhorn nodes ($i/30):"; echo "$notready"
    sleep 10
  done
fi

###############################################################################
log "Restoring workload replica counts"
###############################################################################
if [ -f "$STATE_FILE" ]; then
  while IFS='|' read -r kind ns name replicas; do
    [ -z "${kind:-}" ] && continue
    echo "restoring ${kind,,}/$name in $ns to $replicas"
    kubectl -n "$ns" scale "${kind,,}/$name" --replicas="$replicas" || true
  done < "$STATE_FILE"
else
  echo "no state file at $STATE_FILE — restore replica counts by hand,"
  echo "or just re-enable ArgoCD sync below and let it reconcile."
fi

###############################################################################
log "Re-enabling ArgoCD auto-sync"
###############################################################################
if kubectl get ns argocd >/dev/null 2>&1; then
  for app in $(kubectl -n argocd get applications -o name); do
    kubectl -n argocd patch "$app" --type=merge \
      -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' || true
  done
fi

###############################################################################
log "Post-start checks"
###############################################################################
kubectl get nodes -o wide
kubectl get pods -A | grep -vE 'Running|Completed' || echo "all pods healthy"
echo
echo "Check for degraded volumes:"
echo "  kubectl -n longhorn-system get volumes.longhorn.io"
echo "Check etcd membership:"
echo "  kubectl -n kube-system get pods -l component=etcd"
