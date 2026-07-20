# APT repo: xz repack + incremental deb-s3 pipeline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every package served by the BES APT repo installable on old dpkg (Debian 11), and make the repo-generation job incremental instead of rebuilding the whole repo each run.

**Architecture:** A repack helper normalises any non-xz/gz `.deb` to xz before indexing. The `generate-repo` job is rewritten around `deb-s3`, which maintains the per-arch manifest in S3 and uploads only new packages. A one-time gated bootstrap rebuilds the existing (zstd, hand-rolled) repo through the new path. Two new container smoke-test jobs (Debian 11 + 12) guard against old-dpkg regressions.

**Tech Stack:** GitHub Actions, bash, `dpkg-deb`/`binutils` (`ar`), `deb-s3` (Ruby gem, pinned `26.1.1`), AWS S3 (`bes-ops-tools` bucket), CloudFront.

## Global Constraints

- Served `.deb` members must be `xz` or `gz` only — never `zstd` (old dpkg on Debian 11 / dpkg 1.20 cannot read zstd).
- Repack predicate: repack unless **all** `control.tar.*`/`data.tar.*` members are already `.xz` or `.gz`; leave gzip untouched (safe everywhere, repacking is pure churn).
- `deb-s3` pinned to version `26.1.1` (maintained `deb-s3/deb-s3` fork).
- Public sources line must stay valid: `deb [signed-by=…] https://tools.ops.tamanu.io/apt stable main` → codename `stable`, component `main`.
- Repo lives at bucket `bes-ops-tools`, prefix `apt`, region `ap-southeast-2`.
- GPG signing uses key id `${{ vars.GPG_KEY_ID }}` (passphraseless, loopback pinentry), private key from `${{ secrets.GPG_PRIVATE_KEY }}`.
- Source-deb filters (unchanged from today):
  - Container tools (`aardvark-dns buildah crun krun libkrun libkrunfw netavark passt podman`): `*-<target>-unknown-linux-gnu35-*.deb` only.
  - Others (`caddy kopia bestool algae seedling`): `*-<target>-*.deb`.
  - `bestool-alertd`, `bestool-psql`: `*-<target>-*.deb`, excluding `latest/*`.
  - arch↔target map: `amd64`↔`x86_64`, `arm64`↔`aarch64`.
- Debian 11 (bullseye, glibc 2.31) supports only the first-party subset: `bestool bestool-psql bestool-alertd algae seedling` (the `gnu35` container tools need glibc ≥ 2.35).
- Do **not** modify the 11 build workflows or the first-party source repos.
- Use `jj` for commits (this repo is colocated). Per-task commit = `jj describe -m "…"` then `jj new`.

## File Structure

- `scripts/repack-to-xz.sh` — **new**. Normalise one `.deb` to xz per the predicate; pass through xz/gz unchanged. Single responsibility: byte-in → compliant byte-out.
- `scripts/select-new-debs.sh` — **new**. Given an ingested-keys marker file and candidate source keys on stdin, print the keys not yet ingested. Single responsibility: set difference.
- `scripts/test/repack-to-xz.test.sh` — **new**. Local test for the repack helper using crafted fixtures.
- `scripts/test/select-new-debs.test.sh` — **new**. Local test for the selector.
- `.github/workflows/apt-repo.yml` — **modify**. Rewrite the `generate-repo` job around the helpers + `deb-s3`; add a `rebuild` `workflow_dispatch` input; add a `helper-tests` job; add Debian 11 + 12 smoke-test jobs.

Helper tests require `dpkg-deb`, which is absent on the Arch dev box. Run them in a Debian container:

```bash
docker run --rm -v "$PWD:/w" -w /w debian:12 bash -c \
  'apt-get update >/dev/null && apt-get install -y dpkg-dev binutils zstd xz-utils >/dev/null && \
   scripts/test/repack-to-xz.test.sh && scripts/test/select-new-debs.test.sh'
```

---

### Task 1: Repack helper (`scripts/repack-to-xz.sh`)

