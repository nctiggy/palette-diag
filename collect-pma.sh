#!/usr/bin/env bash
# =============================================================================
# collect-pma.sh — comprehensive diagnostic collection for a Spectro Cloud
#                  Palette Management Appliance (PMA) installed from the ISO.
# -----------------------------------------------------------------------------
# Run this from any workstation that can reach the appliance's Kubernetes API
# with an exported KUBECONFIG. It gathers:
#
#   * full cluster state (nodes, pods, events, CRDs, versions)
#   * Palette control-plane internals (hubble, mongo, nats, ui, cp/jet systems)
#   * the internal pack registry (zot, :30003) and its reachability
#   * ingress, VIP, certificates and their expiry
#   * HOST-level data from every node via short-lived PRIVILEGED helper pods —
#     stylus/kairos/k8s journals, network config, NTP, disk, containerd, /oem
#
# and packs it all into a single .tgz, then uploads it.
#
# QUICK START
#     export KUBECONFIG=/path/to/appliance.kubeconfig
#     curl -fsSL <script-url> | bash -s -- --upload https://<your-upload-host>
#
# OPTIONS  (when run as a file, or via:  curl -fsSL URL | bash -s -- ARGS)
#     --kubeconfig PATH   explicit kubeconfig (otherwise $KUBECONFIG / default)
#     --context NAME      explicit context
#     --no-nodes          skip the privileged host-collection phase
#     --no-upload         build the bundle but do not upload it
#     --upload URL        override the upload endpoint
#     --image REF         image for the helper pods (see AIR-GAP below)
#     -h | --help         this header
#
# AIR-GAP: the appliance has no internet, so a helper pod cannot pull
#   ubuntu/busybox from Docker Hub. The script therefore AUTO-DETECTS an image
#   that is already cached on each node (it reuses an image from a pod already
#   running there) and verifies a shell works before relying on it. Override
#   with --image or COLLECT_NODE_IMAGE if you have a known-good local image.
#
# SAFETY
#   * read-only — nothing in the appliance is modified
#   * Secret VALUES are never collected (names/types only)
#   * a redaction pass scrubs password/token/key material out of host configs
#     (/oem user-data in particular) before the bundle is written
#   * every helper pod is force-deleted on exit, including on Ctrl-C
# =============================================================================
set +e +u
umask 077

# ---- config -----------------------------------------------------------------
CTX=""; KCFG=""; DO_NODES=1; DO_UPLOAD=1
UP="${UP:-}"
NODE_IMAGE="${COLLECT_NODE_IMAGE:-}"
CMD_TIMEOUT="${CMD_TIMEOUT:-90}"
LOG_TAIL="${LOG_TAIL:-3000}"      # container log lines per pod
HOST_TAIL="${HOST_TAIL:-5000}"    # journald lines per unit
NODE_WAIT="${NODE_WAIT:-120}"     # seconds to wait for a helper pod

while [ $# -gt 0 ]; do
  case "$1" in
    --kubeconfig) KCFG="$2"; shift 2;;
    --context)    CTX="$2";  shift 2;;
    --no-nodes)   DO_NODES=0; shift;;
    --no-upload)  DO_UPLOAD=0; shift;;
    --upload)     UP="$2";   shift 2;;
    --image)      NODE_IMAGE="$2"; shift 2;;
    -h|--help)    grep '^#' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; shift;;
  esac
done

command -v kubectl >/dev/null 2>&1 || { echo "FATAL: kubectl not found on PATH"; exit 1; }
command -v timeout >/dev/null 2>&1 || timeout(){ shift; "$@"; }

KARGS=""
[ -n "$KCFG" ] && KARGS="$KARGS --kubeconfig=$KCFG"
[ -n "$CTX" ]  && KARGS="$KARGS --context=$CTX"
KB(){ timeout "$CMD_TIMEOUT" kubectl $KARGS "$@"; }

if ! KB cluster-info >/dev/null 2>&1; then
  echo "FATAL: 'kubectl cluster-info' failed."
  echo "  KUBECONFIG=${KUBECONFIG:-<default ~/.kube/config>}"
  echo "  Export a working kubeconfig for the appliance, or pass --kubeconfig / --context."
  exit 1
fi

