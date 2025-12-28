ARG BUILD_FROM
FROM ${BUILD_FROM}

# Install packages: Node.js, npm, git, gh CLI, adb, bash utilities
RUN apk add --no-cache \
    nodejs \
    npm \
    bash \
    curl \
    git \
    jq \
    openssh-client \
    android-tools \
    github-cli \
    iptables \
    ttyd \
    && npm config set registry https://registry.npmjs.org/ \
    && npm config set fetch-retries 3 \
    && npm config set fetch-retry-mintimeout 20000 \
    && npm config set fetch-retry-maxtimeout 120000 \
    && npm config set fetch-timeout 300000 \
    && for i in 1 2 3; do \
        echo "Attempt $i: Installing Claude Code CLI..." && \
        npm install -g @anthropic-ai/claude-code@latest && \
        echo "Successfully installed Claude Code CLI" && \
        break || \
        (echo "Attempt $i failed, retrying in 10 seconds..." && sleep 10); \
    done \
    && npm cache clean --force

# Install Tailscale 1.92.4 directly (Alpine package is outdated)
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then ARCH="amd64"; fi && \
    if [ "$ARCH" = "aarch64" ]; then ARCH="arm64"; fi && \
    curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_1.92.4_${ARCH}.tgz" -o /tmp/tailscale.tgz && \
    tar -xzf /tmp/tailscale.tgz -C /tmp && \
    cp /tmp/tailscale_*/tailscale /usr/bin/ && \
    cp /tmp/tailscale_*/tailscaled /usr/sbin/ && \
    rm -rf /tmp/tailscale*

# Create directories
RUN mkdir -p /data/repos /data/claude-config /data/logs

# Set working directory
WORKDIR /data

# Copy scripts
COPY run.sh /run.sh
COPY investigate.sh /investigate.sh
COPY server.js /server.js
RUN chmod +x /run.sh /investigate.sh

# Default command keeps container running
CMD ["/run.sh"]
