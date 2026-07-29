#!/usr/bin/env bash
# =============================================================================
# collect-registry-cli.sh — support bundle for two Palette appliance problems:
#
#   1. a registry (Helm / OCI / Pack) that never finishes syncing
#   2. `palette content build` failing to produce a content bundle
#
# Run from a machine that can reach the appliance's Kubernetes API:
#
#   export KUBECONFIG=/path/to/appliance.kubeconfig
#   curl -fsSL https://raw.githubusercontent.com/nctiggy/palette-diag/main/collect-registry-cli.sh \
#     | bash -s -- --upload https://ge-upload.craigcloud.io
#
# Optional, and worth supplying — each one unlocks a whole section:
#
#   --api-key KEY --console-url https://<vip>   query the live registry sync API
#   --profile-id ID --project-id ID             re-run the failing content build
#                                               under trace logging and capture it
#   --cli /path/to/palette                      use an existing Palette CLI binary
#   --no-mongo                                  skip the MongoDB sync-state dump
#   --no-upload                                 build the bundle only
#
# IF YOU RAN `palette content build` ON A DIFFERENT MACHINE than the appliance
# (a build server, a workstation, a pipeline runner) its logs are on THAT
# machine, not this one. Run this on the build machine as well — no kubeconfig
# and no cluster access needed:
#
#   curl -fsSL https://raw.githubusercontent.com/nctiggy/palette-diag/main/collect-registry-cli.sh \
#     | bash -s -- --cli-only --upload https://ge-upload.craigcloud.io
#
# Read-only apart from the optional content-build re-run, which writes only to a
# temp directory. Credentials are redacted before the bundle is written.
# curl uses -k throughout: enterprise TLS interception re-signs traffic.
# =============================================================================
set +e +u
umask 077

UP=""; API_KEY=""; CONSOLE=""; PROFILE_ID=""; PROJECT_ID=""; CLI=""
DO_MONGO=1; DO_UPLOAD=1; ARCH="amd64"; CLI_ONLY=0
LOG_TAIL="${LOG_TAIL:-10000}"

while [ $# -gt 0 ]; do
  case "$1" in
    --upload)       UP="$2"; shift 2;;
    --no-upload)    DO_UPLOAD=0; shift;;
    --api-key)      API_KEY="$2"; shift 2;;
    --console-url)  CONSOLE="${2%/}"; shift 2;;
    --profile-id)   PROFILE_ID="$2"; shift 2;;
    --project-id)   PROJECT_ID="$2"; shift 2;;
    --cli)          CLI="$2"; shift 2;;
    --arch)         ARCH="$2"; shift 2;;
    --no-mongo)     DO_MONGO=0; shift;;
    --cli-only)     CLI_ONLY=1; DO_MONGO=0; shift;;
    --kubeconfig)   export KUBECONFIG="$2"; shift 2;;
    -h|--help)      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) shift;;
  esac
done

if [ "$CLI_ONLY" = 0 ]; then
  command -v kubectl >/dev/null 2>&1 || { echo "FATAL: kubectl not on PATH. If this machine only ran the Palette CLI, use --cli-only"; exit 1; }
  kubectl cluster-info >/dev/null 2>&1 || { echo "FATAL: kubectl cannot reach the cluster (KUBECONFIG=${KUBECONFIG:-default}). If this machine only ran the Palette CLI, use --cli-only"; exit 1; }
fi

TS="$(date -u +%Y%m%d-%H%M%SZ)"
D="$(mktemp -d)"; OUT="/tmp/palette-registry-cli-$TS.tgz"
mkdir -p "$D"/{00-context,10-registry,20-synclogs,30-cli,40-cluster}
exec > >(tee "$D/00-context/console.txt") 2>&1

h(){ echo; echo "==================== $* ===================="; }
run(){ echo; echo "\$ $*"; "$@" 2>&1; }
cap(){ f="$1"; shift; { echo "\$ $*"; "$@" 2>&1; } > "$f" 2>&1; }

NS=hubble-system
echo "###### PALETTE REGISTRY + CLI SUPPORT BUNDLE ($TS) ######"
echo "collected by: $(whoami)@$(hostname 2>/dev/null)"

