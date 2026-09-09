#!/usr/bin/env bash
#
# cluster-shutdown.sh — bring the whole RKE2 cluster down cleanly.
#
# Order matters: workloads stop -> Longhorn volumes detach -> agents stop ->
# servers stop -> VMs power off -> hosts power off. Skipping the detach step
# is what causes every volume to do a full rebuild on the way back up.
#
# Run from your workstation, NOT from a cluster node.
#
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/homelab.yaml}"
export KUBECONFIG

# Namespaces whose workloads hold Longhorn volumes. Add yours here.
APP_NAMESPACES=(signoz default)

# Where replica counts are recorded so startup can restore them.
STATE_FILE="${STATE_FILE:-$HOME/.kube/homelab-shutdown-state.json}"

SERVERS=(192.168.29.201 192.168.29.202 192.168.29.203)
AGENTS=(192.168.29.211 192.168.29.212)
PVE_HOSTS=(192.168.29.11 192.168.29.12 192.168.29.18)

SSH_USER="${SSH_USER:-ubuntu}"
PVE_SSH_USER="${PVE_SSH_USER:-root}"
SSH="ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

log() { printf '\n=== %s\n' "$*"; }

###############################################################################
log "Preflight"
###############################################################################
kubectl cluster-info >/dev/null || { echo "cannot reach cluster; aborting"; exit 1; }
kubectl get nodes

###############################################################################
log "Taking an etcd snapshot"
###############################################################################
# Cheap insurance. If the cluster comes back wrong, this is your way out.
$SSH "${SSH_USER}@${SERVERS[0]}" \
  "sudo rke2 etcd-snapshot save --name pre-shutdown-$(date +%Y%m%d-%H%M%S)"

###############################################################################
log "Suspending ArgoCD auto-sync"
###############################################################################
# Otherwise ArgoCD faithfully scales everything back up while you are trying
# to scale it down.
if kubectl get ns argocd >/dev/null 2>&1; then
  for app in $(kubectl -n argocd get applications -o name); do
    kubectl -n argocd patch "$app" --type=merge \
      -p '{"spec":{"syncPolicy":{"automated":null}}}' || true
  done
fi

###############################################################################
log "Recording replica counts and scaling workloads to zero"
###############################################################################
: > "$STATE_FILE.tmp"
for ns in "${APP_NAMESPACES[@]}"; do
  kubectl get ns "$ns" >/dev/null 2>&1 || continue
  kubectl -n "$ns" get deploy,statefulset \
    -o jsonpath='{range .items[*]}{.kind}{"|"}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.spec.replicas}{"\n"}{end}' \
    >> "$STATE_FILE.tmp"
done
mv "$STATE_FILE.tmp" "$STATE_FILE"
echo "saved to $STATE_FILE"

while IFS='|' read -r kind ns name replicas; do
  [ -z "${kind:-}" ] && continue
  echo "scaling ${kind,,}/$name in $ns (was $replicas)"
  kubectl -n "$ns" scale "${kind,,}/$name" --replicas=0
done < "$STATE_FILE"

###############################################################################
log "Waiting for Longhorn volumes to detach"
###############################################################################
# This is the step that matters. A volume still attached when its node powers
# off comes back needing a full rebuild across the network.
if kubectl get ns longhorn-system >/dev/null 2>&1; then
  for i in $(seq 1 60); do
    attached=$(kubectl -n longhorn-system get volumes.longhorn.io \
      -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.state}{"\n"}{end}' \
      2>/dev/null | grep -v '=detached$' || true)
    if [ -z "$attached" ]; then
      echo "all volumes detached"
      break
    fi
    echo "still attached ($i/60):"; echo "$attached"
    sleep 10
  done
  if [ -n "${attached:-}" ]; then
    echo
    echo "WARNING: volumes still attached after 10 minutes."
    echo "Something is still using them. Investigate before continuing —"
    echo "powering off now means rebuilds on restart."
    read -rp "Continue anyway? [y/N] " ans
    [ "$ans" = "y" ] || exit 1
  fi
fi

###############################################################################
log "Stopping agents, then servers"
###############################################################################
# Agents first: servers should outlive the nodes that report to them.
for ip in "${AGENTS[@]}"; do
  echo "stopping rke2-agent on $ip"
  $SSH "${SSH_USER}@${ip}" "sudo systemctl stop rke2-agent" || true
done

# Servers last. Do NOT use rke2-killall.sh here — that is for uninstall and
# troubleshooting, and it tears down containerd state you want preserved.
for ip in "${SERVERS[@]}"; do
  echo "stopping rke2-server on $ip"
  $SSH "${SSH_USER}@${ip}" "sudo systemctl stop rke2-server" || true
done

###############################################################################
log "Shutting down VMs"
###############################################################################
# ACPI shutdown via the guest agent. Proxmox honours the per-VM 'down' delay
# and startup order configured in Terraform.
for host in "${PVE_HOSTS[@]}"; do
  echo "shutting down guests on $host"
  $SSH "${PVE_SSH_USER}@${host}" \
    "for id in \$(qm list | awk 'NR>1 && \$3==\"running\" {print \$1}'); do qm shutdown \$id --timeout 120 & done; wait" || true
done

echo
echo "VMs are shutting down. Verify with 'qm list' on each host before"
echo "powering off the hosts themselves:"
for host in "${PVE_HOSTS[@]}"; do
  echo "  ssh ${PVE_SSH_USER}@${host} 'shutdown -h now'"
done
echo
echo "Restore with cluster-startup.sh (state: $STATE_FILE)"
