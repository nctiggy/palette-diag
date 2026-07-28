#!/usr/bin/env bash
# =============================================================================
# check-storage.sh — LINSTOR / Piraeus storage triage for a Palette Management
#                    Appliance whose PVCs will not provision.
#
#   export KUBECONFIG=/path/to/appliance.kubeconfig
#   curl -fsSL https://raw.githubusercontent.com/nctiggy/palette-diag/main/check-storage.sh | bash
#
# Prints a readable report to the terminal (paste it straight into a mail or a
# call) and also writes a .tgz next to it.
#
#   --pvc NS/NAME   focus on one claim (default: every non-Bound PVC)
#   --no-bundle     terminal output only
#
# Read-only. No secret values are collected.
# =============================================================================
set +e +u
umask 077

FOCUS=""; DO_BUNDLE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --pvc) FOCUS="$2"; shift 2;;
    --no-bundle) DO_BUNDLE=0; shift;;
    -h|--help) grep '^#' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0;;
    *) shift;;
  esac
done

command -v kubectl >/dev/null 2>&1 || { echo "FATAL: kubectl not on PATH"; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "FATAL: kubectl cannot reach the cluster (KUBECONFIG=${KUBECONFIG:-default})"; exit 1; }

TS="$(date -u +%Y%m%d-%H%M%SZ)"
D="$(mktemp -d)"; OUT="/tmp/pma-storage-$TS.tgz"
exec > >(tee "$D/report.txt") 2>&1

h(){ echo; echo "==================== $* ===================="; }
run(){ echo; echo "\$ $*"; "$@" 2>&1; }

echo "###### PALETTE APPLIANCE — STORAGE TRIAGE ($TS) ######"

# ---------------------------------------------------------------- topology
h "NODES"
run kubectl get nodes -o wide
NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo; echo ">>> node count = $NODES   (any placement count above this can never provision)"

# ---------------------------------------------------------------- storage classes
h "STORAGE CLASSES — full parameters"
run kubectl get sc -o custom-columns='NAME:.metadata.name,PROVISIONER:.provisioner,PLACE:.parameters.placementCount,POOL:.parameters.storagePool,RSCGRP:.parameters.resourceGroup,REMOTE:.parameters.allowRemoteVolumeAccess,BINDING:.volumeBindingMode'
for sc in $(kubectl get sc -o name 2>/dev/null | sed 's|storageclass.storage.k8s.io/||'); do
  run kubectl describe sc "$sc"
done

echo; echo ">>> CHECK: for each class, placementCount must be <= $NODES."
echo ">>> CHECK: the resourceGroup named here is what LINSTOR actually enforces."

# ---------------------------------------------------------------- claims
h "PERSISTENT VOLUME CLAIMS"
run kubectl get pvc -A -o wide
run kubectl get pv -o wide

if [ -n "$FOCUS" ]; then
  PNS="${FOCUS%%/*}"; PNAME="${FOCUS##*/}"
  run kubectl describe pvc "$PNAME" -n "$PNS"
else
  kubectl get pvc -A --no-headers 2>/dev/null | awk '$3!="Bound"{print $1" "$2}' | while read -r ns nm; do
    [ -z "$ns" ] && continue
    run kubectl describe pvc "$nm" -n "$ns"
  done
fi

h "PROVISIONING EVENTS"
run kubectl get events -A --field-selector reason=ProvisioningFailed --sort-by=.lastTimestamp
kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | grep -iE 'provision|volume|linstor|FailedScheduling' | tail -30

# ---------------------------------------------------------------- linstor
NS=$(kubectl get ns --no-headers -o custom-columns=N:.metadata.name 2>/dev/null | grep -iE 'piraeus|linstor' | head -1)
echo; echo ">>> piraeus namespace: ${NS:-<not found>}"