**Files:**
- Create: `scripts/repack-to-xz.sh`
- Test: `scripts/test/repack-to-xz.test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `scripts/repack-to-xz.sh <in.deb> <out.deb>` — writes a compliant deb to `<out.deb>` (repacked to xz, or a byte-identical copy when input members are all xz/gz). Exit 0 on success, 2 on usage error.

- [ ] **Step 1: Write the failing test**

Create `scripts/test/repack-to-xz.test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
repack="$here/repack-to-xz.sh"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

pkg="$work/src"; mkdir -p "$pkg/DEBIAN" "$pkg/usr/bin"
cat > "$pkg/DEBIAN/control" <<EOF
Package: fixture
Version: 1.0.0
Architecture: amd64
Maintainer: test <test@example.com>
Description: fixture package
EOF
printf '#!/bin/sh\necho hi\n' > "$pkg/usr/bin/fixture"; chmod 755 "$pkg/usr/bin/fixture"

dpkg-deb --root-owner-group -Z zstd -b "$pkg" "$work/zstd.deb" >/dev/null
dpkg-deb --root-owner-group -Z xz   -b "$pkg" "$work/xz.deb"   >/dev/null
dpkg-deb --root-owner-group -Z gzip -b "$pkg" "$work/gz.deb"   >/dev/null

fail=0
"$repack" "$work/zstd.deb" "$work/out-zstd.deb"
ar t "$work/out-zstd.deb" | grep -q '\.tar\.zst' && { echo "FAIL: zstd member remains"; fail=1; }
ar t "$work/out-zstd.deb" | grep -q 'control\.tar\.xz' || { echo "FAIL: control not xz"; fail=1; }
ar t "$work/out-zstd.deb" | grep -q 'data\.tar\.xz'    || { echo "FAIL: data not xz"; fail=1; }
dpkg-deb -I "$work/out-zstd.deb" >/dev/null || { echo "FAIL: output not a valid deb"; fail=1; }

"$repack" "$work/xz.deb" "$work/out-xz.deb"
cmp -s "$work/xz.deb" "$work/out-xz.deb" || { echo "FAIL: xz not passed through unchanged"; fail=1; }

"$repack" "$work/gz.deb" "$work/out-gz.deb"
cmp -s "$work/gz.deb" "$work/out-gz.deb" || { echo "FAIL: gz not passed through unchanged"; fail=1; }

[ "$fail" -eq 0 ] && echo "ALL PASS" || exit 1
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
docker run --rm -v "$PWD:/w" -w /w debian:12 bash -c \
  'apt-get update >/dev/null && apt-get install -y dpkg-dev binutils zstd xz-utils >/dev/null && \
   bash scripts/test/repack-to-xz.test.sh'
```
Expected: FAIL — `scripts/repack-to-xz.sh` does not exist (`No such file`).

- [ ] **Step 3: Write the helper**

Create `scripts/repack-to-xz.sh`:

```bash
#!/usr/bin/env bash
# Normalise a .deb so it installs on old dpkg (Debian 11 / dpkg 1.20), which
# cannot read zstd-compressed members. Repacks to xz unless every control/data
# member is already xz or gzip (both readable by every relevant dpkg), in which
# case the input is copied through unchanged.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <in.deb> <out.deb>" >&2
  exit 2
fi
in=$1; out=$2

needs_repack=0
while IFS= read -r m; do
  case "$m" in
    control.tar.*|data.tar.*)
      case "$m" in
        *.tar.xz|*.tar.gz) ;;   # already old-dpkg-safe
        *) needs_repack=1 ;;    # zstd or anything else -> normalise
      esac
      ;;
  esac
done < <(ar t "$in")

if [ "$needs_repack" -eq 0 ]; then
  cp -- "$in" "$out"
  echo "passthrough: $in (already xz/gz)"
  exit 0
