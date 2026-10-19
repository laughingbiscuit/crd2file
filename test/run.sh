#!/bin/sh
# Tests for crd2file, against a saved /api/rawdata (test/fixtures/rawdata.json): no cluster, no network.
# Needs jq and yq, like crd2file itself.   ./test/run.sh
set -u
cd "$(dirname "$0")/.."
crd2file=./crd2file.sh
raw=test/fixtures/rawdata.json
backend=http://backend.test:9000
fails=0

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; fails=$((fails+1)); }
expect() {   # <name> <got> <want>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got '$2', want '$3'"; fi
}

out=$(mktemp) err=$(mktemp)
trap 'rm -f "$out" "$err"' EXIT
run() { "$crd2file" "$@" > "$out" 2> "$err"; }   # sets $? and fills $out and $err
j() { yq -o json '.' "$out" | jq "$@"; }          # query the YAML output with jq

echo "crd2file"

# --- the default conversion ---------------------------------------------------------------------------------------
run $raw; rc=$?
expect "exits 0" "$rc" 0
expect "output is YAML with http.routers" "$(j -r '.http.routers | type')" "object"

want=$(jq '[.routers | keys[] | select(endswith("@internal") | not)] | length' $raw)
expect "keeps every router that is not internal ($want)" "$(j '.http.routers | length')" "$want"

expect "keeps routers from all providers" \
  "$(jq -r '[.routers | keys[] | select(endswith("@internal") | not) | split("@")[1]] | unique | join(",")' $raw)" \
  "file,kubernetes,kubernetescrd,kubernetesgateway"

expect "strips the provider from names" "$(j '[.http.routers, .http.middlewares, .http.services | keys[] | select(test("@"))] | length')" 0

expect "keeps a middleware's settings" "$(j -r '.http.middlewares["demo-add-headers-ingress"].headers.customResponseHeaders["X-Demo-Route"]')" "ingress"

expect "leaves pod IPs alone, and warns" "$(grep -c 'still on pod IPs' $err | tr -d ' ')" "$(j '[.http.services[] | select(.loadBalancer.servers)] | length')"

# --- -b / --backend -----------------------------------------------------------------------------------------------
run -b $backend $raw
expect "-b: every service with servers points at the backend" \
  "$(j -c '[.http.services[] | select(.loadBalancer.servers) | .loadBalancer.servers[].url] | unique')" "[\"$backend\"]"
expect "-b: no 'still on pod IPs' warning" "$(grep -c 'still on pod IPs' $err | tr -d ' ')" 0
expect "-b: keeps the rest of the service" "$(j '[.http.services[] | select(.loadBalancer.servers) | .loadBalancer.passHostHeader] | unique | .[0]')" "true"

run $raw; first=$(j -r '[.http.services | to_entries[] | select(.value.loadBalancer.servers) | .key] | .[0]')
run -b $backend $raw "$first=http://one.test:1"
expect "SERVICE=BACKEND wins over -b" "$(j -r --arg s "$first" '.http.services[$s].loadBalancer.servers[0].url')" "http://one.test:1"
expect "SERVICE=BACKEND leaves the others on -b" \
  "$(j -c --arg s "$first" '[.http.services | to_entries[] | select(.key != $s) | select(.value.loadBalancer.servers) | .value.loadBalancer.servers[].url] | unique')" "[\"$backend\"]"

# --- --drop-internal-routes ---------------------------------------------------------------------------------------
run $raw
expect "default keeps a router that uses api@internal" "$(j '[.http.routers[] | select(.service == "api@internal")] | length')" 1
run --drop-internal-routes $raw
expect "--drop-internal-routes removes it" "$(j '[.http.routers[] | select(.service == "api@internal")] | length')" 0
expect "--drop-internal-routes says what it dropped" "$(grep -c 'dropped router' $err | tr -d ' ')" 1
want=$(jq '[.routers | keys[] | select(endswith("@internal") | not)] | length' $raw)
expect "--drop-internal-routes keeps the other routers" "$(j '.http.routers | length')" "$((want - 1))"

# --- mistakes -----------------------------------------------------------------------------------------------------
run $raw no-such-service=http://x.test; rc=$?
expect "an unknown service name fails" "$rc" 5
expect "...and names it" "$(grep -c 'no-such-service' $err | tr -d ' ')" 1

run --nope $raw; rc=$?
expect "an unknown option exits 2" "$rc" 2

run; rc=$?
expect "no arguments exits 2 with usage" "$rc:$(grep -c 'crd2file \[options\]' $err | tr -d ' ')" "2:1"

run --help; rc=$?
expect "--help exits 0 and prints usage" "$rc:$(grep -c 'crd2file \[options\]' $out | tr -d ' ')" "0:1"

echo
if [ $fails -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
