This repository contains GitHub Actions workflows that build third-party software for BES' use.

## Generalities

### URL format

Builds are pushed to a CDN, with a scheme that roughly always goes:

```
https://tools.ops.tamanu.io/{name}/{version}/{name}-{target}.{extension}
```

Some builds have a `latest` URL to always obtain the latest version.

### Targets

The `{target}` is the Rust-style target triple:

- `x86_64-unknown-linux-gnu` for Linux (x64)
- `aarch64-unknown-linux-gnu` for Linux (ARM64)
- `x86_64-pc-windows-gnu` for Windows
- `x86_64-apple-darwin` for macOS (Intel)
- `aarch64-apple-darwin` for macOS (Apple Silicon)

This is both to provide a consistent scheme between various different build systems, and because that makes it easy to use the [detect-targets](http://docs.rs/detect-targets) crate in tooling that downloads these builds.

### Attestations

These builds are signed with [Artifact Attestations](https://docs.github.com/en/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds), so that integrity and provenance can be tested with:

```console
gh attestation verify path/to/file -R beyondessential/third-party-builds
```

### Reliability

These builds are expressely for BES' purposes, and no guarantees are made beyond this.

Notably, builds may disappear or change at any moment without notice.

## Builds

### [Caddy](./.github/workflows/caddy.yml)

- Upstream: <https://caddyserver.com>
- Targets: Linux (x64 and ARM64), Windows, macOS (Intel and ARM64)
- Package: none (raw executable)

Reason: includes the [Route53 DNS plugin](https://github.com/caddy-dns/route53).

```
https://tools.ops.tamanu.io/caddy/{version}/caddy-{target}
https://tools.ops.tamanu.io/caddy/latest/caddy-{target}
```

### [crun](./.github/workflows/crun.yml)

- Upstream: <https://github.com/containers/crun>
- Targets: Linux (x64 and ARM64)
- Package: tar.zst and .deb

Reason: .deb packaging for a version compatible with Podman 5.

```
https://tools.ops.tamanu.io/crun/{version}/crun-{target}-{version}.tar.zst
https://tools.ops.tamanu.io/crun/{version}/crun-{target}-{version}.deb
```

### [Podman](./.github/workflows/podman.yml)

- Upstream: <https://github.com/containers/podman>
- Targets: Linux (x64 and ARM64)
- Package: tar.zst and .deb

Reason: upstream doesn't provide builds.

```
https://tools.ops.tamanu.io/podman/{version}/podman-{target}-{version}.tar.zst
https://tools.ops.tamanu.io/podman/{version}/podman-{target}-{version}.deb
```

### [Netavark](./.github/workflows/netavark.yml)

- Upstream: <https://github.com/containers/netavark>
- Targets: Linux (x64 and ARM64)
- Package: tar.zst and .deb

Reason: .deb packaging for a version compatible with Podman 5.

```
https://tools.ops.tamanu.io/netavark/{version}/netavark-{target}-{version}.tar.zst
https://tools.ops.tamanu.io/netavark/{version}/netavark-{target}-{version}.deb
```

### [OpenTelemetry Collector](./.github/workflows/otelcol.yml)

- Upstream: <https://opentelemetry.io/docs/collector/>
- Targets: Linux (x64 and ARM64), Windows, macOS (Intel and ARM64)
- Package: none (raw executable)

Reason: we need file storage for our collector, and the AWS auth extension.

```
https://tools.ops.tamanu.io/otelcol/{version}/otelcol-{target}-{version}
https://tools.ops.tamanu.io/otelcol/{version}/otelcol-{target}-{version}.exe
```