# ---------------------------------------------------------------- 00 context
h "CONTEXT"
echo "mode: $([ "$CLI_ONLY" = 1 ] && echo 'CLI-ONLY (no cluster access)' || echo 'full (appliance + CLI)')"
run date -u
echo "local time: $(date)"
[ "$CLI_ONLY" = 0 ] && run kubectl version
[ "$CLI_ONLY" = 0 ] && cap "$D/00-context/nodes.txt"       kubectl get nodes -o wide
[ "$CLI_ONLY" = 0 ] && cap "$D/00-context/appliance-version.txt" \
  kubectl get deploy -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}'
[ "$CLI_ONLY" = 0 ] && echo "--- appliance image versions ---"
[ "$CLI_ONLY" = 0 ] && kubectl get deploy -n "$NS" -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null \
  | sed 's/.*://' | sort -u | tr '\n' ' '; echo

# ---------------------------------------------------------------- 10 registry state (MongoDB)
# Field paths verified against a live 4.9.8 appliance:
#   helm -> status.helmSyncStatus   oci -> status.syncStatus   pack -> status.packSyncStatus
if [ "$DO_MONGO" = 1 ] && [ "$CLI_ONLY" = 0 ]; then
  h "REGISTRY SYNC STATE (MongoDB)"
  MP="$(kubectl get secret spectromongosecret -n "$NS" -o jsonpath='{.data.mongoRootPassword}' 2>/dev/null | base64 -d 2>/dev/null)"
  MPOD="$(kubectl get pods -n "$NS" -o name 2>/dev/null | grep -E 'mongo-[0-9]+$' | head -1 | sed 's|pod/||')"
  if [ -n "$MP" ] && [ -n "$MPOD" ]; then
    echo "querying $MPOD ..."
    kubectl exec -n "$NS" "$MPOD" -c mongo -- mongosh --quiet -u root -p "$MP" \
      --authenticationDatabase admin --eval '
      db = db.getSiblingDB("hubbledb");
      var now = new Date();
      db.registries.find({}).forEach(function(r){
        var m = r.metadata || {};
        print("=========================================================");
        print("name          : " + m.name);
        print("uid           : " + m.uid);
        print("kind          : " + r.kind);
        var s = r.status || {};
        var key = s.helmSyncStatus ? "helmSyncStatus"
                : s.packSyncStatus ? "packSyncStatus"
                : s.syncStatus     ? "syncStatus" : null;
        if (!key) { print("  (no sync status recorded)"); return; }
        var st = s[key];
        print("status field  : status." + key);
        print("inProgress    : " + st.inProgress);
        print("succeeded     : " + st.succeeded);
        print("message       : " + (st.message || "(empty)"));
        print("lastRunTime   : " + st.lastRunTime);
        print("lastSyncedTime: " + st.lastSyncedTime);
        print("retryCount    : " + st.retryCount);
        print("nextRetryTime : " + st.nextRetryTime);
        print("isSyncSupported:" + st.isSyncSupported);
        var beat = st.registrySyncBeatTime || st.lastSyncBeatTime;
        print("syncBeatTime  : " + (beat || "(absent - normal when no sync is running)"));
        if (st.syncRecovery) {
          print("recoveryState : " + st.syncRecovery.syncRecoveryState);
          print("recovery start: " + st.syncRecovery.startTime);
          print("recovery end  : " + st.syncRecovery.endTime);
          print("recovery msg  : " + (st.syncRecovery.message || "(empty)"));
        }
        // ---- the actual verdict -------------------------------------
        if (st.inProgress === true) {
          var mins = beat ? Math.round((now - new Date(beat))/60000) : null;
          var ran  = st.lastRunTime ? Math.round((now - new Date(st.lastRunTime))/60000) : null;
          print(">>> SYNC IS IN PROGRESS. running for ~" + ran + " min");
          if (mins === null)      print(">>> no heartbeat recorded -> likely ORPHANED (pod died mid-sync)");
          else if (mins > 30)     print(">>> heartbeat is " + mins + " min stale -> ORPHANED (pod died mid-sync)");
          else                    print(">>> heartbeat is fresh (" + mins + " min) -> goroutine ALIVE but possibly BLOCKED on the registry/network");
        } else {
          print(">>> sync not currently running.");
        }
        print("--- spec (endpoint / auth type; secrets not shown) ---");
        var sp = r.spec || {};
        printjson({ endpoint: sp.endpoint, baseContentPath: sp.baseContentPath,
                    isPrivate: sp.isPrivate, insecureSkipVerify: sp.insecureSkipVerify,
                    scope: sp.scope, providerType: sp.providerType,
                    isSyncSupported: sp.isSyncSupported });
      });
    ' 2>&1 | tee "$D/10-registry/mongo-registry-state.txt"
  else
    echo "!! could not reach MongoDB (secret or pod missing) - skipping"
    echo "   secret spectromongosecret present: $([ -n "$MP" ] && echo yes || echo no)"
    echo "   mongo pod: ${MPOD:-<none>}"
  fi