TS="$(date -u +%Y%m%d-%H%M%SZ 2>/dev/null || date +%Y%m%d-%H%M%S)"
CC="$(KB config current-context 2>/dev/null | tr -c 'A-Za-z0-9._-' '_')"; CC=${CC:-pma}
D="$(mktemp -d)"; OUT="/tmp/pma-collect-${CC}-$TS.tgz"
mkdir -p "$D"/{00-summary,10-cluster,20-network,30-palette,40-registry,50-certs,60-storage,70-events,80-logs,90-nodes}
LOG="$D/00-summary/00-summary.txt"; exec > >(tee "$LOG") 2>&1

r(){ o="$D/$1"; shift; mkdir -p "$(dirname "$o")"; echo "\$ kubectl $*" >"$o"; KB "$@" >>"$o" 2>&1; echo "[exit $?]" >>"$o"; }

HELPER_NS=""; HELPER_PODS=""
cleanup(){
  for p in $HELPER_PODS; do
    KB delete pod "$p" -n "${HELPER_NS:-default}" --force --grace-period=0 >/dev/null 2>&1
  done
  [ -n "$HELPER_NS" ] && KB delete ns "$HELPER_NS" --wait=false >/dev/null 2>&1
  return 0
}
trap cleanup EXIT INT TERM

echo "###### PALETTE MANAGEMENT APPLIANCE — DIAGNOSTIC COLLECT ($TS) ######"
echo "context   : $CC"
echo "kubeconfig: ${KCFG:-${KUBECONFIG:-<default>}}"
echo "node phase: $([ "$DO_NODES" = 1 ] && echo ON || echo OFF)   upload: $([ "$DO_UPLOAD" = 1 ] && echo "$UP" || echo OFF)"
echo

# =============================================================================
# 1. CLUSTER
# =============================================================================
echo "== cluster =="
r 10-cluster/cluster-info.txt        cluster-info
r 10-cluster/version.txt             version
r 10-cluster/nodes-wide.txt          get nodes -o wide
r 10-cluster/nodes.yaml              get nodes -o yaml
r 10-cluster/namespaces.txt          get ns
r 10-cluster/pods-wide.txt           get pods -A -o wide
r 10-cluster/workloads.txt           get deploy,ds,sts,rs,job,cronjob -A -o wide
r 10-cluster/apiservices.txt         get apiservices
r 10-cluster/crds.txt                get crd
r 10-cluster/configmaps.txt          get cm -A
r 10-cluster/api-resources.txt       api-resources --verbs=list
r 10-cluster/top-nodes.txt           top nodes
r 10-cluster/top-pods.txt            top pods -A
# secrets: NAMES AND TYPES ONLY — values are never collected
r 10-cluster/secrets-names-only.txt  get secrets -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,TYPE:.type,AGE:.metadata.creationTimestamp

echo "== describing unhealthy pods =="
KB get pods -A --no-headers 2>/dev/null \
  | awk '{ready=$3; st=$4; split(ready,a,"/"); if ((st!="Running" && st!="Completed") || a[1]!=a[2]) print $1" "$2}' \
  | while read -r ns p; do
      [ -z "$ns" ] && continue
      f="$D/10-cluster/unhealthy-$ns-$p.txt"
      { echo "\$ kubectl describe pod -n $ns $p"; KB describe pod -n "$ns" "$p" 2>&1
        echo; echo "---- current logs ----";  KB logs -n "$ns" "$p" --all-containers --tail="$LOG_TAIL" 2>&1
        echo; echo "---- previous logs ----"; KB logs -n "$ns" "$p" --all-containers --previous --tail="$LOG_TAIL" 2>&1
      } >"$f" 2>&1
    done

# =============================================================================
# 2. EVENTS
# =============================================================================
r 70-events/events-all.txt      get events -A --sort-by=.lastTimestamp
r 70-events/events-warning.txt  get events -A --field-selector type=Warning --sort-by=.lastTimestamp

