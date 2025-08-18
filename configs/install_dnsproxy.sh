#!/bin/bash

# Define the repository and tool name
REPO_OWNER="AdguardTeam"
REPO_NAME="dnsproxy"

ARGS="--listen 0.0.0.0 --listen :: --port 5353 \
    --bootstrap 8.8.8.8 --bootstrap 2606:4700:4700::1111 \
    --fallback 9.9.9.9 --fallback 2620:fe::9 \
    --upstream [/www.googleadservices.com/]8.8.8.8 --upstream [/ad.doubleclick.net/]8.8.8.8 \
    --upstream https://dns.adguard.com/dns-query --upstream quic://dns.adguard.com \
    --ratelimit 500 --cache --cache-optimistic --cache-size 2097152  --output /dev/null"

# Fetch the latest release tag from GitHub API
echo "Fetching the latest release information..."
LATEST_TAG=$(curl -s "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$LATEST_TAG" ]; then
    echo "Failed to fetch the latest release tag. Exiting."
    exit 1
fi

# Detect system architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) SYSTEM_ARCH="linux-amd64" ;;
    aarch64) SYSTEM_ARCH="linux-arm64" ;;
    armv7*) SYSTEM_ARCH="linux-arm7" ;;
    *)
        echo "Unsupported architecture: $ARCH. Exiting."
        exit 1
        ;;
esac

# Construct the download URL
DOWNLOAD_URL="https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/$LATEST_TAG/dnsproxy-$SYSTEM_ARCH-$LATEST_TAG.tar.gz"
echo "Downloading dnsproxy from: $DOWNLOAD_URL"

# Create a temporary directory for extraction
TEMP_DIR=$(mktemp -d)

# Download and extract the binary
curl -sSL "$DOWNLOAD_URL" -o dnsproxy.tar.gz && \
    tar -xzf dnsproxy.tar.gz -C "$TEMP_DIR" && \
    rm -f dnsproxy.tar.gz

# Move the binary to /usr/local/bin/
echo "Installing dnsproxy to /usr/local/bin/"
mv "$TEMP_DIR/$SYSTEM_ARCH/dnsproxy" /usr/local/bin/

# Clean up the temporary directory
rm -rf "$TEMP_DIR"

# Check if the script was run with systemd
if [[ "$1" == "systemd" ]]; then
    if ! command -v systemctl 2>&1 >/dev/null
    then
        echo "Error: systemd is not available on this system"
        exit 1
    fi

    echo "Setting up systemd service..."

    SERVICE_CONTENT="[Unit]
Description=DNSProxy - A fast DNS proxy with DoH/DoT support
After=network.target

[Service]
ExecStart=/usr/local/bin/dnsproxy ${ARGS}
Restart=always

[Install]
WantedBy=multi-user.target"

    # Write the service file to /etc/systemd/system/dnsproxy.service
    echo "$SERVICE_CONTENT" | tee /etc/systemd/system/dnsproxy.service > /dev/null

    # Enable and start the service (chroot-safe)
    systemctl daemon-reload || true
    systemctl enable dnsproxy || true

    # Configure systemd-resolved (create config if in chroot)
    if [ ! -f /etc/systemd/resolved.conf ]; then
        # We're likely in chroot, create the config file
        mkdir -p /etc/systemd
        cat > /etc/systemd/resolved.conf << 'EOF'
[Resolve]
DNS=127.0.0.1:5353
EOF
        echo "Created systemd-resolved configuration for dnsproxy"
    else
        # Normal system, check if service is running
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            # Backup the original resolved.conf file
            cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak 2>/dev/null || true

            # Ensure [Resolve] section exists
            if ! grep -q '^\[Resolve\]' /etc/systemd/resolved.conf; then
                printf '\n[Resolve]\n' >> /etc/systemd/resolved.conf
            fi
            # Add or replace DNS setting to forward queries to dnsproxy
            if grep -q '^\s*DNS=' /etc/systemd/resolved.conf; then
                sed -i 's/^\s*DNS=.*/DNS=127.0.0.1:5353/' /etc/systemd/resolved.conf
            else
                printf 'DNS=127.0.0.1:5353\n' >> /etc/systemd/resolved.conf
            fi

            # Restart systemd-resolved to apply changes
            systemctl restart systemd-resolved || true
        else
            # Service not running, just configure the file
            if ! grep -q '^\[Resolve\]' /etc/systemd/resolved.conf; then
                printf '\n[Resolve]\n' >> /etc/systemd/resolved.conf
            fi
            if grep -q '^\s*DNS=' /etc/systemd/resolved.conf; then
                sed -i 's/^\s*DNS=.*/DNS=127.0.0.1:5353/' /etc/systemd/resolved.conf
            else
                printf 'DNS=127.0.0.1:5353\n' >> /etc/systemd/resolved.conf
            fi
        fi
        
        echo "Configured systemd-resolved to forward DNS queries to dnsproxy at 127.0.0.1:5353"
    fi

    echo ""
    echo "dnsproxy systemd service has been installed and started with the args: ${ARGS}"
else
    echo "Successfully installed dnsproxy to /usr/local/bin/."
    echo "You can now run 'dnsproxy --version' to verify the installation."
fi