fi

# ---------------------------------------------------------------- 15 projects + profiles
# Your project/profile IDs are site-specific, so discover them rather than asking
# anyone to go and look them up. Also flags which profiles carry a Helm-registry
# layer, since those are the ones a stuck Helm sync will break.
if [ "$DO_MONGO" = 1 ] && [ -n "$MP" ] && [ -n "$MPOD" ]; then
  h "PROJECTS + CLUSTER PROFILES (discovered)"
  mkdir -p "$D/15-profiles"
  kubectl exec -n "$NS" "$MPOD" -c mongo -- mongosh --quiet -u root -p "$MP" \
    --authenticationDatabase admin --eval '
    db = db.getSiblingDB("hubbledb");
    var projName = {}, regName = {}, regKind = {};
    db.projects.find({},{ "metadata.name":1,"metadata.uid":1 }).forEach(function(p){
      projName[p.metadata.uid] = p.metadata.name;
    });
    db.registries.find({},{ "metadata.name":1,"metadata.uid":1,"kind":1 }).forEach(function(r){
      regName[r.metadata.uid] = r.metadata.name; regKind[r.metadata.uid] = r.kind;
    });
    print("=== PROJECTS ===");
    Object.keys(projName).forEach(function(u){ print("  " + projName[u] + "   projectUid=" + u); });
    print("");
    print("=== CLUSTER PROFILES ===");
    db.clusterprofiles.find({}).forEach(function(p){
      var m = p.metadata || {}, a = p.aclmeta || {};
      var pub = (p.spec && (p.spec.published || p.spec.draft)) || {};
      var packs = pub.packs || [];
      var helm = packs.filter(function(k){ return k.type === "helm" || k.type === "oci"; });
      print("  ------------------------------------------------------");
      print("  name       : " + m.name);
      print("  profileUid : " + m.uid);
      print("  projectUid : " + (a.projectUid || "(tenant scope)") +
            "  (" + (projName[a.projectUid] || a.scope || "?") + ")");
      print("  type/scope : " + (pub.type || "?") + " / " + (a.scope || "?"));
      print("  packs      : " + packs.length);
      packs.forEach(function(k){
        var src = k.registryUid ? (regName[k.registryUid] || k.registryUid) : "(inline/manifest)";
        print("     - " + k.name + "  v" + (k.version||k.tag) +
              "  type=" + k.type + "  layer=" + k.layer + "  registry=" + src);
      });
      if (helm.length) {
        helm.forEach(function(k){
          print("  >>> HELM/OCI LAYER from registry \"" +
                (regName[k.registryUid]||k.registryUid) + "\" (" + (regKind[k.registryUid]||"?") + ")");
        });
        // machine-readable pick line for the content-build re-run
        print("AUTOPICK\t" + m.uid + "\t" + (a.projectUid||"") + "\t" + m.name);
      }
    });
  ' 2>&1 | tee "$D/15-profiles/projects-and-profiles.txt" | grep -v '^AUTOPICK'

  grep -a '^AUTOPICK' "$D/15-profiles/projects-and-profiles.txt" > "$D/15-profiles/.autopick" 2>/dev/null
  sed -i '/^AUTOPICK/d' "$D/15-profiles/projects-and-profiles.txt" 2>/dev/null

  if [ -s "$D/15-profiles/.autopick" ]; then
    echo
    echo ">>> Profiles above marked HELM/OCI LAYER are the ones a stuck Helm"
    echo ">>> registry sync will break. To capture the content-build failure,"
    echo ">>> re-run this script adding:"
    while IFS="$(printf '\t')" read -r _ puid pruid pname; do
      echo ">>>   # $pname"
      echo ">>>   --api-key <KEY> --console-url https://<vip> --cli <path/to/palette> \\"
      echo ">>>     --profile-id $puid${pruid:+ --project-id $pruid}"
    done < "$D/15-profiles/.autopick"
  fi