# =============================================================================
# 3. NETWORK / VIP / INGRESS
# =============================================================================
echo "== network =="
r 20-network/svc-wide.txt        get svc -A -o wide
r 20-network/svc.yaml            get svc -A -o yaml
r 20-network/endpoints.txt       get endpoints -A -o wide
r 20-network/endpointslices.txt  get endpointslices -A -o wide
r 20-network/ingress.yaml        get ingress -A -o yaml
r 20-network/ingressclasses.txt  get ingressclass
r 20-network/netpol.yaml         get networkpolicies -A -o yaml
r 20-network/kube-vip-ds.yaml    get ds -n kube-system -l app.kubernetes.io/name=kube-vip -o yaml
r 20-network/metallb.yaml        get ipaddresspools,l2advertisements -A -o yaml
r 20-network/coredns-cm.yaml     get cm -n kube-system coredns -o yaml

# NodePort inventory — the appliance exposes 5080 (Local UI) and 30003 (registry)
KB get svc -A -o json 2>/dev/null | grep -q . && \
  KB get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.type}{"\t"}{range .spec.ports[*]}{.port}:{.nodePort}{" "}{end}{"\n"}{end}' \
  >"$D/20-network/nodeports.txt" 2>&1

# =============================================================================
# 4. PALETTE CONTROL PLANE
# =============================================================================
echo "== palette control plane =="
# discover Palette-ish namespaces rather than hardcoding a list
PAL_NS=$(KB get ns -o name 2>/dev/null | sed 's|namespace/||' \
        | grep -iE 'hubble|spectro|palette|jet|cp-system|ui-system|nats|mongo|reach|ingress|cert-manager|zot|harbor|registry|kube-system' \
        | sort -u)
echo "$PAL_NS" >"$D/30-palette/namespaces-of-interest.txt"

for ns in $PAL_NS; do
  b="$D/30-palette/$ns"; mkdir -p "$b"
  KB get all -n "$ns" -o wide        >"$b/all.txt"        2>&1
  KB describe pods -n "$ns"          >"$b/describe-pods.txt" 2>&1
  KB get events -n "$ns" --sort-by=.lastTimestamp >"$b/events.txt" 2>&1
  KB get cm -n "$ns" -o yaml         >"$b/configmaps.yaml" 2>&1
  KB get pvc -n "$ns" -o wide        >"$b/pvc.txt"        2>&1
  # logs for every container in every pod
  KB get pods -n "$ns" --no-headers -o custom-columns=N:.metadata.name 2>/dev/null | while read -r p; do
    [ -z "$p" ] && continue
    KB logs -n "$ns" "$p" --all-containers --tail="$LOG_TAIL" >"$b/logs-$p.txt" 2>&1
    KB logs -n "$ns" "$p" --all-containers --previous --tail="$LOG_TAIL" >"$b/logs-$p-previous.txt" 2>&1
    [ -s "$b/logs-$p-previous.txt" ] || rm -f "$b/logs-$p-previous.txt"
  done
done

# Palette CRs — the appliance manages itself through these
for k in spectroclusters clusterprofiles packs edgehosts cloudaccounts; do
  KB get "$k" -A -o yaml >"$D/30-palette/cr-$k.yaml" 2>&1
done

# version / build identity of the appliance
KB get cm -A -o json 2>/dev/null \
  | grep -iE '"(VERSION|BUILD_ID|version|build)"' >"$D/30-palette/version-strings.txt" 2>&1

# MongoDB — Palette's datastore. Replica-set health is a common root cause.
MONGO_POD=$(KB get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null | awk '/mongo/{print; exit}')
if [ -n "$MONGO_POD" ]; then
  mns=$(echo "$MONGO_POD" | awk '{print $1}'); mp=$(echo "$MONGO_POD" | awk '{print $2}')
  echo "  mongo: $mns/$mp"
  { echo "\$ rs.status()"
    KB exec -n "$mns" "$mp" -- mongosh --quiet --eval 'JSON.stringify(rs.status(),null,2)' 2>&1
    echo; echo "\$ db.serverStatus().connections"
    KB exec -n "$mns" "$mp" -- mongosh --quiet --eval 'JSON.stringify(db.serverStatus().connections)' 2>&1
  } >"$D/30-palette/mongo-status.txt" 2>&1
fi

# NATS — the appliance's message bus
NATS_POD=$(KB get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null | awk '/nats/{print; exit}')
if [ -n "$NATS_POD" ]; then
  nns=$(echo "$NATS_POD" | awk '{print $1}'); np=$(echo "$NATS_POD" | awk '{print $2}')
  KB exec -n "$nns" "$np" -- sh -c 'nats-server --version; nats str ls 2>/dev/null' >"$D/30-palette/nats-status.txt" 2>&1
