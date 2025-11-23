#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Configuration
# ============================================================

BITCOIN_USER="bitcoin"
BITCOIN_DATA_DIR="/var/lib/bitcoind"
BIN_DIR="/usr/local/bin"
ARCH="x86_64-linux-gnu"

SERVICE_FILE="/etc/systemd/system/bitcoind.service"
TOR_SCRIPT="/usr/local/bin/enable-tor-post-ibd.sh"
TOR_SERVICE_FILE="/etc/systemd/system/enable-tor-post-ibd.service"

DOWNLOAD_BASE_URL="https://bitcoincore.org/bin"
GUIX_SIGS_REPO="https://github.com/bitcoin-core/guix.sigs.git"

WORK_DIR="$(mktemp -d)"
KEYS_DIR="$WORK_DIR/guix.sigs/builder-keys"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

log() {
    echo "$(date +'%F %T') - $*"
}

error_exit() {
    echo "ERROR: $*" >&2
    exit 1
}

# ============================================================
# Start
# ============================================================

log "Starting Bitcoin Core installation (full key import + simple gpg verify)"

if [ "$(id -u)" -ne 0 ]; then
    error_exit "Run as root (use sudo)"
fi

log "Installing dependencies"
apt-get update
apt-get install -y curl gnupg2 ca-certificates jq tor git || error_exit "Dependency installation failed"

log "Enabling Tor"
systemctl enable tor
systemctl start tor

# ============================================================
# Step 1: Import all GPG builder keys
# ============================================================

log "Cloning guix.sigs"
git clone --depth=1 "$GUIX_SIGS_REPO" "$WORK_DIR/guix.sigs" || error_exit "Failed to clone guix.sigs"

if [ ! -d "$KEYS_DIR" ]; then
    error_exit "builder-keys directory missing"
fi

log "Importing all builder GPG keys"
for keyfile in "$KEYS_DIR"/*.gpg; do
    log "Importing $keyfile"
    gpg --import "$keyfile" || error_exit "Failed to import $keyfile"
done

# ============================================================
# Step 2: Download Bitcoin Core and verify signatures
# ============================================================

echo -n "Enter Bitcoin Core version to install (e.g., 28.1): "
read VERSION

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
    error_exit "Invalid version number"
fi

TARBALL="bitcoin-${VERSION}-${ARCH}.tar.gz"
CHECKSUMS="SHA256SUMS"
CHECKSUMS_ASC="SHA256SUMS.asc"

BASE="$DOWNLOAD_BASE_URL/bitcoin-core-${VERSION}"

log "Downloading Bitcoin Core release files"
curl -fLO "$BASE/$TARBALL"      || error_exit "Download failed: tarball"
curl -fLO "$BASE/$CHECKSUMS"    || error_exit "Download failed: checksums"
curl -fLO "$BASE/$CHECKSUMS_ASC" || error_exit "Download failed: signature"

log "Running gpg --verify on SHA256SUMS.asc"
gpg --verify "$CHECKSUMS_ASC" "$CHECKSUMS" || error_exit "GPG signature verification FAILED"

log "Verifying SHA256 checksum"
grep "$TARBALL" "$CHECKSUMS" | sha256sum --check --ignore-missing || error_exit "Checksum mismatch"

# ============================================================
# Step 3: Install Bitcoin Core binaries
# ============================================================

TMP_EXTRACT="/tmp/bitcoin-core-${VERSION}"
rm -rf "$TMP_EXTRACT"
mkdir -p "$TMP_EXTRACT"

log "Extracting binaries"
tar -xzf "$TARBALL" -C "$TMP_EXTRACT"

EXTRACTED="$TMP_EXTRACT/bitcoin-${VERSION}"

log "Installing binaries to $BIN_DIR"
install -m 0755 -o root -g root -t "$BIN_DIR" "$EXTRACTED/bin/"*

# ============================================================
# Step 4: Create bitcoin user + datadir
# ============================================================

log "Creating bitcoin system user (if missing)"
id -u "$BITCOIN_USER" >/dev/null 2>&1 || adduser --system --no-create-home --group "$BITCOIN_USER"

log "Ensuring datadir exists"
mkdir -p "$BITCOIN_DATA_DIR"
chown "$BITCOIN_USER":"$BITCOIN_USER" "$BITCOIN_DATA_DIR"

# ============================================================
# Step 5: bitcoin.conf
# ============================================================

CONF="$BITCOIN_DATA_DIR/bitcoin.conf"
if [ ! -f "$CONF" ]; then
    log "Creating bitcoin.conf"
    cat > "$CONF" <<EOF
datadir=$BITCOIN_DATA_DIR
server=1
daemon=0
txindex=1
peerbloomfilters=1
rpcallowip=127.0.0.1
rpcport=8332
listen=1
listenonion=1
EOF

    chown "$BITCOIN_USER":"$BITCOIN_USER" "$CONF"
fi

# ============================================================
# Step 6: Systemd services
# ============================================================

log "Creating bitcoind systemd service"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Bitcoin daemon
After=network.target

[Service]
ExecStart=/usr/local/bin/bitcoind -conf=$CONF
User=$BITCOIN_USER
Group=$BITCOIN_USER
Restart=on-failure
TimeoutStopSec=600

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable bitcoind

# ============================================================
# Step 7: Tor post-IBD script + service
# ============================================================

log "Creating Tor post-IBD script"
cat > "$TOR_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -e

if ! systemctl is-active --quiet bitcoind; then
    echo "bitcoind not running"
    exit 1
fi

BLOCKS=$(bitcoin-cli getblockcount || echo 0)
if [ "$BLOCKS" -lt 500000 ]; then
    echo "Not past initial block download"
    exit 0
fi

echo "Enabling Tor hidden services (post-IBD)"
# Insert Tor configuration changes here if desired
EOF

chmod +x "$TOR_SCRIPT"

log "Creating Tor post-IBD systemd unit"
cat > "$TOR_SERVICE_FILE" <<EOF
[Unit]
Description=Enable Tor config after IBD
After=bitcoind.service

[Service]
Type=oneshot
ExecStart=$TOR_SCRIPT

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable enable-tor-post-ibd

# ============================================================
# Done
# ============================================================

log "Bitcoin Core ${VERSION} installation complete"
log "Start with:  systemctl start bitcoind"