fi

# ---------------------------------------------------------------- 10 registry state (API)
if [ -n "$API_KEY" ] && [ -n "$CONSOLE" ]; then
  h "REGISTRY SYNC STATE (API)"
  for t in helm oci pack; do
    echo; echo "\$ GET $CONSOLE/v1/registries/$t"
    curl -k -sS -m 30 -H "ApiKey: $API_KEY" "$CONSOLE/v1/registries/$t" \
      | tee "$D/10-registry/api-registries-$t.json" | head -c 4000
    echo
    # per-registry sync status
    for uid in $(curl -k -sS -m 30 -H "ApiKey: $API_KEY" "$CONSOLE/v1/registries/$t" 2>/dev/null \
                  | grep -o '"uid":"[^"]*"' | cut -d'"' -f4 | sort -u); do
      case "$t" in
        oci) path="/v1/registries/oci/$uid/basic/sync/status";;
        *)   path="/v1/registries/$t/$uid/sync/status";;
      esac
      echo "\$ GET $path"
      curl -k -sS -m 30 -H "ApiKey: $API_KEY" "$CONSOLE$path" \
        | tee "$D/10-registry/api-syncstatus-$t-$uid.json"; echo
    done
  done
else
  echo; echo ">>> no --api-key/--console-url given: skipping live registry API checks."
fi

# ---------------------------------------------------------------- 20 sync logs
# The sync machinery lives in three deployments. registrySyncRecovery (the
# auto-healer) runs ONLY in spectrocluster-reconciler - the others log
# "Skipping schedulling registrySyncRecovery, since Schdeuler not enabled".
if [ "$CLI_ONLY" = 0 ]; then
h "REGISTRY SYNC LOGS"
SYNC_RE='helmregistry_service|registry_sync_beat_manager|spectrocluster_packsync_service|registrySyncRecovery|packsync|SyncHelmRegistries|syncDefaultRegistry|beat manager|sync recovery|InProgress|panic|Panic'

for dep in spectrocluster spectrocluster-jobs spectrocluster-reconciler mgmt system; do
  echo; echo "---- $dep ----"
  kubectl logs -n "$NS" "deploy/$dep" --tail="$LOG_TAIL" --all-containers >"$D/20-synclogs/$dep-full.log" 2>&1
  kubectl logs -n "$NS" "deploy/$dep" --tail="$LOG_TAIL" --all-containers --previous \
      >"$D/20-synclogs/$dep-previous.log" 2>/dev/null
  [ -s "$D/20-synclogs/$dep-previous.log" ] || rm -f "$D/20-synclogs/$dep-previous.log"
  grep -aiE "$SYNC_RE" "$D/20-synclogs/$dep-full.log" 2>/dev/null \
    | tail -60 | tee "$D/20-synclogs/$dep-sync-filtered.log"
done

echo; echo "--- packsync panics (a panic mid-sync leaves inProgress=true forever) ---"
grep -ah -A6 'panicked while watching packsync\|PANIC\|Panic recovered' "$D/20-synclogs/"*-full.log 2>/dev/null \
  | head -40 | tee "$D/20-synclogs/panics.txt"
PANICS=$(grep -ah 'panicked while watching packsync\|Panic recovered' "$D/20-synclogs/"*-full.log 2>/dev/null | wc -l | tr -d ' ')
echo "panic occurrences: ${PANICS:-0}"

echo; echo "--- beat manager register/deregister pairing ---"
# A registry that was registered but never deregistered = the sync goroutine is
# still holding it. That is the signature of a sync that never finished.
grep -ah "beat manager: registered\|beat manager: deregistered" "$D/20-synclogs/"*-full.log 2>/dev/null \
  | tee "$D/20-synclogs/beat-pairing.txt" | tail -20
