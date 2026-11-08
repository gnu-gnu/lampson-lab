# Images built by this lab. Targets: bootstrap, client, sshd.
# Release binaries are downloaded once (tools stage) and checked against the
# upstream checksum files before use.
ARG DEBIAN_IMAGE

FROM ${DEBIAN_IMAGE} AS tools
ARG SPIRE_VERSION
ARG STEP_CLI_VERSION
ARG TARGETARCH
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /dl
RUN set -eux; \
    test -n "${SPIRE_VERSION}" && test -n "${STEP_CLI_VERSION}" && test -n "${TARGETARCH}"; \
    spire="spire-${SPIRE_VERSION}-linux-${TARGETARCH}-musl"; \
    base="https://github.com/spiffe/spire/releases/download/v${SPIRE_VERSION}"; \
    curl -fsSLO "${base}/${spire}.tar.gz"; \
    curl -fsSLO "${base}/${spire}_sha256sum.txt"; \
    sha256sum -c "${spire}_sha256sum.txt"; \
    mkdir spire; tar -xzf "${spire}.tar.gz" -C spire --strip-components=1; \
    install -m 0755 spire/bin/spire-server spire/bin/spire-agent /usr/local/bin/; \
    step="step_linux_${TARGETARCH}.tar.gz"; \
    base="https://github.com/smallstep/cli/releases/download/v${STEP_CLI_VERSION}"; \
    curl -fsSLO "${base}/${step}"; \
    curl -fsSLO "${base}/checksums.txt"; \
    grep -E "[[:space:]]${step}\$" checksums.txt | sha256sum -c -; \
    mkdir step; tar -xzf "${step}" -C step --strip-components=1; \
    install -m 0755 step/bin/step /usr/local/bin/step; \
    spire-server --version; spire-agent --version; step version

# One-shot bootstrap: lab PKI, step-ca config, SPIRE join token and entries.
FROM ${DEBIAN_IMAGE} AS bootstrap
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates jq \
 && rm -rf /var/lib/apt/lists/*
COPY --from=tools /usr/local/bin/spire-server /usr/local/bin/step /usr/local/bin/
COPY bootstrap/templates/ /etc/lab-bootstrap/templates/
COPY bootstrap/spire-entries.txt /etc/lab-bootstrap/spire-entries.txt
COPY step/ /etc/lab-bootstrap/step/
COPY --chmod=0755 bootstrap/bootstrap.sh /usr/local/bin/bootstrap
ENTRYPOINT ["/usr/local/bin/bootstrap"]

# Workload host: local accounts mapped to SPIFFE IDs by uid (CONTRACT §5.1).
FROM ${DEBIAN_IMAGE} AS client
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates jq openssh-client \
 && rm -rf /var/lib/apt/lists/*
COPY --from=tools /usr/local/bin/spire-agent /usr/local/bin/step /usr/local/bin/
RUN set -eux; \
    useradd -m -u 1001 -s /bin/bash deployer; \
    useradd -m -u 1002 -s /bin/bash monitor; \
    useradd -m -u 1003 -s /bin/bash stranger; \
    useradd -m -u 1004 -s /bin/bash intruder
COPY --chmod=0755 client/lab-ssh-cert client/lab-login /usr/local/bin/
ENV SPIRE_AGENT_SOCKET=/run/spire/agent/api.sock \
    STEP_CA_URL=https://step-ca:9000 \
    STEP_CA_ROOT=/etc/lab-step-ca/root_ca.crt
CMD ["sleep", "infinity"]

# SSH target host (host-billing, host-crm): role accounts only (CONTRACT §5.3).
FROM ${DEBIAN_IMAGE} AS sshd
# Package install generates host keys; they are deleted in the same layer so no
# private key is baked into the image. The entrypoint creates one per host volume.
RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-server sudo \
 && rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_* /etc/ssh/sshd_config.d
RUN set -eux; \
    # Debian already has a system group "operator" (gid 37); each role account
    # gets its own new primary group instead of joining it.
    for role in admin operator readonly; do \
      groupadd "lab-${role}"; \
      useradd -m -s /bin/bash -N -g "lab-${role}" "$role"; \
      usermod -p '*' "$role"; \
    done; \
    install -d -m 0755 /etc/demo; \
    echo "demo secret: only root may read this" >/etc/demo/secret.conf; \
    chown root:root /etc/demo/secret.conf; chmod 0600 /etc/demo/secret.conf; \
    install -d -m 0700 /etc/ssh/host-keys
COPY sshd/sshd_config /etc/ssh/sshd_config
COPY --chmod=0440 sshd/sudoers /etc/sudoers.d/lab-roles
COPY --chmod=0755 sshd/demo-restart /usr/local/bin/demo-restart
COPY --chmod=0755 sshd/entrypoint.sh /usr/local/bin/lab-sshd
COPY --chmod=0755 sshd/session-reaper.sh /usr/local/bin/lab-session-reaper
RUN visudo -cf /etc/sudoers.d/lab-roles && chmod 0644 /etc/ssh/sshd_config
ENTRYPOINT ["/usr/local/bin/lab-sshd"]
