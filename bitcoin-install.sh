#!/usr/bin/env bash
set -euo pipefail

# =============================
# CONFIGURATION
# =============================
BIN_DIR="/usr/local/bin"
WORK_DIR="$(mktemp -d)"
KEYSERVER="hkps://keys.openpgp.org"

# Trusted GPG keys (verify fingerprints independently!)
TRUSTED_KEYS=(
  "71A3B16735405025D447E8F274810B012346C9A6"  # Wladimir van der Laan
  "133EAC179436F14A5CF1B794860FEB804E669320"  # Pieter Wuille
)

DOWNLOAD_BASE_URL="https://bitcoincore.org/bin"
ARCH="x86_64-linux-gnu"

BITCOIN_USER="satoshi"
DATA_DIR="/home/$BITCOIN_USER/.bitcoin"
SERVICE_FILE="/etc/systemd/system/bitcoind.service"
TOR_SERVICE_FILE="/etc/systemd/system/enable-tor-post-ibd.service"
TOR_SCRIPT="/usr/local/bin/enable-tor-post-ibd.sh"

# =============================
# FUNCTIONS
# =============================
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

log() { echo "$(date +'%F %T') - $*"; }
error_exit() { echo "ERROR: $*" >&2; exit 1; }

# =============================
# MAIN
# =============================
log "Starting Bitcoin Core installation"

# Require root
if [ "$(id -u)" -ne 0 ]; then
  error_exit "This script must be run as root (use sudo)"
fi

# =============================
# INSTALL DEPENDENCIES
# =============================
log "Updating package lists and installing dependencies"
apt-get update
apt-get install -y curl gnupg2 ca-certificates jq tor || error_exit "Failed to install required packages"

# Ensure Tor service is enabled and running
log "Enabling and starting Tor service"
systemctl enable tor
systemctl start tor

cd "$WORK_DIR"

# Import GPG keys
log "Importing trusted GPG keys"
for key in "${TRUSTED_KEYS[@]}"; do
  gpg --keyserver "$KEYSERVER" --recv-keys "$key" || error_exit "Failed to import key $key"
done

# Determine version
echo -n "Enter Bitcoin Core version to install (e.g., 28.1): "
read VERSION
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
  error_exit "Invalid version format: $VERSION"
fi

TARBALL="bitcoin-${VERSION}-${ARCH}.tar.gz"
CHECKSUM_FILE="SHA256SUMS"
SIGNATURE_FILE="SHA256SUMS.asc"

DOWNLOAD_URL="$DOWNLOAD_BASE_URL/bitcoin-core-${VERSION}/$TARBALL"
CHECKSUM_URL="$DOWNLOAD_BASE_URL/bitcoin-core-${VERSION}/$CHECKSUM_FILE"
SIGNATURE_URL="$DOWNLOAD_BASE_URL/bitcoin-core-${VERSION}/$SIGNATURE_FILE"

# Download files
log "Downloading Bitcoin Core tarball and verification files"
curl -fLO "$DOWNLOAD_URL" || error_exit "Failed to download $TARBALL"
curl -fLO "$CHECKSUM_URL" || error_exit "Failed to download $CHECKSUM_FILE"
curl -fLO "$SIGNATURE_URL" || error_exit "Failed to download $SIGNATURE_FILE"

# Verify signature and checksum
# Step: verify the signature  
log "Verifying GPG signature of checksum file"  
if ! gpg --verify "$SIGNATURE_FILE" "$CHECKSUM_FILE" 2>&1 | tee gpg_verify.log; then  
    error_exit "GPG signature verification failed"  
fi  

# Extract the list of *signer key IDs* that made a **good signature**  
VALID_SIG_KEYS=$(grep -E 'Good signature from' gpg_verify.log | \
    sed -E 's/.*key ID ([A-Fa-f0-9]+).*/\1/' | tr 'a-f' 'A-F' | sort -u)  

if [ -z "$VALID_SIG_KEYS" ]; then  
    error_exit "No valid signatures found."  
fi  

log "Signer key IDs with good signatures: $VALID_SIG_KEYS"  

# Now verify that **each trusted key** signed the file  
for trusted in "${TRUSTED_KEYS[@]}"; do  
    # Normalize to uppercase hex (GPG output is uppercase)  
    trusted_upper=$(echo "$trusted" | tr 'a-f' 'A-F')  
    if ! echo "$VALID_SIG_KEYS" | grep -q "$trusted_upper"; then  
        error_exit "Trusted key $trusted did NOT sign the checksum!"  
    fi  
