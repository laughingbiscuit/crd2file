#!/bin/sh
# crd2file: print a running Traefik's dynamic config as file-provider YAML.
# Traefik has already translated Ingress, IngressRoute, HTTPRoute and the rest into one dynamic
# configuration: we read it from /api/rawdata and tidy it into something the file provider loads.
#
#   crd2file [options] URL|FILE [SERVICE=BACKEND[,BACKEND]...] > dynamic.yaml
#
#   URL|FILE         a Traefik API (http://host:8080) or a saved copy of its /api/rawdata
#   -c, --context C  also read what rawdata lacks with kubectl: ServersTransports,
#                    TLSOptions and the TLS certificates routes use (inlined as PEM)
#   -b, --backend U  point every HTTP service still on pod IPs at U, e.g. http://localhost:8080
#   SERVICE=BACKEND  point one service elsewhere, e.g. demo-whoami-80=http://vm1:8080; wins over -b
#                    (TCP and UDP services only take this form, as host:port)
#   --drop-internal-routes
#                    leave out routers that use an internal service (api@internal, ...): where
#                    the config lands they would switch the dashboard or API on
#   -h, --help       this text
#
# Needs jq, curl and yq (mikefarah, v4); kubectl for -c. Warnings go to stderr, YAML to stdout.
set -eu

usage() { sed -n '2,/^# Needs/p' "$0" | sed 's/^# \{0,1\}//'; }

ctx= backend= drop=false
while [ $# -gt 0 ]; do
  case $1 in
    -c|--context) ctx=${2:?crd2file: $1 needs a value}; shift 2 ;;
    -b|--backend) backend=${2:?crd2file: $1 needs a value}; shift 2 ;;
    --drop-internal-routes) drop=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "crd2file: unknown option $1 (see --help)" >&2; exit 2 ;;
    *) break ;;
  esac
done
src=${1:-}
[ -n "$src" ] || { usage >&2; exit 2; }
shift

case $src in
http*) raw=$(curl -fsS "${src%/}/api/rawdata") ;;
*) raw=$(cat "$src") ;;
esac

backends=$(printf '%s\n' "$@" | jq -Rn '
  [inputs | select(length > 0) | capture("^(?<key>[^=]+)=(?<value>.+)$") | .value |= split(",")] | from_entries')

k8s='{"items": []}' certs='{"items": []}'
if [ -n "$ctx" ]; then
  k8s=$(kubectl --context "$ctx" get -A -o json serverstransports.traefik.io,serverstransporttcps.traefik.io,tlsoptions.traefik.io,ingressroutes.traefik.io,ingresses)
  certs=$(kubectl --context "$ctx" get -A -o json secrets --field-selector type=kubernetes.io/tls)
fi

json=$(printf '%s' "$raw" | jq --argjson b "$backends" --arg backend "$backend" --argjson drop "$drop" --argjson k8s "$k8s" --argjson certs "$certs" '
  # "tcpRouters" -> ["tcp", "routers"], "routers" -> ["http", "routers"]
  def section: capture("^(?<p>tcp|udp)?(?<k>.+)") | [.p // "http", (.k[:1] | ascii_downcase) + .k[1:]];
  def where: {ServersTransport: ["http", "serversTransports"],
              ServersTransportTCP: ["tcp", "serversTransports"], TLSOption: ["tls", "options"]}[.kind];
  def nosecrets: delpaths([paths | select(.[-1] | tostring | test("[Ss]ecret"))]);

  [to_entries[] | .key as $s | .value | objects | to_entries[]
   | (.key | split("@")) as [$n, $p] | select($p != "internal") | {s: $s, k: .key, $n, $p, v: .value}] as $all
  | ($all | map({key: .k}) | from_entries) as $keys
  | ($all | map({key: .p}) | from_entries) as $providers
  # Names that two providers both use keep the provider: x@kubernetes -> x-kubernetes.
  | ($all | group_by(.n) | map(select(map(.p) | unique | length > 1) | {key: .[0].n}) | from_entries) as $clash
  # Same-provider references omit the suffix; add it so every reference is renamed alike.
  | def qualify($p): walk(if type == "string" and ("\(.)@\($p)" | in($keys)) then "\(.)@\($p)" else . end);
    def rename: walk(if type == "string" then
        (capture("^(?<n>.+)@(?<p>[a-z]+)$") // {}) as $m
        | if ($m.p // "" | in($providers) | not) then . elif ($m.n | in($clash)) then "\($m.n)-\($m.p)" else $m.n end
      else . end);

  reduce $all[] as $o ({};
    ($o.k | rename) as $name
    | setpath($o.s | section + [$name];
        $o.v | del(.status, .error, .using, .usedBy, .serverStatus, .observability.metadata)
        | qualify($o.p) | rename
        | if $b[$name] and ($o.s | endswith("ervices")) then .loadBalancer.servers = [$b[$name][] | if $o.s == "services" then {url: .} else {address: .} end]
          elif $backend != "" and $o.s == "services" and .loadBalancer.servers then .loadBalancer.servers = [{url: $backend}]
          else . end))

  # Same names as the CRD provider gives them.
  | reduce ($k8s.items[] | select(where)) as $i (.;
      setpath($i | where + [if $i.metadata.name == "default" then "default" else "\($i.metadata.namespace)-\($i.metadata.name)" end];
        $i.spec | nosecrets))

  # Certificates named by IngressRoutes (spec.tls.secretName) and Ingresses (spec.tls[].secretName).
  | ([$k8s.items[] | .metadata.namespace as $ns | [.spec.tls | .. | .secretName? | strings][] | "\($ns)/\(.)"]) as $used
  | ([$certs.items[] | select(IN("\(.metadata.namespace)/\(.metadata.name)"; $used[]))
      | {certFile: (.data["tls.crt"] | @base64d), keyFile: (.data["tls.key"] | @base64d)}]) as $pem
  | if $pem == [] then . else .tls.certificates = $pem end

  # A router that uses an internal service (api@internal, ...) would switch it on where the config lands.
  | (if $drop then [("http", "tcp", "udp") as $t | ((.[$t] // {}) | .routers // {}) | to_entries[]
                    | select((.value.service // "") | endswith("@internal")) | {t: $t, n: .key}] else [] end) as $dropped
  | reduce $dropped[] as $d (.; delpaths([[$d.t, "routers", $d.n]]))

  | ([.http.services, .tcp.services, .udp.services | objects | keys[]]) as $names
  | ($b | keys - $names) as $typos
  | if $typos == [] then . else error("unknown services: \($typos | join(", "))") end
  | {config: .,
     warnings: ([(if $backend == "" then .http.services else null end), .tcp.services, .udp.services | objects | to_entries[]
                 | select(.value.loadBalancer.servers and (.key | in($b) | not)) | "still on pod IPs: \(.key)"]
               + ($dropped | map("dropped router \(.n): it uses an internal service"))
               + [$k8s.items[] | select(where) | select(.spec != (.spec | nosecrets))
                  | "dropped Secret fields of \(.kind) \(.metadata.namespace)/\(.metadata.name)"])}
')

printf '%s' "$json" | jq -r '.warnings[] | "crd2file: " + .' >&2
printf '%s' "$json" | jq '.config' | yq -p json -o yaml