REG=$(grep -ah "beat manager: registered"   "$D/20-synclogs/"*-full.log 2>/dev/null | wc -l | tr -d ' ')
DEREG=$(grep -ah "beat manager: deregistered" "$D/20-synclogs/"*-full.log 2>/dev/null | wc -l | tr -d ' ')
echo "registered=${REG:-0}  deregistered=${DEREG:-0}"
if [ "${REG:-0}" -gt "${DEREG:-0}" ] 2>/dev/null; then
  echo ">>> $(( REG - DEREG )) registry sync(s) registered but never deregistered."
  echo ">>> That sync goroutine never completed - matches a permanently 'in progress' registry."
fi

echo; echo "--- is the recovery scheduler actually scheduled? ---"
grep -ah "registrySyncRecovery\|sync recovery scheduler" "$D/20-synclogs/"*-full.log 2>/dev/null | tail -20
echo
echo ">>> expect in spectrocluster-reconciler:"
echo ">>>   'Scheduled job registrySyncRecovery with an interval of 15m0s and staleness 2h0m0s'"
echo ">>>   'sync recovery scheduler started' every 15 min"
echo ">>> if those lines are ABSENT, stuck syncs will never self-heal."

# ---------------------------------------------------------------- 20 broker / mongo health
h "MSGBROKER + MONGO HEALTH"
cap "$D/20-synclogs/msgbroker-pods.txt"  kubectl get pods -n "$NS" -l app=msgbroker -o wide
kubectl logs -n "$NS" -l app=msgbroker --tail=300 --all-containers >"$D/20-synclogs/msgbroker.log" 2>&1
cap "$D/20-synclogs/mongo-pods.txt"      kubectl get pods -n "$NS" -o wide
run kubectl get cronjobs -n "$NS"

echo; echo "--- restarts / OOMKills in $NS (a restart mid-sync is the usual cause) ---"
kubectl get pods -n "$NS" --no-headers 2>/dev/null | awk '$4>0 {print "  RESTARTED x"$4"  "$1}'
kubectl get pods -n "$NS" -o json 2>/dev/null \
  | grep -B4 -A2 'OOMKilled' | head -40

fi   # end cluster-only sections

# ---------------------------------------------------------------- 30 Palette CLI
h "PALETTE CLI"

if [ -z "$CLI" ]; then
  for c in ./palette /usr/local/bin/palette "$(command -v palette 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { CLI="$c"; break; }
  done
fi

if [ -n "$CLI" ]; then
  echo "using CLI: $CLI"
  { echo "\$ $CLI version"; "$CLI" version 2>&1; } | tee "$D/30-cli/version.txt"
  echo "binary size: $(du -h "$CLI" 2>/dev/null | cut -f1)"
else
  echo "!! Palette CLI not found. Pass --cli /path/to/palette."
  echo "   Download the version matching the appliance from:"
  echo "   https://software.spectrocloud.com/palette-cli/v<version>/linux/cli/palette"
fi

# --- the CLI's own artefacts. palette.log is the single most useful file here.
# The CLI writes to $HOME/.palette, so a sudo/su run lands in /root/.palette and
# a pipeline run lands in that service account's home. Search all of them.
echo; echo "--- locating Palette CLI workspaces ---"
CANDIDATES="${PALETTE_WORKSPACE:-} $HOME/.palette /root/.palette"
for hd in /home/*/ /Users/*/; do CANDIDATES="$CANDIDATES ${hd}.palette"; done
# last resort: a bounded search for the CLI's own config file
CANDIDATES="$CANDIDATES $(find / -maxdepth 5 -name palette.yaml -path '*/.palette/*' 2>/dev/null \
                            | sed 's|/palette.yaml$||' | head -10)"

