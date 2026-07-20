# APT repo: xz repack + incremental deb-s3 pipeline

Date: 2026-07-21

## Problem

`sudo apt-get install bestool` fails on Debian 11 (bullseye):

```
dpkg-deb: error: archive '.../bestool_1.47.0_amd64.deb' uses unknown
compression for member 'control.tar.zst', giving up
```

zstd-compressed `.deb` members are only readable by dpkg ≥ 1.21.18 (Debian
bookworm+, backported on Ubuntu). bullseye's dpkg (1.20) cannot install them.

Two independent causes:

1. **Compression.** First-party tools (`bestool`, `algae`, `seedling`,
   `bestool-alertd`, `bestool-psql`) are built in their *own* repos and synced
   into this repo's APT pool from `s3://bes-ops-tools/{tool}/`. They arrive
   zstd-compressed. This repo never runs `dpkg-deb` on them, so PR #7 (which
   added `-Z xz` to the 11 build workflows here) does **not** fix them. The
   container tools it did fix are `gnu35` builds (glibc ≥ 2.35) that can't
   install on bullseye (glibc 2.31) regardless.

2. **Blind spot.** `apt-repo.yml`'s test jobs only exercise Ubuntu 24.04 and
   26.04 — both new enough to read zstd — so a zstd `.deb` ships green.

A secondary concern: the `generate-repo` job re-downloads the entire S3 pool,
re-scans, and re-signs on every run because runners are ephemeral (no local
cache). This is wasteful and grows linearly with the repo.

## Goals

- Every package served by the APT repo installs on old dpkg (predicate below).
- CI catches old-dpkg regressions before they ship.
- The repo-generation job stops doing O(whole-repo) work every run.

## Non-goals

- Changing the first-party build repos to emit xz. The pipeline repack is the
  permanent normalization mechanism; source repos are intentionally untouched
  so any future zstd-defaulting source is handled automatically.
- Preserving the per-file `gh attestation verify` match for repacked debs. The
  APT trust path is the GPG-signed `InRelease`/`Release` (which chains to the
  regenerated `Packages` hashes), not per-file attestations. Repacking changes
  the served bytes; re-signing keeps APT verification fully intact. The
  build-repo attestation still validly describes the original build artifact.

## Design

Three parts, landing together (see Sequencing).

### A. Compression normalization (repack)

A step in `generate-repo` normalizes each candidate `.deb` before indexing.

**Predicate (locked):** repack a `.deb` unless **all** of its `control.tar.*`
and `data.tar.*` members are already `.xz` or `.gz`. In practice this fires
only on zstd today, but it is forward-safe: any future non-safe codec is
normalized to xz automatically, whereas hardcoding "if zstd" would silently
ship the next surprise. gzip is deliberately left untouched — it is readable by
every relevant dpkg, so repacking it would be pure churn and needless byte
changes.

**Detection:** `ar t <deb>` lists members. If every `*.tar.*` suffix is in
`{xz, gz}`, pass the file through unchanged. Otherwise repack.

**Repack:** `dpkg-deb -R <deb> <tmpdir>` then
`dpkg-deb --root-owner-group -Z xz -b <tmpdir> <out.deb>`. The `-R`/`-b`
round-trip preserves maintainer scripts, conffiles, ownership, and control
metadata.

Rationale: gzip and xz are readable by every relevant dpkg; xz since dpkg 1.15
(2009). zstd is the only real-world offender, gated behind dpkg ≥ 1.21.18.

### B. Incremental publish via deb-s3

Replace the hand-rolled scan + `Release` + sign + `s3 sync --delete` with
`deb-s3` (the maintained `deb-s3/deb-s3` fork, pinned to `26.1.1`, installed via
`gem install deb-s3 -v 26.1.1`).

deb-s3 pulls the per-arch `Packages` manifest from S3, adds/replaces stanzas,
uploads only the new `.deb`s, regenerates `Packages` + `Packages.gz`, and
re-signs `Release`/`InRelease`. No local pool tree, no full re-scan.

**Bootstrap rebuild (one-time cutover).** The current pool is hand-rolled,
zstd, and laid out at `pool/$arch/$tool/` — paths deb-s3 does not own, so a
purely incremental switch would strand the old zstd entries in the manifest.
The cutover therefore does a full rebuild: download every source deb, repack,
and publish a fresh `dists/` + `pool/` via deb-s3. Gated behind a
`workflow_dispatch` boolean input `rebuild`. Before wiping, snapshot the
existing `apt/` prefix to `s3://bes-ops-tools/apt-backup-<runid>/` for rollback.

