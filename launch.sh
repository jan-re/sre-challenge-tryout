#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

IMAGE_TAG=0.1.0
APPS="front back reader"
FRONT_PORT=18080
READER_PORT=18084
STEP=0
PF_PIDS=""

log() { printf '[%s] [step %s/7] %s\n' "$(date +%H:%M:%S)" "$STEP" "$*"; }
fail() { printf '[%s] [step %s/7] ERROR: %s\n' "$(date +%H:%M:%S)" "$STEP" "$1" >&2; exit "${2:-2}"; }

on_exit() {
  local rc=$?
  [ -n "$PF_PIDS" ] && kill $PF_PIDS 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then
    printf '[%s] launch aborted in step %s with exit code %s\n' "$(date +%H:%M:%S)" "$STEP" "$rc" >&2
  fi
}
trap on_exit EXIT

wait_for() {
  local timeout=$1 ns=$2 resource=$3 condition=$4
  local start now elapsed
  start=$(date +%s)
  until $K -n "$ns" wait "$resource" --for="$condition" --timeout=10s >/dev/null 2>&1; do
    now=$(date +%s); elapsed=$((now - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      log "timed out after ${elapsed}s waiting for $resource to be $condition in namespace $ns"
      $K -n "$ns" get pods 2>/dev/null || true
      $K -n "$ns" describe "$resource" 2>/dev/null | tail -25 || true
      $K -n "$ns" get events --sort-by=.lastTimestamp 2>/dev/null | tail -15 || true
      fail "gave up waiting for $resource"
    fi
    log "waiting for $resource to be $condition (${elapsed}s of ${timeout}s); pods in $ns:"
    $K -n "$ns" get pods --no-headers 2>/dev/null | awk '{printf "    %-45s %-20s restarts=%s\n", $1, $3, $4}' || true
    sleep 5
  done
  log "$resource is $condition"
}

CLUSTER="${1:-}"
if [ -z "$CLUSTER" ]; then
  printf 'Name for the new k3d cluster: '
  read -r CLUSTER
fi
REGISTRY_PORT="${2:-}"
if [ -z "$REGISTRY_PORT" ]; then
  printf 'Host port for the image registry: '
  read -r REGISTRY_PORT
fi
case "$CLUSTER" in
  "" ) fail "cluster name must not be empty" 1 ;;
  *[!a-z0-9-]* | -* ) fail "cluster name must match ^[a-z0-9][a-z0-9-]*$" 1 ;;
esac
CONTEXT="k3d-$CLUSTER"
REGISTRY_NAME="$CLUSTER-registry"
REGISTRY_HOST="localhost:$REGISTRY_PORT"
REGISTRY_IN_CLUSTER="$REGISTRY_NAME:$REGISTRY_PORT"
K="kubectl --context $CONTEXT"
H="helm --kube-context $CONTEXT"

STEP=0
log "checking dependencies"
problems=""
problem() { problems="$problems"$'\n'"  - $*"; }

for tool in docker k3d kubectl helm git curl; do
  command -v "$tool" >/dev/null 2>&1 || problem "$tool not found on PATH"
done

if command -v k3d >/dev/null 2>&1 && k3d cluster get "$CLUSTER" >/dev/null 2>&1; then
  problem "k3d cluster '$CLUSTER' already exists; remove it with: k3d cluster delete $CLUSTER"
fi

if [ -n "${JAVA_HOME:-}" ]; then
  JAVA_BIN="$JAVA_HOME/bin/java"
else
  JAVA_BIN=$(command -v java || true)
fi
if [ -z "$JAVA_BIN" ] || [ ! -x "$JAVA_BIN" ]; then
  problem "java not found; set JAVA_HOME or put java on PATH"
else
  log "java at $JAVA_BIN"
fi

[ -x sre-challenge/gradlew ] || problem "sre-challenge/gradlew missing; run: git clone https://github.com/kaktooss/sre-challenge sre-challenge"
for d in helm/strimzi-kafka-operator helm/cloudnative-pg helm/kafka-cluster helm/sre-challenge; do
  [ -e "$d" ] || problem "$d missing"
done

if [ -n "$problems" ]; then
  fail "dependency check failed:$problems" 1
fi
log "all dependencies present (required versions are listed in notes/how-to.md)"

STEP=1
log "building jars with Gradle (first run downloads Gradle and dependencies)"
(cd sre-challenge && JAVA_HOME="$(dirname "$(dirname "$JAVA_BIN")")" ./gradlew clean build -q)
for a in $APPS; do
  jar="sre-challenge/app/$a/build/libs/$a-$IMAGE_TAG.jar"
  [ -f "$jar" ] || fail "expected jar not found: $jar"
  log "built $jar"