fi

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
dpkg-deb -R "$in" "$tmp/pkg"
dpkg-deb --root-owner-group -Z xz -b "$tmp/pkg" "$out" >/dev/null
echo "repacked: $in -> xz"
```

Then: `chmod +x scripts/repack-to-xz.sh`

- [ ] **Step 4: Run the test to verify it passes**

```bash
docker run --rm -v "$PWD:/w" -w /w debian:12 bash -c \
  'apt-get update >/dev/null && apt-get install -y dpkg-dev binutils zstd xz-utils >/dev/null && \
   bash scripts/test/repack-to-xz.test.sh'
```
Expected: `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
jj describe -m "apt-repo: add repack-to-xz helper for old-dpkg compatibility" && jj new
```

---

### Task 2: New-deb selector (`scripts/select-new-debs.sh`)

**Files:**
- Create: `scripts/select-new-debs.sh`
- Test: `scripts/test/select-new-debs.test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `scripts/select-new-debs.sh <ingested-keys-file> < candidates` — reads candidate S3 object keys (one per line) on stdin, prints to stdout those not present in `<ingested-keys-file>` (whole-line, fixed-string match). A missing marker file means every candidate is new.

- [ ] **Step 1: Write the failing test**

Create `scripts/test/select-new-debs.test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
sel="$here/select-new-debs.sh"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

printf '%s\n' a/1.deb b/2.deb > "$work/ingested"
out=$(printf '%s\n' a/1.deb b/2.deb c/3.deb | "$sel" "$work/ingested")
[ "$out" = "c/3.deb" ] || { echo "FAIL: expected c/3.deb, got: [$out]"; exit 1; }

out=$(printf '%s\n' a/1.deb | "$sel" "$work/does-not-exist")
[ "$out" = "a/1.deb" ] || { echo "FAIL: missing marker should yield all; got: [$out]"; exit 1; }

out=$(printf '%s\n' a/1.deb b/2.deb | "$sel" "$work/ingested" || true)
[ -z "$out" ] || { echo "FAIL: expected empty, got: [$out]"; exit 1; }

echo "ALL PASS"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash scripts/test/select-new-debs.test.sh`
Expected: FAIL — `scripts/select-new-debs.sh` not found. (No container needed; pure text.)

- [ ] **Step 3: Write the selector**

Create `scripts/select-new-debs.sh`:

```bash
#!/usr/bin/env bash
# Print candidate S3 object keys (stdin, one per line) that are NOT already
# recorded in the ingested-keys marker file ($1). A missing marker = first run
# / rebuild, so every candidate is treated as new.
set -euo pipefail
ingested=${1:?usage: select-new-debs.sh <ingested-keys-file> < candidates}
[ -f "$ingested" ] || ingested=/dev/null
grep -vxF -f "$ingested" || true
```