FOUND=0
for PW in $CANDIDATES; do
  [ -n "$PW" ] && [ -d "$PW" ] || continue
  case " $SEEN " in *" $PW "*) continue;; esac
  SEEN="$SEEN $PW"
  FOUND=$((FOUND+1))
  TAG="$(printf '%s' "$PW" | tr '/' '_' | sed 's/^_//')"
  echo "  [$FOUND] $PW   (owner: $(stat -c '%U' "$PW" 2>/dev/null))"
  mkdir -p "$D/30-cli/workspaces/$TAG"
  { echo "path: $PW"; ls -la "$PW" "$PW/logs" 2>/dev/null; } \
      > "$D/30-cli/workspaces/$TAG/listing.txt" 2>&1
  cp -a "$PW/logs/."     "$D/30-cli/workspaces/$TAG/logs/" 2>/dev/null
  cp    "$PW/palette.yaml" "$D/30-cli/workspaces/$TAG/palette.yaml" 2>/dev/null  # redacted below
  cp    "$PW/.version"     "$D/30-cli/workspaces/$TAG/cli-dot-version" 2>/dev/null
  N=$(find "$D/30-cli/workspaces/$TAG/logs" -type f 2>/dev/null | wc -l)
  echo "      -> $N log file(s)"
  # keep the primary one where the build re-run expects it
  [ "$FOUND" = 1 ] && { PWMAIN="$PW"; mkdir -p "$D/30-cli/logs"; cp -a "$PW/logs/." "$D/30-cli/logs/" 2>/dev/null; }
done

CLILOGS=$(find "$D/30-cli/workspaces" -name '*.log' 2>/dev/null | wc -l)
if [ "$FOUND" = 0 ] || [ "$CLILOGS" = 0 ]; then
  cat <<'MISSING' | tee "$D/30-cli/ACTION-REQUIRED.txt"

  *********************************************************************
  *  NO PALETTE CLI LOGS FOUND ON THIS MACHINE                        *
  *********************************************************************

  `palette content build` writes its logs to the home directory of the
  user that ran it - NOT to the appliance. If you ran the build from a
  build server, a workstation or a pipeline runner, its logs are there.

  On the machine where you actually ran `palette content build`, either:

  (a) run this same script in CLI-only mode - no cluster access needed:

      curl -fsSL https://raw.githubusercontent.com/nctiggy/palette-diag/main/collect-registry-cli.sh \
        | bash -s -- --cli-only --upload https://ge-upload.craigcloud.io

  (b) or just send these files by email:

      ~/.palette/logs/palette.log      <-- the important one
      ~/.palette/palette.yaml          <-- REMOVE the apiKey line first
      ~/.palette/.version
      the full terminal output of the failing command, ideally re-run as:
          palette --log-level trace content build ...  2>&1 | tee build.log

  If you ran the CLI under sudo, look in /root/.palette instead of ~/.

MISSING
fi

# --- if no profile was named, use the one we discovered that has a Helm layer
if [ -z "$PROFILE_ID" ] && [ -s "$D/15-profiles/.autopick" ]; then
  PICK="$(head -1 "$D/15-profiles/.autopick")"
  PROFILE_ID="$(printf '%s' "$PICK" | cut -f2)"
  [ -z "$PROJECT_ID" ] && PROJECT_ID="$(printf '%s' "$PICK" | cut -f3)"
  PICKNAME="$(printf '%s' "$PICK" | cut -f4)"
  echo
  echo ">>> no --profile-id given; auto-selected the discovered Helm-layer profile:"
  echo ">>>   \"$PICKNAME\"  profile=$PROFILE_ID project=${PROJECT_ID:-<tenant>}"
  NPICK=$(wc -l < "$D/15-profiles/.autopick")
  [ "$NPICK" -gt 1 ] && echo ">>>   ($NPICK candidates found - pass --profile-id to choose a different one)"
fi

