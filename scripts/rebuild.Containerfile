# Image for scripts/rebuild-apt-repo.sh — bakes the Debian tooling so batches
# start instantly and nothing is installed on the host. Build once:
#   sudo podman build -t localhost/bes-apt-rebuild -f scripts/rebuild.Containerfile scripts/
FROM docker.io/library/debian:12

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      dpkg-dev binutils zstd xz-utils gnupg ruby ruby-dev build-essential \
      curl unzip ca-certificates \
 && arch="$(uname -m)" \
 && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o /tmp/awscliv2.zip \
 && (cd /tmp && unzip -q awscliv2.zip && ./aws/install) \
 && rm -rf /tmp/aws /tmp/awscliv2.zip \
 && gem install --no-document deb-s3 -v 26.1.0 \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && aws --version && deb-s3 upload --help >/dev/null 2>&1 || true