**Steady state (every subsequent run):**

1. `deb-s3 list` per arch → set of `(package, version, arch)` already published.
2. `aws s3 ls` the per-tool source prefixes with the **existing** filters:
   - Container tools (`aardvark-dns buildah crun krun libkrun libkrunfw
     netavark passt podman`): `*-<target>-unknown-linux-gnu35-*.deb` only.
   - Others (`caddy kopia bestool algae seedling`): `*-<target>-*.deb`.
   - `bestool-alertd`, `bestool-psql`: `*-<target>-*.deb`, excluding `latest/*`
     (unversioned duplicate copies).
   This is a cheap listing — no downloads.
3. Diff source listing against the published set to find debs not yet
   published. The published set from `deb-s3 list` is keyed by control
   `Package:` name, which can differ from the source directory name (e.g. dir
   `bestool-alertd`). The reliable join key is the source `.deb` filename
   itself: track which source object keys (or their S3 ETags) have already been
   ingested via a small marker object under `s3://bes-ops-tools/apt-state/`,
   rather than trying to reconstruct the control name from the path. New =
   source object not in the ingested-marker set.
4. Download only those, apply the repack predicate, then
   `deb-s3 upload --arch <arch> --preserve-versions --sign=<KEYID> --lock ...`
   (`--preserve-versions` reproduces today's `--multiversion` behaviour).

**deb-s3 invocation parameters:**

- `--bucket bes-ops-tools --prefix apt`
- `--s3-region ap-southeast-2`
- `--codename stable --suite stable --component main --origin "BES Tools"`
- `--arch amd64` / `--arch arm64` (run per arch)
- `--sign=${{ vars.GPG_KEY_ID }}`, with loopback pinentry passed via
  `--gpg-options` (matching the current batch/loopback signing).
- `--visibility public`
- `--lock` (belt-and-suspenders on top of the existing `concurrency` group).

**Kept:** `concurrency: apt-repo` group; CloudFront invalidation of `/apt/*`;
the `bes-tools.gpg.key` export; the `Package: *` pin instructions in README.

**Accepted losses (minor, confirmed):**

- The `.bz2` and `.xz` *index* variants of `Packages` are dropped. deb-s3 emits
  `Packages` + `Packages.gz`; every apt reads `.gz`.
- `Label` and `Description` `Release` fields are dropped (deb-s3 exposes
  `Origin`/`Suite`/`Codename`/`Component`, not `Label`/`Description`).

### C. Test matrix (regression guard)

Replace/extend the `test-repo*` jobs:

- **Keep** Ubuntu 24.04 native (amd64 + arm64) and Ubuntu 26.04 (container).
- **Add Debian 12 (bookworm)** container — glibc 2.36, so the **full** package
  set including container tools.
- **Add Debian 11 (bullseye)** container — glibc 2.31, so the **first-party
  subset only**: `bestool`, `bestool-psql`, `bestool-alertd`, `algae`,
  `seedling`. This job is the guard that would have caught the outage.

Each container job runs on the matching host arch (amd64 + arm64) as the
existing 26.04 job does. `seedling` is installed `--no-install-recommends`
(as today) to avoid the DKMS kernel-module dependency in the smoke test.

## Components / files

- `.github/workflows/apt-repo.yml` — major rewrite of the `generate-repo` job
  (5 steps → list-diff → download-new → repack → deb-s3 upload); add `rebuild`
  `workflow_dispatch` input; add bookworm + bullseye test jobs.
- A small repack helper (inline shell or a checked-in
  `scripts/repack-to-xz.sh`, ~15–25 lines) implementing the predicate.
- No changes to the 11 build workflows (already done in PR #7).

## Risks / rollback

- **Bootstrap correctness.** The full rebuild replaces the live repo. Mitigated
  by the `apt-backup-<runid>/` snapshot and by the old hand-rolled job remaining
  in git history to revert to.
- **deb-s3 Ruby dependency.** Pinned to `26.1.1`; installed per-run on the
  runner. Verify the pin resolves during planning.
- **Release field parity.** If `Label`/`Description` turn out to matter,
  post-process deb-s3's `Release` before signing (adds hand-rolled bits back);
  out of scope unless required.

## Sequencing

A and B ship together. B's bootstrap performs a full repack anyway, so shipping
A separately inside the current hand-rolled job would mean repacking the whole
repo twice. C ships in the same change so the guard exists the moment the fix
lands. PR #7 (build-workflow `-Z xz`) is already merged and independent.