done
for a in $APPS; do
  log "building image $REGISTRY_HOST/sre-challenge/$a:$IMAGE_TAG"
  docker build -q -f "sre-challenge/app/$a/src/main/docker/Dockerfile" \
    -t "$REGISTRY_HOST/sre-challenge/$a:$IMAGE_TAG" "sre-challenge/app/$a/build/libs"
done
log "artifacts built"

STEP=2
log "creating k3d cluster '$CLUSTER' with registry $REGISTRY_NAME on $REGISTRY_HOST"
k3d cluster create "$CLUSTER" --servers 1 --agents 1 --registry-create "$REGISTRY_NAME:0.0.0.0:$REGISTRY_PORT"
wait_for 120 kube-system node/k3d-$CLUSTER-server-0 condition=Ready
wait_for 120 kube-system node/k3d-$CLUSTER-agent-0 condition=Ready
for a in $APPS; do
  log "pushing $REGISTRY_HOST/sre-challenge/$a:$IMAGE_TAG"
  docker push -q "$REGISTRY_HOST/sre-challenge/$a:$IMAGE_TAG"
done
catalog=$(curl -fsS "http://$REGISTRY_HOST/v2/_catalog")
for a in $APPS; do
  case "$catalog" in *"sre-challenge/$a"*) ;; *) fail "image sre-challenge/$a missing from registry catalog: $catalog" ;; esac
done
log "cluster up, images in registry: $catalog"

STEP=3
log "installing Strimzi operator into namespace kafka"
$K create namespace kafka
$K create namespace postgres
$H install strimzi ./helm/strimzi-kafka-operator -n kafka
wait_for 180 kafka deploy/strimzi-cluster-operator condition=Available
log "installing CloudNativePG operator into namespace postgres"
$H install cnpg ./helm/cloudnative-pg -n postgres
wait_for 180 postgres deploy/cnpg-cloudnative-pg condition=Available
log "operators installed"

STEP=4
log "installing Kafka cluster chart into namespace kafka"
$H install kafka ./helm/kafka-cluster -n kafka
log "Kafka cluster requested (PostgreSQL cluster and topic are part of the app chart)"

STEP=5
log "waiting for Kafka to become ready"
wait_for 300 kafka kafka/kafka condition=Ready
log "infrastructure ready"

STEP=6
log "deploying sre-challenge chart into namespace sre-challenge (image registry $REGISTRY_IN_CLUSTER)"
$H install sre-challenge ./helm/sre-challenge -n sre-challenge --create-namespace \
  --set "image.registry=$REGISTRY_IN_CLUSTER"
wait_for 120 kafka kafkatopic/test-command condition=Ready
wait_for 300 sre-challenge cluster/sre-challenge-db condition=Ready
for a in $APPS; do
  wait_for 300 sre-challenge deploy/sre-challenge-$a condition=Available
done
$K -n sre-challenge get pods
log "application deployed"

STEP=7
log "validating: posting a command through front and reading it back through reader"
$K -n sre-challenge port-forward svc/sre-challenge-front "$FRONT_PORT:8080" >/dev/null 2>&1 &
PF_PIDS="$!"
$K -n sre-challenge port-forward svc/sre-challenge-reader "$READER_PORT:8084" >/dev/null 2>&1 &
PF_PIDS="$PF_PIDS $!"
sleep 3
marker="launch-$(date +%s)"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://localhost:$FRONT_PORT/api/v1/command" \
  -H 'Content-Type: application/json' -d "{\"message\":\"$marker\"}")
[ "$code" = "200" ] || fail "POST /api/v1/command returned HTTP $code"
log "front accepted message '$marker'"
found=""
for _ in $(seq 1 30); do
  body=$(curl -s "http://localhost:$READER_PORT/api/v1/testEntity?size=50" || true)
  case "$body" in *"$marker"*) found=1; break ;; esac
  sleep 2
done
[ -n "$found" ] || fail "message '$marker' did not show up in reader within 60s"
log "reader returned the message: $body"

printf '\nlaunch complete\n'
printf '  kube context : %s\n' "$CONTEXT"
printf '  helm releases: strimzi, kafka (ns kafka); cnpg (ns postgres); sre-challenge (ns sre-challenge)\n'
printf '  front  : kubectl --context %s -n sre-challenge port-forward svc/sre-challenge-front %s:8080\n' "$CONTEXT" "$FRONT_PORT"
printf '  reader : kubectl --context %s -n sre-challenge port-forward svc/sre-challenge-reader %s:8084\n' "$CONTEXT" "$READER_PORT"
printf '  teardown: k3d cluster delete %s\n' "$CLUSTER"
