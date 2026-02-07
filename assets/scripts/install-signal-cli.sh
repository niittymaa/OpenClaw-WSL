#!/bin/bash
# Signal-CLI Installer Script
# Downloads and installs the latest signal-cli native binary from GitHub

set -e

echo "=== Signal-CLI Installer ==="
echo

# Install dependencies
echo "[1/4] Installing dependencies..."
sudo apt update -qq
sudo apt install -y -qq jq wget

# Get latest version
echo "[2/4] Fetching latest version..."
SIGNAL_CLI_VERSION=$(curl -s https://api.github.com/repos/AsamK/signal-cli/releases/latest | jq -r .tag_name | tr -d 'v')

if [ -z "$SIGNAL_CLI_VERSION" ]; then
    echo "ERROR: Failed to fetch version from GitHub API"
    exit 1
fi

echo "       Latest version: v${SIGNAL_CLI_VERSION}"

# Download native binary (no Java required)
echo "[3/4] Downloading signal-cli-${SIGNAL_CLI_VERSION}-Linux-native.tar.gz..."
wget -q --show-progress "https://github.com/AsamK/signal-cli/releases/download/v${SIGNAL_CLI_VERSION}/signal-cli-${SIGNAL_CLI_VERSION}-Linux-native.tar.gz" -O /tmp/signal-cli.tar.gz

# Install
echo "[4/4] Installing to /usr/local/bin..."
sudo tar xzf /tmp/signal-cli.tar.gz -C /usr/local/bin
sudo chmod +x /usr/local/bin/signal-cli
rm /tmp/signal-cli.tar.gz

# Verify
echo
signal-cli --version
echo
echo "=== Installation complete! ==="
echo
echo "Next steps:"
echo "  1. Get captcha: https://signalcaptchas.org/registration/generate.html"
echo "  2. Register:    signal-cli -u +YOUR_PHONE register --captcha CAPTCHA"
echo "  3. Verify:      signal-cli -u +YOUR_PHONE verify CODE"