Then: `chmod +x scripts/select-new-debs.sh`

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash scripts/test/select-new-debs.test.sh`
Expected: `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
jj describe -m "apt-repo: add select-new-debs helper for incremental publishing" && jj new
```

---

### Task 3: Wire helper tests into CI

**Files:**
- Modify: `.github/workflows/apt-repo.yml` (add a `helper-tests` job at the top of `jobs:`)

**Interfaces:**
- Consumes: `scripts/test/*.test.sh` from Tasks 1–2.
- Produces: a `helper-tests` job that `generate-repo` will depend on (wired in Task 4).

- [ ] **Step 1: Add the job**

Insert as the first entry under `jobs:` in `.github/workflows/apt-repo.yml`:

```yaml
  helper-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install deb tooling
        run: sudo apt-get update && sudo apt-get install -y dpkg-dev binutils zstd xz-utils
      - name: repack-to-xz helper
        run: bash scripts/test/repack-to-xz.test.sh
      - name: select-new-debs helper
        run: bash scripts/test/select-new-debs.test.sh
```

- [ ] **Step 2: Lint the workflow**

Run: `docker run --rm -v "$PWD:/w" -w /w rhysd/actionlint:latest -color .github/workflows/apt-repo.yml`
Expected: no errors. (If `actionlint` is unavailable, `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/apt-repo.yml'))"` to at least confirm valid YAML.)

- [ ] **Step 3: Commit**

```bash
jj describe -m "apt-repo: run repack/select helper tests in CI" && jj new
```

---

### Task 4: Rewrite the `generate-repo` job around deb-s3

**Files:**
- Modify: `.github/workflows/apt-repo.yml` — `on.workflow_dispatch` inputs, and the whole `generate-repo` job body (currently the steps: install deps → import GPG → configure AWS → download all → generate metadata → generate Release → sign → upload → CloudFront).

**Interfaces:**
- Consumes: `scripts/repack-to-xz.sh`, `scripts/select-new-debs.sh`, the `helper-tests` job.
- Produces: a repo at `s3://bes-ops-tools/apt/` published by `deb-s3` (codename `stable`, component `main`, arches `amd64`/`arm64`), plus an ingested-keys marker at `s3://bes-ops-tools/apt-state/ingested-keys.txt`.

- [ ] **Step 1: Add the `rebuild` input**

Under `on:`, extend `workflow_dispatch`:

```yaml
on:
  workflow_dispatch:
    inputs:
      rebuild:
        description: "Full rebuild: snapshot, wipe, and republish the entire repo from source"
        type: boolean
        default: false
  schedule:
    - cron: "0 */3 * * *"
  workflow_run:
    workflows: ["aardvark-dns", "buildah", "caddy", "crun", "kopia", "krun", "libkrun", "libkrunfw", "netavark", "passt", "podman"]
    types: [completed]
    branches: [main]
  push:
    branches:
      - main
    paths:
      - .github/workflows/apt-repo.yml
```

- [ ] **Step 2: Add `needs` + checkout + provisioning to `generate-repo`**

Set the job to depend on the tests and gain a checkout. Replace the existing `Install dependencies` step. Keep `runs-on: ubuntu-slim`, and keep the existing `if:` guard but add `helper-tests` success:

```yaml
  generate-repo:
    needs: helper-tests
    runs-on: ubuntu-slim
    if: ${{ github.event.workflow_run.conclusion == 'success' || github.event_name == 'workflow_dispatch' || github.event_name == 'schedule' || github.event_name == 'push' }}
    steps:
      - uses: actions/checkout@v4

      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y dpkg-dev binutils gnupg ruby ruby-dev build-essential zstd xz-utils
          sudo gem install deb-s3 -v 26.1.1
          deb-s3 --version
