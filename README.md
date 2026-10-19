# crd2file

Print a running Traefik's configuration as **file-provider YAML**.

Traefik has already done the hard part: whatever you gave it (Kubernetes `Ingress`, `IngressRoute`,
Gateway API `HTTPRoute`, Docker labels, ...) is merged into one dynamic configuration, and it serves that at
`/api/rawdata`. `crd2file` reads it and tidies it into a file the file provider loads, so the same routers,
middlewares and services can run on a Traefik that has no Kubernetes behind it.

```sh
crd2file -b http://localhost:8080 --drop-internal-routes http://traefik.example:8080 > dynamic.yaml
```

A shell script: no build, no install. Copy `crd2file.sh` onto your `PATH`.

## Usage

```
crd2file [options] URL|FILE [SERVICE=BACKEND[,BACKEND]...] > dynamic.yaml
```

| | |
|---|---|
| `URL`, `FILE` | a Traefik API (`http://host:8080`) or a saved copy of its `/api/rawdata` |
| `-c`, `--context C` | also read what rawdata leaves out with `kubectl`: ServersTransports, TLSOptions, and the TLS certificates your routes use |
| `-b`, `--backend U` | point every HTTP service that is still on pod IPs at `U`, for example `http://localhost:8080` |
| `SERVICE=BACKEND` | point one service elsewhere, for example `demo-whoami-80=http://vm1:8080`. It wins over `-b`. TCP and UDP services only take this form, as `host:port` |
| `--drop-internal-routes` | leave out routers that use an internal service (`api@internal`, ...). Where the file lands they would switch the dashboard or the API on |
| `-h`, `--help` | the usage text |

The YAML goes to stdout. Warnings go to stderr, one per line, starting `crd2file:`:

```
crd2file: still on pod IPs: demo-whoami-80
crd2file: dropped router traefik-dashboard-d012b7f8: it uses an internal service
crd2file: dropped Secret fields of TLSOption demo/mtls
```

## Pod IPs

Kubernetes services resolve to pod IPs (`10.42.0.7:80`), which mean nothing anywhere else. Point them at
something that does: `-b` for all of them, `SERVICE=BACKEND` for one. Any service left on a pod IP is reported.

## Names

The provider is dropped from names, since everything is `@file` where this lands: `whoami@kubernetescrd`
becomes `whoami`. If two providers use the same name, both keep it as a suffix (`whoami-kubernetescrd`,
`whoami-file`), and every reference is renamed to match.

## What comes across, and what doesn't

Only **dynamic** configuration: routers, middlewares, services, TLS options and ServersTransports.

**Static** configuration does not, because Traefik does not serve it: entrypoints, providers, certificate
resolvers, the licence. A route that needs something static (the `websecure` entrypoint, a `certResolver`)
still loads, but the target Traefik disables it unless you configure the same thing there. Know which of your
configuration is static before you move it.

## Getting the API out of Traefik

`/api/rawdata` is part of Traefik's API. It is off by default in many installs, and it has no
authentication: **do not expose it beyond a trusted network.** With the Helm chart:

```yaml
ingressRoute:
  dashboard:
    enabled: true          # a router for api@internal on the "traefik" entrypoint
ports:
  traefik:
    expose:
      default: true        # publish that entrypoint (8080 in the pod) on the Service
    exposedPort: 8082
```

Or reach it without exposing anything: `kubectl -n traefik port-forward deploy/traefik 8080:8080`, with the
same `ingressRoute` setting, then `crd2file http://localhost:8080`.

## Security

- `-c` reads TLS Secrets and writes the certificate **and its private key** into the output, inline. Treat the
  file like a Secret, and do not commit it.
- Secret references in TLSOptions and ServersTransports are dropped, with a warning.
- Middleware settings that Traefik has already resolved (for example `basicAuth` users from a Secret) are in the
  rawdata, and so in the output.

## Requirements

`sh`, [`jq`](https://jqlang.org), [`yq`](https://github.com/mikefarah/yq) (mikefarah, v4) and `curl`.
`kubectl` for `-c`.

Developed against Traefik Hub v3.21 on k3d. It reads Traefik's rawdata format, so other Traefik v3 versions
should work, but that is not tested.

## Tests

```sh
./test/run.sh
```

The tests run against a saved `/api/rawdata` (`test/fixtures/rawdata.json`), so they need no cluster. Most
expectations are worked out from the fixture, but a few name what it holds: routers from the file, Kubernetes
Ingress, IngressRoute and Gateway API providers, a `demo-add-headers-ingress` middleware and one router that
uses `api@internal`. A refreshed fixture needs those, or the tests need adjusting. The `-c` path needs a
cluster and is not covered.

## License

MIT, see [LICENSE](LICENSE).
