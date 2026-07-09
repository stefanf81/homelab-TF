#!/bin/zsh
set -eo pipefail

LOG_FILE="/Users/stefanfaes/homelab/TF/diagnostics.log"
KUBECONFIG_PATH="/Users/stefanfaes/homelab/TF/kubeconfig.yaml"

echo "=== STARTING CLUSTER DIAGNOSTICS ===" > "$LOG_FILE"
echo "Date: $(date)" >> "$LOG_FILE"
echo "Kubeconfig: $KUBECONFIG_PATH" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

if [ ! -f "$KUBECONFIG_PATH" ]; then
  echo "ERROR: Kubeconfig file not found at $KUBECONFIG_PATH" >> "$LOG_FILE"
  exit 1
fi

export KUBECONFIG="$KUBECONFIG_PATH"

echo "=== 1. NODE STATUS ===" >> "$LOG_FILE"
kubectl get nodes -o wide >> "$LOG_FILE" 2>&1 || true
echo "" >> "$LOG_FILE"

echo "=== 2. NODE DESCRIPTION ===" >> "$LOG_FILE"
kubectl describe nodes >> "$LOG_FILE" 2>&1 || true
echo "" >> "$LOG_FILE"

echo "=== 3. ALL PODS STATUS ===" >> "$LOG_FILE"
kubectl get pods -A -o wide >> "$LOG_FILE" 2>&1 || true
echo "" >> "$LOG_FILE"

echo "=== 4. CRITICAL SYSTEM EVENTS ===" >> "$LOG_FILE"
kubectl get events -A --sort-by='.metadata.creationTimestamp' | tail -n 100 >> "$LOG_FILE" 2>&1 || true
echo "" >> "$LOG_FILE"

echo "=== 5. NON-READY PODS DETAILS ===" >> "$LOG_FILE"
NON_READY_PODS=$(kubectl get pods -A --no-headers | grep -v -E "Running|Completed" || true)
if [ -n "$NON_READY_PODS" ]; then
  echo "$NON_READY_PODS" >> "$LOG_FILE"
  echo "" >> "$LOG_FILE"
  echo "--- Descriptions and Logs of non-Ready pods ---" >> "$LOG_FILE"
  echo "$NON_READY_PODS" | while read -r line; do
    ns=$(echo "$line" | awk '{print $1}')
    pod=$(echo "$line" | awk '{print $2}')
    echo "--- POD: $ns/$pod ---" >> "$LOG_FILE"
    kubectl describe pod -n "$ns" "$pod" >> "$LOG_FILE" 2>&1 || true
    echo "Logs:" >> "$LOG_FILE"
    kubectl logs -n "$ns" "$pod" --tail=100 >> "$LOG_FILE" 2>&1 || true
    echo "" >> "$LOG_FILE"
  done
else
  echo "All pods are Running or Completed!" >> "$LOG_FILE"
fi
echo "" >> "$LOG_FILE"

echo "=== DIAGNOSTICS COMPLETE. LOG WRITTEN TO $LOG_FILE ==="