```

Keep the existing `Import GPG key` and `Configure AWS Credentials` steps as-is (they already run after deps).

- [ ] **Step 3: Replace the download/metadata/Release/sign/upload steps with the incremental publish**

Delete these existing steps entirely: `Download all .deb files from S3`, `Generate repository metadata`, `Generate Release file`, `Sign Release`, `Upload repository to S3`. Replace with the two steps below. Keep the final `Clear CloudFront cache` step.

```yaml
      - name: Snapshot and wipe (full rebuild only)
        if: ${{ inputs.rebuild }}
        run: |
          set -x
          runid="${{ github.run_id }}"
          aws s3 sync s3://bes-ops-tools/apt/ "s3://bes-ops-tools/apt-backup-$runid/" --no-progress
          aws s3 rm s3://bes-ops-tools/apt/ --recursive --no-progress
          aws s3 rm s3://bes-ops-tools/apt-state/ingested-keys.txt --no-progress || true

      - name: Publish new packages
        env:
          GPG_KEY_ID: ${{ vars.GPG_KEY_ID }}
        run: |
          set -euo pipefail
          chmod +x scripts/repack-to-xz.sh scripts/select-new-debs.sh

          # Current ingested-keys marker (empty after a rebuild wipe / first run).
          aws s3 cp s3://bes-ops-tools/apt-state/ingested-keys.txt ingested-keys.txt --no-progress 2>/dev/null || : > ingested-keys.txt

          gpg --export --armor "$GPG_KEY_ID" > bes-tools.gpg.key
          aws s3 cp bes-tools.gpg.key s3://bes-ops-tools/apt/bes-tools.gpg.key --no-progress

          publish_arch() {
            local arch="$1" target="$2"
            # Build the candidate source-key list using the same filters as before.
            : > candidates.txt
            for dir in aardvark-dns buildah crun krun libkrun libkrunfw netavark passt podman; do
              aws s3 ls "s3://bes-ops-tools/$dir/" --recursive \
                | awk '{print $4}' | grep -E "/$dir/.*-${target}-unknown-linux-gnu35-.*\.deb$" >> candidates.txt || true
            done
            for dir in caddy kopia bestool algae seedling; do
              aws s3 ls "s3://bes-ops-tools/$dir/" --recursive \
                | awk '{print $4}' | grep -E "/$dir/.*-${target}-.*\.deb$" >> candidates.txt || true
            done
            for dir in bestool-alertd bestool-psql; do
              aws s3 ls "s3://bes-ops-tools/$dir/" --recursive \
                | awk '{print $4}' | grep -E "/$dir/.*-${target}-.*\.deb$" | grep -v "/latest/" >> candidates.txt || true
            done

            local newkeys
            newkeys=$(scripts/select-new-debs.sh ingested-keys.txt < candidates.txt || true)
            if [ -z "$newkeys" ]; then
              echo "no new $arch packages"
              return 0
            fi

            mkdir -p "staged/$arch"
            local i=0
            while IFS= read -r key; do
              [ -n "$key" ] || continue
              aws s3 cp "s3://bes-ops-tools/$key" "src.deb" --no-progress
              scripts/repack-to-xz.sh src.deb "staged/$arch/$(printf '%04d' "$i")-$(basename "$key")"
              rm -f src.deb
              echo "$key" >> ingested-keys.txt
              i=$((i + 1))
            done <<< "$newkeys"

            deb-s3 upload \
              --bucket bes-ops-tools --prefix apt \
              --s3-region ap-southeast-2 \
              --codename stable --suite stable --component main --origin "BES Tools" \
              --arch "$arch" \
              --preserve-versions \
              --visibility public \
              --lock \
              --sign="$GPG_KEY_ID" \
              --gpg-options="--pinentry-mode loopback --batch --yes --no-tty" \
              "staged/$arch/"*.deb
          }

          publish_arch amd64 x86_64
          publish_arch arm64 aarch64

          aws s3 cp ingested-keys.txt s3://bes-ops-tools/apt-state/ingested-keys.txt --no-progress
```

Leave the existing `Clear CloudFront cache` step unchanged.

- [ ] **Step 4: Lint the workflow**

Run: `docker run --rm -v "$PWD:/w" -w /w rhysd/actionlint:latest -color .github/workflows/apt-repo.yml`
Expected: no errors.

- [ ] **Step 5: Static review checklist (no live run yet — the first live run is the gated bootstrap in Task 6)**

Confirm by reading the diff:
- `deb-s3 upload` uses `--preserve-versions` (keeps old versions, matching the old `--multiversion`).
- The `bestool-alertd`/`bestool-psql` filters still exclude `latest/`.
- Container-tool filter still restricts to `gnu35`.
- `bes-tools.gpg.key` is still published at `apt/bes-tools.gpg.key`.

- [ ] **Step 6: Commit**

```bash
jj describe -m "apt-repo: incremental publish via deb-s3 with xz repack