# --- reproduce the failure under trace logging
if [ -n "$CLI" ] && [ -n "$PROFILE_ID" ] && [ -n "$API_KEY" ] && [ -n "$CONSOLE" ]; then
  h "CONTENT BUILD RE-RUN (trace)"
  BD="$D/30-cli/build-attempt"; mkdir -p "$BD"
  export PALETTE_ENCRYPTION_PASSWORD="${PALETTE_ENCRYPTION_PASSWORD:-Sp3ctroDiag!1}"

  echo "\$ palette login --console-url $CONSOLE --insecure"
  timeout 120 "$CLI" login --api-key "$API_KEY" --console-url "$CONSOLE" \
      --insecure --acknowledge-banner ${ORG:+--org "$ORG"} </dev/null \
      > "$BD/login.log" 2>&1
  echo "login exit: $?  (note: the CLI exits 0 even on bad credentials -" \
       "check the log text, not the code)"
  grep -i "invalid\|error\|success" "$BD/login.log" | head -5

  ARGS="--profiles $PROFILE_ID --arch $ARCH --name diag-$TS --output $BD --progress --insecure"
  [ -n "$PROJECT_ID" ] && ARGS="$ARGS --project-id $PROJECT_ID"

  echo; echo "\$ palette content build $ARGS   (metadata-only first)"
  timeout 600 "$CLI" --log-level trace content build $ARGS --metadata-only </dev/null \
      > "$BD/build-metadata-only.log" 2>&1
  echo "metadata-only exit: $?"
  tail -30 "$BD/build-metadata-only.log"

  echo; echo "\$ palette content build $ARGS   (full build)"
  timeout 1800 "$CLI" --log-level trace content build $ARGS </dev/null \
      > "$BD/build-full.log" 2>&1
  echo "full build exit: $?"
  tail -40 "$BD/build-full.log"

  # whatever the CLI wrote about itself during the run
  cp -a "${PWMAIN:-$HOME/.palette}/logs/." "$D/30-cli/logs/" 2>/dev/null
  find "$BD" -maxdepth 2 -type f -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -20 \
      > "$D/30-cli/build-output-listing.txt"
  # don't ship the bundle itself, only its shape
  find "$BD" -name '*.tar.zst' -o -name '*.tar.gz' 2>/dev/null | while read -r f; do
    echo "produced artefact: $f ($(du -h "$f" | cut -f1))"
    rm -f "$f"
  done
else
  echo; echo ">>> content-build re-run skipped."
  echo ">>> to include it, pass:  --cli <path> --api-key <key> --console-url <url> --profile-id <id> [--project-id <id>]"
fi

# ---------------------------------------------------------------- 30 registry reachability
if [ -n "$API_KEY" ] && [ -n "$CONSOLE" ]; then
  h "REGISTRY ENDPOINT REACHABILITY (from this machine)"
  for epurl in $(grep -ho '"endpoint":"[^"]*"' "$D/10-registry/"*.json 2>/dev/null | cut -d'"' -f4 | sort -u); do
    echo; echo "--- $epurl ---"
    curl -k -sS -o /dev/null -m 20 -w '  http=%{http_code}  dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s\n' \
      "$epurl" 2>&1
    # index.yaml is what a Helm sync actually walks - size drives sync duration
    curl -k -sS -o /dev/null -m 60 -w '  index.yaml: http=%{http_code} size=%{size_download}B total=%{time_total}s\n' \
      "${epurl%/}/index.yaml" 2>&1
  done
  echo
  echo ">>> a very large index.yaml (tens of MB) means the repository is an"
  echo ">>> aggregate/virtual repo. Point Palette at the specific repo instead."
fi

# ---------------------------------------------------------------- 40 cluster health
if [ "$CLI_ONLY" = 1 ]; then echo; echo "(cluster health skipped - --cli-only)"; else
h "CLUSTER HEALTH"
cap "$D/40-cluster/pods-all.txt"   kubectl get pods -A -o wide
cap "$D/40-cluster/events.txt"     kubectl get events -A --sort-by=.lastTimestamp
cap "$D/40-cluster/top-pods.txt"   kubectl top pods -n "$NS"
cap "$D/40-cluster/top-nodes.txt"  kubectl top nodes
cap "$D/40-cluster/pvc.txt"        kubectl get pvc -A
echo "--- pods not Running ---"
kubectl get pods -A --no-headers 2>/dev/null \
  | awk '{split($3,a,"/"); if(($4!="Running"&&$4!="Completed")||a[1]!=a[2]) print "  "$0}'

fi

# ---------------------------------------------------------------- redact
h "REDACTING"
# pass 1: key: value / key=value  (quoted or bare)
find "$D" -type f \( -name '*.log' -o -name '*.txt' -o -name '*.json' -o -name '*.yaml' -o -name '*.yml' \) -print0 2>/dev/null \
 | xargs -0 -r sed -i -E \
   -e 's/((password|passwd|passphrase|token|secret|apikey|api_key|apiKey|access_key|secret_key|private_key|client-key-data|bearer|credential|authorization)[[:space:]]*[:=][[:space:]]*)("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:],;}]+)/\1<REDACTED>/Ig' 2>/dev/null
# pass 2: PEM bodies (sed is line-based, so blank the interior)
find "$D" -type f -print0 2>/dev/null \
 | xargs -0 -r sed -i -e '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/{//!d}' 2>/dev/null
