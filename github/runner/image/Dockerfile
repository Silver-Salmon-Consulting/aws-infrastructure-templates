# Ephemeral GitHub Actions runner image for the Fargate runner stack.
#
#   docker buildx build --platform linux/amd64 -t <ecr-repo-uri>:latest --push .
#   docker buildx build --platform linux/arm64 -t <ecr-repo-uri>:latest --push .   # CpuArchitecture=ARM64
#
# The image architecture must match the stack's CpuArchitecture parameter.
FROM ubuntu:24.04

ARG TARGETARCH
# Leave empty to install the latest runner release at build time.
ARG RUNNER_VERSION=""

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq sudo unzip zip tar gzip libicu74 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash runner \
 && echo "runner ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/runner

USER runner
WORKDIR /home/runner/actions-runner

RUN set -eux; \
    case "${TARGETARCH}" in amd64) arch=x64 ;; arm64) arch=arm64 ;; *) echo "unsupported arch ${TARGETARCH}" >&2; exit 1 ;; esac; \
    version="${RUNNER_VERSION:-$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/^v//')}"; \
    curl -fsSL "https://github.com/actions/runner/releases/download/v${version}/actions-runner-linux-${arch}-${version}.tar.gz" | tar xz; \
    sudo ./bin/installdependencies.sh

COPY --chown=runner:runner entrypoint.sh /home/runner/entrypoint.sh
RUN chmod +x /home/runner/entrypoint.sh

ENTRYPOINT ["/home/runner/entrypoint.sh"]