Replaces the hand-rolled scan/Release/sign/full-sync with deb-s3, which
maintains the per-arch manifest in S3 and uploads only new packages. Each
candidate deb is normalised to xz first so it installs on old dpkg
(Debian 11). A workflow_dispatch 'rebuild' input snapshots and republishes
the whole repo for the one-time cutover." && jj new
```

---

### Task 5: Add Debian 11 + 12 install smoke tests

**Files:**
- Modify: `.github/workflows/apt-repo.yml` — add two jobs alongside the existing `test-repo` / `test-repo-26-04`.

**Interfaces:**
- Consumes: the published repo from `generate-repo`.
- Produces: `needs: generate-repo` jobs `test-repo-debian-11` and `test-repo-debian-12`.

- [ ] **Step 1: Add the Debian 12 (full-set) job**

Append under `jobs:` (mirrors `test-repo-26-04`, swapping the image and running the full set):

```yaml
  test-repo-debian-12:
    needs: generate-repo
    strategy:
      fail-fast: false
      matrix:
        runner: [ubuntu-24.04, ubuntu-24.04-arm]
    runs-on: ${{ matrix.runner }}
    steps:
      - name: Wait for CloudFront cache to clear
        run: sleep 30
      - name: Install and verify on Debian 12
        run: |
          docker run --rm -i -e DEBIAN_FRONTEND=noninteractive debian:12 \
            bash -euxo pipefail <<'EOF'
          apt-get update
          apt-get install -y curl gpg ca-certificates
          mkdir -p /etc/apt/keyrings
          curl -fsSL https://tools.ops.tamanu.io/apt/bes-tools.gpg.key \
            | gpg --dearmor -o /etc/apt/keyrings/bes-tools.gpg
          echo "deb [signed-by=/etc/apt/keyrings/bes-tools.gpg] https://tools.ops.tamanu.io/apt stable main" \
            > /etc/apt/sources.list.d/bes-tools.list
          cat > /etc/apt/preferences.d/bes-tools <<PIN
          Package: *
          Pin: origin tools.ops.tamanu.io
          Pin-Priority: 999
          PIN
          apt-get update
          apt-get install -y aardvark-dns buildah caddy crun kopia krun netavark passt podman \
            bestool bestool-psql bestool-alertd algae
          apt-get install -y --no-install-recommends seedling
          bestool --version; bestool-psql -h; bestool-alertd -h
          algae --version; seedling --version; caddy version; kopia --version
          EOF
```

- [ ] **Step 2: Add the Debian 11 (first-party subset) job**

Append the bullseye job — installs only the glibc-2.31-compatible first-party subset (this is the regression guard for the original outage):

```yaml
  test-repo-debian-11:
    needs: generate-repo
    strategy:
      fail-fast: false
      matrix:
        runner: [ubuntu-24.04, ubuntu-24.04-arm]
    runs-on: ${{ matrix.runner }}
    steps:
      - name: Wait for CloudFront cache to clear
        run: sleep 30
      - name: Install and verify first-party subset on Debian 11
        run: |
          docker run --rm -i -e DEBIAN_FRONTEND=noninteractive debian:11 \
            bash -euxo pipefail <<'EOF'
          apt-get update
          apt-get install -y curl gpg ca-certificates
          mkdir -p /etc/apt/keyrings
          curl -fsSL https://tools.ops.tamanu.io/apt/bes-tools.gpg.key \
            | gpg --dearmor -o /etc/apt/keyrings/bes-tools.gpg
          echo "deb [signed-by=/etc/apt/keyrings/bes-tools.gpg] https://tools.ops.tamanu.io/apt stable main" \
            > /etc/apt/sources.list.d/bes-tools.list
          cat > /etc/apt/preferences.d/bes-tools <<PIN
          Package: *
          Pin: origin tools.ops.tamanu.io
          Pin-Priority: 999
          PIN
          apt-get update
          # glibc 2.31 on bullseye: only the first-party subset is expected to work.
          apt-get install -y bestool bestool-psql bestool-alertd algae
          apt-get install -y --no-install-recommends seedling
          bestool --version; bestool-psql -h; bestool-alertd -h
          algae --version; seedling --version
          EOF
```

- [ ] **Step 3: Lint the workflow**

Run: `docker run --rm -v "$PWD:/w" -w /w rhysd/actionlint:latest -color .github/workflows/apt-repo.yml`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
jj describe -m "apt-repo: add Debian 11 + 12 install smoke tests

Debian 11 (glibc 2.31) installs the first-party subset only and guards the
old-dpkg/zstd regression; Debian 12 installs the full set." && jj new
```

