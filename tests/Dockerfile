# Throwaway test environment for tests/run.sh and CI. The suites replace
# system commands with test doubles, so they only run where
# FIERO_TEST_CONTAINER=1 is set.
FROM debian:trixie-slim

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash bats ca-certificates iw perl procps shellcheck sudo systemd util-linux \
    && rm -rf /var/lib/apt/lists/*

ENV FIERO_TEST_CONTAINER=1
WORKDIR /src
