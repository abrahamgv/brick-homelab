#!/usr/bin/env bash
#
# node-maintenance.sh <node-name> [drain|restore]
#
# Take ONE node out of service while the cluster keeps running — the case for
# a single mini PC needing a reboot or a RAM upgrade.
#
# This is a different operation from cluster-shutdown.sh. Here the cluster
# survives, so Longhorn needs to know the node is going away on purpose.
#
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/homelab.yaml}"
export KUBECONFIG

NODE="${1:?usage: node-maintenance.sh <node-name> [drain|restore]}"
ACTION="${2:-drain}"

case "$ACTION" in
drain)
  echo "=== Cordoning $NODE"
  kubectl cordon "$NODE"

  # Longhorn's default node-drain-policy is block-if-contains-last-replica,
  # so a drain will correctly hang rather than let you evict the only copy of
  # a volume. If it hangs, that is the safety net working — check:
  #   kubectl -n longhorn-system get replicas.longhorn.io -o wide | grep $NODE
  echo "=== Draining $NODE"
  kubectl drain "$NODE" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --timeout=600s

  echo
  echo "=== Longhorn replicas still on $NODE"
  kubectl -n longhorn-system get replicas.longhorn.io \
    -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeID,STATE:.status.currentState \
    | grep "$NODE" || echo "  none"

  echo
  echo "IMPORTANT: with 3 storage zones and no spare capacity, replicas on"
  echo "this node cannot be rebuilt elsewhere. Volumes will run Degraded until"
  echo "the node returns. That is expected — do not 'fix' it by deleting"
  echo "replicas. Keep the window short."
  echo
  echo "Safe to reboot the host now. Afterwards:"
  echo "  $0 $NODE restore"
  ;;

restore)
  echo "=== Waiting for $NODE to be Ready"
  kubectl wait --for=condition=Ready "node/$NODE" --timeout=600s

  echo "=== Uncordoning $NODE"
  kubectl uncordon "$NODE"

  echo "=== Waiting for Longhorn to mark the node schedulable"
  for i in $(seq 1 30); do
    state=$(kubectl -n longhorn-system get nodes.longhorn.io "$NODE" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    [ "$state" = "True" ] && { echo "ready"; break; }
    echo "waiting ($i/30)"; sleep 10
  done

  echo
  echo "Replica rebuild will now start. Rebuild concurrency is capped at 1"
  echo "per node, so this is deliberately slow. Watch progress:"
  echo "  kubectl -n longhorn-system get volumes.longhorn.io -w"
  ;;

*)
  echo "unknown action: $ACTION (expected drain or restore)"; exit 1
  ;;
esac