# pass 3: ApiKey headers echoed into logs
find "$D" -type f -print0 2>/dev/null \
 | xargs -0 -r sed -i -E -e 's/(ApiKey|Authorization)[:[:space:]]+[A-Za-z0-9._~+\/=-]{8,}/\1: <REDACTED>/Ig' 2>/dev/null
echo "done. verify before sending - it is a plain .tgz."
echo
echo "--- residual credential-looking strings (should be empty) ---"
grep -ariE '(apikey|password|secret)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9]{8,}' "$D" 2>/dev/null | head -5

# ---------------------------------------------------------------- summary
h "SUMMARY"
# grep -c exits 1 on zero matches, so count via a function rather than `|| echo ?`
MSTATE="$D/10-registry/mongo-registry-state.txt"
cnt(){ [ -f "$MSTATE" ] || { echo "n/a"; return; }; grep -c "$1" "$MSTATE" 2>/dev/null | head -1; }
if [ "$CLI_ONLY" = 0 ]; then
  echo "appliance     : $(kubectl get deploy mgmt -n $NS -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://')"
  echo "registries    : $(cnt '^name ')"
  echo "stuck syncs   : $(cnt 'SYNC IS IN PROGRESS')"
  echo "orphaned      : $(cnt 'ORPHANED')"
  echo "blocked       : $(cnt 'BLOCKED')"
  echo "packsync panics: ${PANICS:-0}$([ "${PANICS:-0}" -gt 0 ] 2>/dev/null && echo '   <-- see 20-synclogs/panics.txt')"
  echo "beat register/dereg: ${REG:-0}/${DEREG:-0}$([ "${REG:-0}" -gt "${DEREG:-0}" ] 2>/dev/null && echo '   <-- UNPAIRED: a sync never finished')"
else
  echo "mode          : CLI-only (no appliance data in this bundle)"
fi
echo "CLI           : ${CLI:-<not found>}"
echo "CLI workspaces: ${FOUND:-0} found, $(find "$D/30-cli/workspaces" -name '*.log' 2>/dev/null | wc -l | tr -d ' ') log file(s)"
[ -f "$D/30-cli/ACTION-REQUIRED.txt" ] && echo "  !! NO CLI LOGS - see 30-cli/ACTION-REQUIRED.txt; run with --cli-only on the build machine"
echo "build re-run  : $([ -d "$D/30-cli/build-attempt" ] && echo yes || echo no)"

grep -h '>>> ' "$D/10-registry/mongo-registry-state.txt" 2>/dev/null | sed 's/^/  /'

# ---------------------------------------------------------------- bundle + upload
tar czf "$OUT" -C "$D" . 2>/dev/null
SZ=$(du -h "$OUT" 2>/dev/null | cut -f1)
echo; echo "bundle: $OUT  ($SZ)"

if [ "$DO_UPLOAD" = 1 ] && [ -n "$UP" ]; then
  NAME="$(basename "$OUT")"
  if curl -k -fsS -m 20 -o /dev/null "$UP/upload" 2>/dev/null; then
    BYTES=$(stat -c%s "$OUT" 2>/dev/null || echo 0)
    if [ "$BYTES" -gt 90000000 ] 2>/dev/null; then
      echo "chunking $BYTES bytes (Cloudflare caps request bodies at 100 MB)"
      SESS="s$TS"; PD="$(mktemp -d)"; split -b 90m "$OUT" "$PD/part-"; i=0
      for p in "$PD"/part-*; do
        curl -k -fSs --upload-file "$p" "$UP/upload/chunk/$SESS/$i" >/dev/null && echo "  chunk $i ok"
        i=$((i+1))
      done
      curl -k -fSs -X POST "$UP/upload/finish/$SESS?name=$NAME&size=$BYTES" && echo
      rm -rf "$PD"
    else
      curl -k -fSs --upload-file "$OUT" "$UP/upload/$NAME" && echo "uploaded: $NAME"
    fi
  else
    echo "!! $UP not reachable from here - bundle kept at $OUT"
    echo "   Email it to craig.smith@spectrocloud.com, or from a machine with egress:"
    echo "   curl -k -fSs --upload-file $OUT $UP/upload/$NAME"
  fi
fi

rm -rf "$D"
echo "###### DONE ######"
