# The one artifact every forge runs: GitHub and Forgejo as a job container,
# GitLab as the job image. No ENTRYPOINT, so each CI system's shell runs.

# trivy (a static binary) for the security strategy's image scans; Alpine
# stable does not package it.
FROM ghcr.io/aquasecurity/trivy:0.76.2@sha256:8f6bb947dbc528902e11f2f5be52f7b519f6a39d5d148f41166f2040499768fb AS trivy

FROM alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a AS runtime

# Unpinned on purpose: the Alpine release fixes their versions, and Renovate
# moves the base image digest.
# hadolint ignore=DL3018
RUN apk add --no-cache ca-certificates crane curl git git-cliff jq
COPY --from=trivy /usr/local/bin/trivy /usr/local/bin/trivy
COPY bin/auto-release /usr/local/bin/auto-release
COPY share/auto-release/ /usr/local/share/auto-release/

# CI builds this stage to run the tests against the installed layout and the
# exact tool versions above.
FROM runtime AS test
# hadolint ignore=DL3018
RUN apk add --no-cache bats
COPY tests/ /src/tests/
RUN AUTO_RELEASE_BIN=/usr/local/bin/auto-release bats /src/tests

FROM runtime
