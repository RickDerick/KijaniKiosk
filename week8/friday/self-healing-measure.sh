#!/usr/bin/env bash
# Measures Kubernetes self-healing for kk-payments:
# T0 = one Pod deleted, T1 = two Pods Ready again (excluding the deleted one).
set -uo pipefail
OUT="${1:-self-healing-rerun.txt}"
ts() { date '+%H:%M:%S.%3N'; }

{
  echo "# Self-healing measurement ($(date '+%Y-%m-%d %H:%M:%S'))"
  echo "Image: $(kubectl get deploy kk-payments -o jsonpath='{.spec.template.spec.containers[0].image}')"
  echo "Thursday's Pods were kk-payments-5bd47c6b86-55w49 and kk-payments-5bd47c6b86-drrfx"
  echo
  echo "## Pods before"
  kubectl get pods -l app=kk-payments -o wide
  echo
  echo "## kubectl get pods -l app=kk-payments -w  (each line prefixed with local time)"
} > "$OUT"

# Background watch, every event timestamped
( kubectl get pods -l app=kk-payments -w --no-headers 2>&1 \
    | while IFS= read -r line; do echo "$(ts)  $line"; done ) >> "$OUT" &
sleep 2

VICTIM=$(kubectl get pods -l app=kk-payments -o jsonpath='{.items[0].metadata.name}')
T0=$(date +%s.%N)
echo "$(ts)  >>> T0: deleting pod/$VICTIM" >> "$OUT"
kubectl delete pod "$VICTIM" --wait=false >/dev/null

# Wait until 2 Pods are Ready that are NOT being deleted
while :; do
  READY=$(kubectl get pods -l app=kk-payments \
    -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{"|"}{.status.containerStatuses[0].ready}{"\n"}{end}' \
    | grep -c '^|true$')
  [ "$READY" -ge 2 ] && break
  sleep 0.2
done
T1=$(date +%s.%N)
echo "$(ts)  >>> T1: 2/2 Pods Ready again" >> "$OUT"

sleep 5
pkill -f "kubectl get pods -l app=kk-payments -w" 2>/dev/null

{
  echo
  echo "## Pods after"
  kubectl get pods -l app=kk-payments -o wide
  echo
  echo "## Result"
  echo "Deleted Pod:   $VICTIM"
  echo "T0 (epoch s):  $T0"
  echo "T1 (epoch s):  $T1"
  echo "Recovery time: $(awk "BEGIN{printf \"%.1f\", $T1 - $T0}") seconds (deletion to 2/2 Ready)"
} >> "$OUT"

cat "$OUT"