if [ -n "$NS" ]; then
  h "PIRAEUS / LINSTOR PODS"
  run kubectl get pods -n "$NS" -o wide

  LC=$(kubectl get pods -n "$NS" -o name 2>/dev/null | grep linstor-controller | head -1)
  echo; echo ">>> linstor controller pod: ${LC:-<not found>}"

  if [ -n "$LC" ]; then
    L(){ kubectl exec -n "$NS" "$LC" -- linstor "$@" 2>&1; }
    h "LINSTOR — NODES";           echo "\$ linstor node list";           L node list
    h "LINSTOR — STORAGE POOLS";   echo "\$ linstor storage-pool list";   L storage-pool list
    h "LINSTOR — RESOURCE GROUPS"; echo "\$ linstor resource-group list"; L resource-group list
    h "LINSTOR — RESOURCES";       echo "\$ linstor resource list";       L resource list
    h "LINSTOR — VOLUMES";         echo "\$ linstor volume list";         L volume list
    h "LINSTOR — ERROR REPORTS";   echo "\$ linstor error-reports list";  L error-reports list

    echo
    echo ">>> CHECK: every resource group's PlaceCount must be <= $NODES."
    echo ">>> CHECK: a StorageClass naming a resourceGroup that is ABSENT above means"
    echo ">>>        linstor-csi will create it on first use, using the class's"
    echo ">>>        placementCount. Fixing DfltRscGrp does NOT affect a named group."
    echo ">>> FIX  : linstor resource-group modify <NAME> --place-count 1 --storage-pool <POOL>"
  fi

  h "PIRAEUS OPERATOR CRs (declared storage pools live here)"
  run kubectl get linstorclusters,linstorsatellites,linstorsatelliteconfigurations -A
  for c in linstorsatelliteconfigurations linstorclusters; do
    kubectl get "$c" -A -o yaml 2>/dev/null | grep -iB3 -A15 'storagePools' | head -60
  done

  h "CSI / CONTROLLER LOGS"
  for c in csi-provisioner csi-attacher csi-resizer linstor-csi; do
    echo; echo "\$ logs deploy/linstor-csi-controller -c $c (tail 40)"
    kubectl logs -n "$NS" deploy/linstor-csi-controller -c "$c" --tail=40 2>&1 | tail -40
  done
  echo; echo "\$ logs linstor-controller (tail 60)"
  [ -n "$LC" ] && kubectl logs -n "$NS" "$LC" --tail=60 2>&1 | tail -60
fi

# ---------------------------------------------------------------- palette packs
CNS=$(kubectl get ns --no-headers -o custom-columns=N:.metadata.name 2>/dev/null | grep '^cluster-' | head -1)
echo; echo ">>> palette cluster namespace: ${CNS:-<not found>}"
if [ -n "$CNS" ]; then
  h "PALETTE PACKS — what is still Pending"
  run kubectl get packs.cluster.spectrocloud.com -n "$CNS"
  h "PACK DESIRED STATE (pvc / storage stanzas)"
  for p in $(kubectl get packs.cluster.spectrocloud.com -n "$CNS" -o name 2>/dev/null); do
    echo; echo "---- $p ----"
    kubectl get "$p" -n "$CNS" -o yaml 2>/dev/null \
      | grep -iE 'name:|persistentVolumeClaim|storageClass|storage:|accessMode|placementCount|resourceGroup|storagePool|size:' \
      | head -40
  done
  h "PACK CONDITIONS"
  kubectl get packs.cluster.spectrocloud.com -n "$CNS" -o json 2>/dev/null \
    | grep -iE '"(name|status|reason|message)"' | head -60
fi

# ---------------------------------------------------------------- workloads
h "PODS NOT RUNNING"
kubectl get pods -A --no-headers 2>/dev/null \
  | awk '{split($3,a,"/"); if(($4!="Running"&&$4!="Completed")||a[1]!=a[2]) print}'

h "SUMMARY"
echo "nodes                : $NODES"
echo "storage classes      : $(kubectl get sc --no-headers 2>/dev/null | wc -l | tr -d ' ')"
echo "PVCs not Bound       : $(kubectl get pvc -A --no-headers 2>/dev/null | awk '$3!="Bound"' | wc -l | tr -d ' ')"
echo "piraeus namespace    : ${NS:-none}"
echo "palette cluster ns   : ${CNS:-none}"
echo
echo "Most common cause on a single-node appliance: a resource group (named by the"
echo "StorageClass, or DfltRscGrp) with PlaceCount greater than the node count."

if [ "$DO_BUNDLE" = 1 ]; then
  tar czf "$OUT" -C "$D" . 2>/dev/null
  echo; echo "bundle: $OUT"
fi
echo "###### END ######"
