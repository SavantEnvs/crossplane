# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — crossplane (Go, Kubernetes control plane).
# Builds ON TOP of the org C/C++ base (clang links the go-118-fuzz-build
# libFuzzer archive) + a pinned Go toolchain and go-118-fuzz-build under
# /opt/toolchains/go, then runs mayhem/build.sh to fuzz the package dependency
# DAG (internal/dag) as an isolated dependency-light mini-module.
#
# WHY caches at fixed /opt/toolchains paths (SPEC §6.2 item 8 / §6.5): Go's
# GOPATH/GOMODCACHE default to $HOME/go, and the commit build vs. the PATCH RL
# re-run use DIFFERENT $HOMEs — an unpinned cache vanishes under the re-run
# identity and the offline build dies. Pinning them (below) is what makes the
# air-gapped re-run find the module cache the first online build filled.
#
# Build (from repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) -t crossplane-commit:test .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS

# Pinned Go (version AND tarball sha256) + go-118-fuzz-build pinned by COMMIT
# (its release tag is a stale 2022 snapshot predating the /testing shim).
# crossplane's go.mod is `go 1.25.11`; with GOTOOLCHAIN=local we install a
# toolchain that satisfies it. 1.26.7 is current and go-118-fuzz-build
# @a70c2aa677fa builds under it.
ARG GO_VERSION=1.26.7
ARG GO_SHA256=ffb5f8de10c62550dfddab66b36b57030721e0a44a3218e9e1181d7b59f121ca
ARG GO_118_FUZZ_BUILD_COMMIT=a70c2aa677fa43583571959478decabe02a96cd6

ENV GOROOT=/opt/toolchains/go \
    GOPATH=/opt/toolchains/go-path \
    GOMODCACHE=/opt/toolchains/go-path/pkg/mod \
    GOCACHE=/opt/toolchains/go-path/build-cache \
    GOTOOLCHAIN=local \
    GOFLAGS=-mod=mod \
    GOSUMDB=off \
    PATH=/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

USER root
RUN install -d /opt/toolchains/go-path \
 && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz \
 && echo "${GO_SHA256}  /tmp/go.tgz" | sha256sum -c - \
 && tar -C /opt/toolchains -xzf /tmp/go.tgz && rm -f /tmp/go.tgz \
 # Install go-118-fuzz-build (the OSS-Fuzz native testing.F path). This also seeds
 # its module — incl. the /testing shim + go-fuzz-headers — into GOMODCACHE, which
 # build.sh's `go get .../testing` then resolves OFFLINE at the PATCH re-run.
 && go install "github.com/AdamKorcz/go-118-fuzz-build@${GO_118_FUZZ_BUILD_COMMIT}" \
 # The commit build AND the air-gapped re-run run as `mayhem` (2000): it must read
 # the toolchain and read/refresh the module cache, so hand GOPATH to 2000.
 && chown -R 2000:2000 /opt/toolchains/go-path

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $GOMODCACHE (online, this first build) and builds the libFuzzer target.
RUN bash mayhem/build.sh

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