done  

log "All trusted keys successfully signed the checksum. Continuing…" 

log "Verifying tarball checksum"
grep "$TARBALL" "$CHECKSUM_FILE" | sha256sum --check --ignore-missing || error_exit "Checksum verification failed"

# Extract to /tmp
TMP_EXTRACT_DIR="/tmp/bitcoin-core-${VERSION}"
log "Extracting tarball to $TMP_EXTRACT_DIR"
rm -rf "$TMP_EXTRACT_DIR"
mkdir -p "$TMP_EXTRACT_DIR"
tar -xzf "$TARBALL" -C "$TMP_EXTRACT_DIR"
EXTRACTED_DIR="$TMP_EXTRACT_DIR/bitcoin-${VERSION}"

# Install binaries
log "Installing binaries to $BIN_DIR"
install -m 0755 -o root -g root -t "$BIN_DIR" "$EXTRACTED_DIR/bin/"*

# Create data directory
log "Creating data directory at $DATA_DIR"
mkdir -p "$DATA_DIR"
chown -R "$BITCOIN_USER":"$BITCOIN_USER" "$DATA_DIR"
chmod 700 "$DATA_DIR"

# Create bitcoin.conf with daemon enabled and basic settings
log "Writing bitcoin.conf"
cat > "$DATA_DIR/bitcoin.conf" <<EOF
listen=1
server=1
daemon=1
txindex=1
rpcuser=bitcoin
rpcpassword=bitcoin
disablewallet=1
dbcache=2048
maxconnections=125
EOF
chown "$BITCOIN_USER":"$BITCOIN_USER" "$DATA_DIR/bitcoin.conf"
chmod 600 "$DATA_DIR/bitcoin.conf"

# =============================
# SYSTEMD SERVICE FOR BITCOIND
# =============================
log "Creating systemd service at $SERVICE_FILE"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Bitcoin daemon
Documentation=https://github.com/bitcoin/bitcoin/blob/master/doc/init.md
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$BIN_DIR/bitcoind -conf=$DATA_DIR/bitcoin.conf -datadir=$DATA_DIR -pid=/run/bitcoind/bitcoind.pid
Type=forking
PIDFile=/run/bitcoind/bitcoind.pid
Restart=unless-stopped
TimeoutStartSec=600
TimeoutStopSec=600

User=$BITCOIN_USER
Group=$BITCOIN_USER
RuntimeDirectory=bitcoind
RuntimeDirectoryMode=0710

PrivateTmp=true
ProtectSystem=full
NoNewPrivileges=true
PrivateDevices=true
MemoryDenyWriteExecute=true
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd, enable and start service
log "Reloading systemd and starting bitcoind"
systemctl daemon-reload
systemctl enable bitcoind
systemctl start bitcoind

# =============================
# POST-IBD TOR CONFIGURATION (BACKGROUND)
# =============================
log "Creating post-IBD Tor enable script at $TOR_SCRIPT"
cat > "$TOR_SCRIPT" <<'EOF'
#!/usr/bin/env bash
BITCOIN_CLI="bitcoin-cli -conf=/home/satoshi/.bitcoin/bitcoin.conf -datadir=/home/satoshi/.bitcoin"
CONF_FILE="/home/satoshi/.bitcoin/bitcoin.conf"

while $BITCOIN_CLI getblockchaininfo | jq -e '.initialblockdownload' >/dev/null; do
    sleep 60
done

cat >> "$CONF_FILE" <<EOC

# Tor-only configuration
proxy=127.0.0.1:9050
listen=1
bind=127.0.0.1
onlynet=onion
EOC

chown satoshi:satoshi "$CONF_FILE"
chmod 600 "$CONF_FILE"

systemctl restart bitcoind
EOF
chmod +x "$TOR_SCRIPT"

log "Creating background systemd service for post-IBD Tor configuration"
cat > "$TOR_SERVICE_FILE" <<EOF
[Unit]
Description=Enable Tor for Bitcoin Core after IBD
After=bitcoind.service
Wants=bitcoind.service

[Service]
Type=simple
ExecStart=$TOR_SCRIPT
User=$BITCOIN_USER
Group=$BITCOIN_USER
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now enable-tor-post-ibd.service

log "Bitcoin Core installation complete. Tor will be enabled automatically after IBD finishes."
log "Check bitcoind status: sudo systemctl status bitcoind"