---

### Task 6: Bootstrap cutover (operational, gated)

**Files:** none (operational — a manual dispatch and verification).

**Interfaces:**
- Consumes: everything above, merged to `main` (the workflow must be on the branch you dispatch).

- [ ] **Step 1: Open the PR and get it merged**

Push the bookmark and open a PR (robot-emoji prefix, no test-plan section, no backtick-escaping):

```bash
jj bookmark create apt-repo-xz-deb-s3 -r @-
jj git push --bookmark apt-repo-xz-deb-s3
gh pr create --repo beyondessential/third-party-builds --head apt-repo-xz-deb-s3 --base main \
  --title "APT repo: xz repack + incremental deb-s3 pipeline" --body "…"
```

The PR's own `helper-tests` job must be green before merge. `generate-repo`/smoke-test jobs only run meaningfully after merge (they publish to the live bucket), so do not expect them to exercise the live repo from the PR.

- [ ] **Step 2: Run the gated full rebuild**

After merge, from `main`:

```bash
gh workflow run "APT Repository" -f rebuild=true --ref main
gh run watch "$(gh run list --workflow='APT Repository' -L1 --json databaseId -q '.[0].databaseId')"
```

Expected: `generate-repo` succeeds; a snapshot exists at `s3://bes-ops-tools/apt-backup-<runid>/`.

- [ ] **Step 3: Verify no zstd remains and old dpkg installs**

```bash
# Every served deb must now be xz/gz, never zstd.
aws s3 ls s3://bes-ops-tools/apt/pool/ --recursive | awk '{print $4}' | grep '\.deb$' \
  | while read -r k; do aws s3 cp "s3://bes-ops-tools/$k" - --no-progress | ar t /dev/stdin; done | sort -u
```
Expected: only `*.tar.xz` / `*.tar.gz` members (plus `debian-binary`, `control.tar.*`), no `.tar.zst`.

Then confirm the `test-repo-debian-11` and `test-repo-debian-12` jobs (triggered by the rebuild run) are green — this is the definitive proof the original `bestool` failure is fixed.

- [ ] **Step 4: Confirm steady-state is incremental**

```bash
gh workflow run "APT Repository" --ref main   # no rebuild flag
```
Expected in logs: `no new amd64 packages` / `no new arm64 packages` (marker already covers everything); deb-s3 does not re-download the pool.

- [ ] **Step 5: Clean up the backup once satisfied**

```bash
aws s3 rm "s3://bes-ops-tools/apt-backup-<runid>/" --recursive
```

---

## Self-Review

**Spec coverage:**
- A (repack, predicate 2) → Task 1 + used in Task 4 Step 3. ✓
- B (deb-s3 incremental, bootstrap, steady-state list/diff, marker) → Tasks 2, 4, 6. ✓
- C (Debian 11 + 12 tests, subset vs full) → Task 5. ✓
- Accepted losses (`.bz2`/`.xz` index variants, `Label`/`Description`) → inherent to using deb-s3; no task needed, documented in spec. Note: the manual S3 content-type retagging step is also dropped (deb-s3 sets its own; apt is content-type-agnostic) — acceptable.
- Non-goal (don't touch build repos) → respected; only `apt-repo.yml` + `scripts/` change. ✓

**Placeholder scan:** the only `…` is the PR `--body` in Task 6 Step 1, which is intentionally author-written at PR time; every code/YAML step is complete.

**Type/name consistency:** `scripts/repack-to-xz.sh <in> <out>` and `scripts/select-new-debs.sh <marker> < candidates` are used with those exact signatures in Task 4. Marker path `s3://bes-ops-tools/apt-state/ingested-keys.txt` is consistent across Task 4 and Task 6. Job names (`helper-tests`, `generate-repo`, `test-repo-debian-11/12`) are consistent across `needs:` references.
