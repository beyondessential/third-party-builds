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

### APT repository

We provide a custom APT repository for our tools, including these.

```bash
curl -fsSL https://tools.ops.tamanu.io/apt/bes-tools.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/bes-tools.gpg
echo "deb [signed-by=/etc/apt/keyrings/bes-tools.gpg] https://tools.ops.tamanu.io/apt stable main" | sudo tee /etc/apt/sources.list.d/bes-tools.list
sudo tee /etc/apt/preferences.d/bes-tools <<EOF
Package: *
Pin: origin tools.ops.tamanu.io
Pin-Priority: 999
EOF

sudo apt-get update
sudo apt-get install aardvark-dns buildah caddy crun kopia netavark passt podman
```

## Builds

### [Aardvark DNS](./.github/workflows/aardvark-dns.yml)

- Upstream: <https://github.com/containers/aardvark-dns>
- Targets: Linux (x64 and ARM64)
- Package: tar.zst and .deb
- APT: Available in repository

Reason: .deb packaging for a newer version (Ubuntu 24.04 ships with 1.4.0) with performance fixes.

```
https://tools.ops.tamanu.io/aardvark-dns/{version}/aardvark-dns-{target}-{version}.tar.zst
https://tools.ops.tamanu.io/aardvark-dns/{version}/aardvark-dns-{target}-{version}.deb
```

### [Caddy](./.github/workflows/caddy.yml)

- Upstream: <https://caddyserver.com>
- Targets: Linux (x64 and ARM64), Windows, macOS (Intel and ARM64)
- Package: .deb (Linux only), raw executable (all platforms)
- APT: Available in repository

Reason: includes the [Route53 DNS](https://github.com/caddy-dns/route53) and other plugins.

```
https://tools.ops.tamanu.io/caddy/{version}/caddy-{target}
https://tools.ops.tamanu.io/caddy/{version}/caddy-{target}-{version}.deb
https://tools.ops.tamanu.io/caddy/latest/caddy-{target}
```

### [Buildah](./.github/workflows/buildah.yml)

- Upstream: <https://github.com/containers/buildah>
- Targets: Linux (x64 and ARM64)
- Package: tar.zst and .deb
- APT: Available in repository

Reason: `podman build` delegates to buildah's logic, and Ubuntu LTS ships versions significantly behind upstream. Matched to our podman build.

```
https://tools.ops.tamanu.io/buildah/{version}/buildah-{target}-{version}.tar.zst
https://tools.ops.tamanu.io/buildah/{version}/buildah-{target}-{version}.deb
```

### [crun](./.github/workflows/crun.yml)

- Upstream: <https://github.com/containers/crun>
- Targets: Linux (x64 and ARM64)
- Package: tar.zst and .deb
- APT: Available in repository

Reason: .deb packaging for a version compatible with Podman 5.

```
https://tools.ops.tamanu.io/crun/{version}/crun-{target}-{version}.tar.zst
https://tools.ops.tamanu.io/crun/{version}/crun-{target}-{version}.deb
```

### [Kopia](./.github/workflows/kopia.yml)

- Upstream: <https://kopia.io>
- Targets: Linux (x64 and ARM64)
- Package: .deb
- APT: Available in repository

Reason: we build the lean version (no UI) and include a kopia system user/group/home.

```
https://tools.ops.tamanu.io/kopia/{version}/kopia-{target}-{version}.deb
```

### [Podman](./.github/workflows/podman.yml)

- Upstream: <https://github.com/containers/podman>
- Targets: Linux (x64 and ARM64)
- Package: tar.zst and .deb
- APT: Available in repository

Reason: upstream doesn't provide builds.

```
https://tools.ops.tamanu.io/podman/{version}/podman-{target}-{version}.tar.zst
https://tools.ops.tamanu.io/podman/{version}/podman-{target}-{version}.deb
```

### [libkrunfw](./.github/workflows/libkrunfw.yml) / [libkrun](./.github/workflows/libkrun.yml) / [krun](./.github/workflows/krun.yml)

- Upstream: <https://github.com/containers/libkrunfw>, <https://github.com/containers/libkrun>, <https://github.com/containers/crun>
- Targets: Linux (x64 and ARM64), KVM hosts only
- Package: .deb (each)
- APT: Available in repository

Reason: the libkrun stack is not packaged by Ubuntu or Debian at all. Allows `podman --runtime krun` for KVM-based microVM isolation.

```
https://tools.ops.tamanu.io/libkrunfw/{version}/libkrunfw-{target}-{version}.deb
https://tools.ops.tamanu.io/libkrun/{version}/libkrun-{target}-{version}.deb
https://tools.ops.tamanu.io/krun/{version}/krun-{target}-{version}.deb
```

### [passt](./.github/workflows/passt.yml)

- Upstream: <https://passt.top>
- Targets: Linux (x64 and ARM64)
- Package: tar.zst and .deb
- APT: Available in repository

Reason: `pasta` (provided by the passt package) is the default rootless network backend for podman 5. The project ships date-tagged snapshots and develops rapidly, so distro packages lag meaningfully behind upstream.

```
https://tools.ops.tamanu.io/passt/{version}/passt-{target}-{version}.tar.zst
https://tools.ops.tamanu.io/passt/{version}/passt-{target}-{version}.deb
```

### [Netavark](./.github/workflows/netavark.yml)

- Upstream: <https://github.com/containers/netavark>
- Targets: Linux (x64 and ARM64)
- Package: tar.zst and .deb
- APT: Available in repository

Reason: .deb packaging for a version compatible with Podman 5.

```
https://tools.ops.tamanu.io/netavark/{version}/netavark-{target}-{version}.tar.zst
https://tools.ops.tamanu.io/netavark/{version}/netavark-{target}-{version}.deb
```