fi

# =============================================================================
# 5. INTERNAL REGISTRY (zot / :30003)
# =============================================================================
echo "== internal registry =="
REG_POD=$(KB get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null | awk '/zot|registry|harbor/{print; exit}')
if [ -n "$REG_POD" ]; then
  rns=$(echo "$REG_POD" | awk '{print $1}'); rp=$(echo "$REG_POD" | awk '{print $2}')
  echo "  registry pod: $rns/$rp"
  KB describe pod -n "$rns" "$rp" >"$D/40-registry/describe.txt" 2>&1
  KB logs -n "$rns" "$rp" --all-containers --tail="$LOG_TAIL" >"$D/40-registry/logs.txt" 2>&1
  # catalog from inside the cluster (works even when :30003 is firewalled off)
  KB exec -n "$rns" "$rp" -- sh -c 'curl -sk https://127.0.0.1:5000/v2/_catalog || curl -s http://127.0.0.1:5000/v2/_catalog' \
    >"$D/40-registry/catalog.json" 2>&1
fi
# reachability of the documented NodePort from wherever this script runs
VIP=$(KB get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
{ echo "node IP tried: $VIP"
  echo "--- https://$VIP:30003/v2/ ---"; curl -sk -m 10 -o /dev/null -w 'http=%{http_code}\n' "https://$VIP:30003/v2/" 2>&1
  echo "--- https://$VIP/ (tenant console) ---"; curl -sk -m 10 -o /dev/null -w 'http=%{http_code}\n' "https://$VIP/" 2>&1
  echo "--- https://$VIP/system ---"; curl -sk -m 10 -o /dev/null -w 'http=%{http_code}\n' "https://$VIP/system" 2>&1
  echo "--- https://$VIP:5080 (local UI) ---"; curl -sk -m 10 -o /dev/null -w 'http=%{http_code}\n' "https://$VIP:5080" 2>&1
} >"$D/40-registry/endpoint-reachability.txt" 2>&1

# =============================================================================
# 6. CERTIFICATES  (expiry is a frequent appliance failure mode)
# =============================================================================
echo "== certificates =="
r 50-certs/certificates.yaml   get certificates -A -o yaml
r 50-certs/certrequests.txt    get certificaterequests -A
r 50-certs/issuers.txt         get issuers,clusterissuers -A
KB get secrets -A -o json 2>/dev/null \
  | python3 -c '
import sys,json,base64,ssl,datetime
try: d=json.load(sys.stdin)
except Exception as e: print("parse failed:",e); sys.exit(0)
for it in d.get("items",[]):
    if it.get("type")!="kubernetes.io/tls": continue
    ns=it["metadata"]["namespace"]; nm=it["metadata"]["name"]
    crt=it.get("data",{}).get("tls.crt")
    if not crt: continue
    try:
        pem=base64.b64decode(crt).decode()
        # only the metadata of the cert is printed — never the key
        import subprocess
        p=subprocess.run(["openssl","x509","-noout","-subject","-issuer","-dates"],
                         input=pem,capture_output=True,text=True)
        print(f"=== {ns}/{nm} ==="); print(p.stdout.strip() or p.stderr.strip()); print()
    except Exception as e:
        print(f"=== {ns}/{nm} === error: {e}\n")
' >"$D/50-certs/tls-expiry.txt" 2>&1

# =============================================================================
# 7. STORAGE
# =============================================================================
echo "== storage =="
r 60-storage/storageclasses.txt  get sc
r 60-storage/pv.txt              get pv -o wide
r 60-storage/pvc.txt             get pvc -A -o wide
r 60-storage/pv.yaml             get pv -o yaml

# =============================================================================
# 8. HOST-LEVEL COLLECTION VIA PRIVILEGED PODS
# =============================================================================
if [ "$DO_NODES" = 1 ]; then
  echo
  echo "== host collection (privileged pods) =="
  HELPER_NS="pma-collect-$$"
  KB create ns "$HELPER_NS" >/dev/null 2>&1
  KB label ns "$HELPER_NS" pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null 2>&1

  # ---- pick an image that is ALREADY on the node (air-gap safe) -------------
  # The appliance has no egress, so the helper pod must reuse an image the node
  # has already cached. Everything running on the node qualifies (pulled with
  # IfNotPresent it will never reach the network). Rank by likelihood of
  # containing a shell — the Palette control plane mixes alpine-based images
  # (mongo, nats, zot, nginx, stylus) with distroless ones (coredns, the Go
  # managers) that have no /bin/sh and can never host the collector.
  pick_image(){ # $1 = node
    [ -n "$NODE_IMAGE" ] && { echo "$NODE_IMAGE"; return; }
    KB get pods -A --field-selector "spec.nodeName=$1" \
        -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null \
      | grep -viE 'pause|distroless|scratch' | sort -u \
      | awk '
          /mongo|nats|zot|registry|harbor|nginx|alpine|busybox|ubuntu|debian|toolbox|stylus|kairos/ {print "0\t"$0; next}
          /spectro|palette|kube-vip|metallb/                                                       {print "1\t"$0; next}
                                                                                                   {print "2\t"$0}' \
      | sort -k1,1 | cut -f2- | head -8
  }

  # -------------------------------------------------------------------------
  # TIER A — full host command execution. Requires nsenter (util-linux) or
  # chroot in the helper image. $MODE is substituted per node by the prober.
  # -------------------------------------------------------------------------
  HOST_SCRIPT='
set +e
H=/host
MODE="__MODE__"
o(){ echo; echo "########## $* ##########"; }
run(){ o "$*"; if [ "$MODE" = nsenter ]; then nsenter -t 1 -m -u -i -n -p -- sh -c "$*" 2>&1; else chroot $H sh -c "$*" 2>&1; fi; }
cat_(){ o "cat $1"; cat "$H$1" 2>&1; }

o "identity"; echo "collector mode: $MODE"
run "date -u; uname -a"
run "hostnamectl 2>/dev/null; cat /etc/os-release"

o "===== TIME / NTP (cert + auth failures usually start here) ====="
run "timedatectl 2>/dev/null; chronyc tracking 2>/dev/null; ntpq -p 2>/dev/null; date -u"

o "===== SYSTEMD ====="
run "systemctl --failed --no-pager"
run "systemctl list-units --type=service --state=running --no-pager"

o "===== JOURNALS ====="
for u in spectro-stylus-agent stylus kairos-agent k3s k3s-agent kubelet containerd systemd-networkd systemd-resolved chronyd systemd-timesyncd; do
  run "journalctl -u $u --no-pager -n '"$HOST_TAIL"' 2>/dev/null | tail -n '"$HOST_TAIL"'"
done
run "journalctl -p err --no-pager -n 2000"
run "dmesg -T 2>/dev/null | tail -n 2000"

o "===== NETWORK ====="
run "ip -d addr; echo; ip route; echo; ip -6 route; echo; ip neigh"
run "ss -lntup 2>/dev/null || netstat -lntup 2>/dev/null"
run "iptables-save 2>/dev/null | head -n 4000"
run "nft list ruleset 2>/dev/null | head -n 2000"
cat_ /etc/resolv.conf
cat_ /etc/hosts
run "cat /etc/netplan/*.yaml 2>/dev/null"
run "nmcli con show 2>/dev/null; nmcli dev show 2>/dev/null"

o "===== DISK / MEMORY (a full disk stalls the appliance) ====="
run "df -hT; echo; df -i"
run "lsblk -f; echo; mount | sort"
run "free -m; echo; uptime; echo; vmstat 1 3"
run "du -xh --max-depth=2 /var 2>/dev/null | sort -rh | head -40"
run "du -xh --max-depth=2 /run/stylus /opt /persistent 2>/dev/null | sort -rh | head -40"

o "===== CONTAINER RUNTIME ====="
run "crictl version 2>/dev/null; crictl info 2>/dev/null | head -n 200"
run "crictl ps -a 2>/dev/null"
run "crictl images 2>/dev/null"
cat_ /etc/containerd/config.toml
run "ls -la /etc/containerd/certs.d 2>/dev/null; find /etc/containerd/certs.d -name hosts.toml -exec sh -c \"echo == {}; cat {}\" \\; 2>/dev/null"

o "===== KAIROS / STYLUS APPLIANCE STATE ====="
run "ls -la /oem /etc/kairos /etc/spectro /run/stylus /usr/local/.state 2>/dev/null"
run "cat /etc/kairos/* 2>/dev/null | head -n 400"
run "cat /run/stylus/*.yaml /run/stylus/**/*.yaml 2>/dev/null | head -n 400"
run "cat /oem/*.yaml 2>/dev/null | head -n 600"
run "kairos-agent state 2>/dev/null; stylus --version 2>/dev/null"
run "cat /proc/cmdline"

o "===== K8S NODE FILES ====="
run "ls -la /etc/kubernetes /var/lib/rancher/k3s/server/manifests 2>/dev/null"
run "cat /etc/kubernetes/manifests/*.yaml 2>/dev/null | head -n 600"
'

  # -------------------------------------------------------------------------
  # TIER B — no nsenter and no chroot in any cached image. Read the host
  # filesystem directly through the /host mount using ONLY shell builtins
  # (read/echo/glob), because these minimal images often lack even cat and ls.
  # Far less than tier A, but still yields OS identity, network config, kairos
  # and stylus state, containerd config and the static pod manifests.
  # -------------------------------------------------------------------------
  HOST_SCRIPT_FILES='
set +e
H=/host
o(){ echo; echo "########## $* ##########"; }
dump(){ o "file $1"; if [ -r "$H$1" ]; then while IFS= read -r l || [ -n "$l" ]; do echo "$l"; done <"$H$1"; else echo "(unreadable or missing)"; fi; }
glob(){ o "glob $1"; for f in $H$1; do [ -e "$f" ] && echo "--- ${f#$H} ---" && { while IFS= read -r l || [ -n "$l" ]; do echo "$l"; done <"$f"; }; done; }
listd(){ o "dir $1"; for f in $H$1/*; do [ -e "$f" ] && echo "${f#$H}"; done; }

o "identity"; echo "collector mode: files-only (no nsenter/chroot in any cached image)"
dump /etc/os-release
dump /etc/hostname
dump /proc/cmdline
dump /proc/uptime
dump /proc/loadavg
dump /proc/meminfo
dump /proc/mounts
dump /proc/net/dev
dump /proc/net/route
dump /proc/net/tcp

o "===== NETWORK ====="
dump /etc/resolv.conf
dump /etc/hosts
glob /etc/netplan/*.yaml
listd /etc/systemd/network
glob /etc/systemd/network/*

o "===== CONTAINER RUNTIME ====="
dump /etc/containerd/config.toml
listd /etc/containerd/certs.d

o "===== KAIROS / STYLUS APPLIANCE STATE ====="
listd /oem
glob /oem/*.yaml
listd /etc/kairos
glob /etc/kairos/*
listd /etc/spectro
listd /run/stylus
glob /run/stylus/*.yaml

o "===== K8S NODE FILES ====="
listd /etc/kubernetes
listd /etc/kubernetes/manifests
glob /etc/kubernetes/manifests/*.yaml
listd /var/lib/rancher/k3s/server/manifests

o "===== RECENT LOG FILES (journald is binary; plain logs only) ====="
glob /var/log/syslog
glob /var/log/messages
listd /var/log
'

  for n in $(KB get nodes -o name 2>/dev/null | sed 's|node/||'); do
    echo "  -- node: $n"
    nd="$D/90-nodes/$n"; mkdir -p "$nd"
    KB describe node "$n" >"$nd/describe.txt" 2>&1

    OKIMG=""; FALLBACK_IMG=""
    for img in $(pick_image "$n"); do
      pod="pma-collect-$(echo "$n" | tr -c 'a-z0-9' '-' | cut -c1-40)-$RANDOM"
      cat <<EOF | KB apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  namespace: $HELPER_NS
spec:
  nodeName: $n
  hostPID: true
  hostIPC: true
  hostNetwork: true
  restartPolicy: Never
  tolerations: [{operator: "Exists"}]
  containers:
  - name: c
    image: $img
    imagePullPolicy: IfNotPresent
    securityContext: {privileged: true, runAsUser: 0}
    command: ["sh","-c","sleep 900"]
    volumeMounts: [{name: host, mountPath: /host}]
  volumes:
  - name: host
    hostPath: {path: /}
EOF
      HELPER_PODS="$HELPER_PODS $pod"
      # Wait for Running, then PROVE a shell works before trusting this image.
      # A shell-less image fails to start rather than hanging, so bail out early
      # on Failed/ImagePullBackOff and move to the next candidate instead of
      # spending the full timeout on an image that can never work.
      for _ in $(seq 1 "$NODE_WAIT"); do
        ph=$(KB get pod "$pod" -n "$HELPER_NS" -o jsonpath='{.status.phase}' 2>/dev/null)
        [ "$ph" = "Running" ] && break
        [ "$ph" = "Failed" ]  && break
        wr=$(KB get pod "$pod" -n "$HELPER_NS" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
        case "$wr" in ErrImagePull|ImagePullBackOff|CreateContainerError|RunContainerError|CrashLoopBackOff) break;; esac
        sleep 1
      done
      # Probe what this image can ACTUALLY do against the host. `echo ok` is not
      # a sufficient test: minimal images (kube-proxy, most Go control-plane
      # images) have a shell but no nsenter, no chroot, and no coreutils, so
      # every host command silently returns "not found". Ask the real question.
      CAP=$(KB exec -n "$HELPER_NS" "$pod" -- sh -c '
        nsenter -t 1 -m -u -i -n -p -- true 2>/dev/null && { echo nsenter; exit; }
        chroot /host /bin/true      2>/dev/null && { echo chroot;  exit; }
        [ -r /host/proc/cmdline ]              && { echo files;   exit; }
        echo none' 2>/dev/null | tr -d '\r' | tail -1)

      case "$CAP" in
        nsenter|chroot)
          OKIMG="$img"
          echo "     image: $img   (host access: $CAP)"
          printf '%s' "$HOST_SCRIPT" | sed "s|__MODE__|$CAP|" \
            | KB exec -i -n "$HELPER_NS" "$pod" -- sh >"$nd/host.txt" 2>&1
          KB delete pod "$pod" -n "$HELPER_NS" --force --grace-period=0 >/dev/null 2>&1
          break;;
        files)
          # usable, but only for file reads — keep looking for something better
          if [ -z "$FALLBACK_IMG" ]; then FALLBACK_IMG="$img"; fi
          echo "     $img — file-read only, trying for a better image"
          KB delete pod "$pod" -n "$HELPER_NS" --force --grace-period=0 >/dev/null 2>&1
          ;;
        *)
          KB delete pod "$pod" -n "$HELPER_NS" --force --grace-period=0 >/dev/null 2>&1
          ;;
      esac
    done

    # No image could exec against the host, but one could at least read /host —
    # run the builtin-only file collection rather than returning nothing.
    if [ -z "$OKIMG" ] && [ -n "$FALLBACK_IMG" ]; then
      echo "     falling back to file-read collection via $FALLBACK_IMG"
      pod="pma-collect-fb-$(echo "$n" | tr -c 'a-z0-9' '-' | cut -c1-36)-$RANDOM"
      cat <<EOF | KB apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  namespace: $HELPER_NS
spec:
  nodeName: $n
  hostPID: true
  hostIPC: true
  hostNetwork: true
  restartPolicy: Never
  tolerations: [{operator: "Exists"}]
  containers:
  - name: c
    image: $FALLBACK_IMG
    imagePullPolicy: IfNotPresent
    securityContext: {privileged: true, runAsUser: 0}
    command: ["sh","-c","sleep 600"]
    volumeMounts: [{name: host, mountPath: /host}]
  volumes:
  - name: host
    hostPath: {path: /}
EOF
      HELPER_PODS="$HELPER_PODS $pod"
      for _ in $(seq 1 "$NODE_WAIT"); do
        [ "$(KB get pod "$pod" -n "$HELPER_NS" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] && break
        sleep 1
      done
      printf '%s' "$HOST_SCRIPT_FILES" | KB exec -i -n "$HELPER_NS" "$pod" -- sh >"$nd/host.txt" 2>&1
      OKIMG="$FALLBACK_IMG (file-read only)"
      KB delete pod "$pod" -n "$HELPER_NS" --force --grace-period=0 >/dev/null 2>&1
    fi

    if [ -z "$OKIMG" ]; then
      echo "     !! no usable image on $n — host data skipped."
      echo "        re-run with: --image <an image on that node containing nsenter or chroot>"
      { echo "No cached image on this node could reach the host filesystem."
        echo "Images tried:"; pick_image "$n"
        echo; echo "Re-run with --image REF pointing at an image already present on the node"
        echo "that contains nsenter (util-linux) or chroot."
      } >"$nd/host-SKIPPED.txt"
    fi
  done
fi

# =============================================================================
# 9. REDACT, PACKAGE, UPLOAD
# =============================================================================
echo
echo "== redacting secret material =="
# Scrub credential-looking values out of anything pulled off the hosts / ConfigMaps
# (/oem site user-data on an ISO-installed appliance carries the node password and
# the registration token in clear text).
#
# Pass 1 — key/value pairs. The value alternation deliberately matches a
# double-quoted, single-quoted OR bare value: an earlier version excluded the
# quote character, so `apiKey: "sk-live-…"` matched zero characters and sailed
# through un-redacted.
find "$D" -type f -print0 2>/dev/null | xargs -0 -r sed -i -E \
  -e 's/((password|passwd|passphrase|token|secret|apikey|api_key|access_key|secret_key|private_key|client-key-data|bearer|credential)[[:space:]]*[:=][[:space:]]*)("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:],;]+)/\1<REDACTED>/Ig' \
  2>/dev/null

# Pass 2 — PEM blocks. sed works a line at a time, so a BEGIN…END regex spanning
# lines can never match; delete the body lines between the markers instead.
find "$D" -type f -print0 2>/dev/null | xargs -0 -r sed -i \
  -e '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/{//!d}' \
  2>/dev/null

{ echo "collected : $TS"
  echo "context   : $CC"
  echo "nodes     : $(KB get nodes --no-headers 2>/dev/null | wc -l)"
  echo "pods !ok  : $(KB get pods -A --no-headers 2>/dev/null | awk '{split($3,a,"/"); if(($4!="Running"&&$4!="Completed")||a[1]!=a[2]) c++} END{print c+0}')"
  echo "bundle    : $OUT"
} >"$D/00-summary/manifest.txt"

tar czf "$OUT" -C "$D" . 2>/dev/null
SIZE=$(wc -c <"$OUT" 2>/dev/null | tr -d ' ')
echo "bundle: $OUT  ($SIZE bytes)"

if [ "$DO_UPLOAD" = 1 ] && [ -z "$UP" ]; then
  echo "== upload skipped — no endpoint given =="
  echo "   Re-run with --upload https://<host>, or hand the bundle over directly:"
  echo "     $OUT"
elif [ "$DO_UPLOAD" = 1 ]; then
  echo "== upload -> $UP =="
  NAME="$(basename "$OUT")"
  CHUNK=$((90 * 1024 * 1024))     # stay under Cloudflare's 100 MB body cap
  if ! curl -fsS -m 15 -o /dev/null "$UP/upload" 2>/dev/null; then
    echo "!! upload endpoint $UP is not reachable from this machine."
    echo "   The bundle is complete and kept at: $OUT"
    echo "   Move it to a machine with egress and run:"
    echo "     curl -fSs --upload-file $OUT $UP/upload/$NAME"
  elif [ "${SIZE:-0}" -le "$CHUNK" ]; then
    curl -fSs --upload-file "$OUT" "$UP/upload/$NAME" && echo && echo "uploaded: $NAME"
  else
    SESSION="$(date +%s)-$$-${RANDOM}"
    PARTS=$(( (SIZE + CHUNK - 1) / CHUNK ))
    T2="$(mktemp -d)"
    echo "chunking into $PARTS parts (session $SESSION)…"
    split -b "$CHUNK" -d -a 6 "$OUT" "$T2/part_"
    i=0
    for p in "$T2"/part_*; do
      seq=$(printf '%06d' "$i")
      curl -fSs --upload-file "$p" "$UP/upload/chunk/$SESSION/$seq" >/dev/null && \
        echo "  chunk $((i+1))/$PARTS"
      i=$((i+1))
    done
    curl -fSs -X POST "$UP/upload/finish/$SESSION?name=$NAME&size=$SIZE" && echo && echo "uploaded: $NAME"
    rm -rf "$T2"
  fi
fi

echo
echo "###### DONE ######"
echo "bundle kept locally at: $OUT"
