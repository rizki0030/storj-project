#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# ==========================================
# Storj Miner Setup - STB B860H + HDD 1TB
# Fixed & Robust Version (Auto + Monitoring)
# - Installs Docker (official)
# - Installs netcat-openbsd, msmtp
# - Detects HDD, formats only if needed
# - Uses UUID in /etc/fstab
# - Searches for identity in several locations
# - Uses docker compose (plugin)
# ==========================================

# -------------------------
# CONFIG - EDIT BEFORE RUN
# -------------------------
WALLET="0x5534E4Dc87F591076843F2Cfbbfb842a91096ec6"
EMAIL="rizkiwahyuariyanto0030@gmail.com"
ALERT_EMAIL="YOUR_ALERT_EMAIL@gmail.com"
SMTP_SERVER="smtp.gmail.com"
SMTP_PORT="587"
SMTP_USER="rizkiwahyuariyanto0030@gmail.com"
SMTP_PASS="@Linux090593"   # e.g. Gmail app password
STORJ_PATH="/mnt/storj"
# locations where the script will look for identity folder (in order)
IDENTITY_SEARCH=(
  "/root/identity"
  "/home/armbian/identity"
  "/home/root/identity"
  "./identity"
  "$HOME/identity"
)
# -------------------------

echo "==== START Storj Final Fixed Setup ===="

# 1) basic apt update and required packages
echo "[1/12] Update & install base packages..."
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y curl jq ca-certificates apt-transport-https lsb-release gnupg

# netcat package for port check
sudo apt-get install -y netcat-openbsd msmtp

# 2) Install Docker via official convenience script (reliable on Armbian)
echo "[2/12] Installing Docker (official)..."
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sudo sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
fi

# enable and start docker
sudo systemctl enable docker || true
sudo systemctl start docker || true

# Install docker compose plugin (if available)
echo "[3/12] Installing docker compose plugin..."
# On Debian/Armbian newer: package docker-compose-plugin
if ! dpkg -s docker-compose-plugin >/dev/null 2>&1; then
  sudo apt-get install -y docker-compose-plugin || true
fi

# If 'docker compose' not found but plugin installed in other path, try to detect and symlink
if ! docker compose version >/dev/null 2>&1; then
  # try common plugin paths
  POSSIBLE_PLUGIN=$(find / -type f -name docker-compose -maxdepth 5 2>/dev/null | head -n1 || true)
  if [ -n "$POSSIBLE_PLUGIN" ]; then
    sudo mkdir -p /usr/local/lib/docker/cli-plugins || true
    sudo ln -sf "$POSSIBLE_PLUGIN" /usr/local/lib/docker/cli-plugins/docker-compose || true
  fi
fi

# final check
if ! docker --version >/dev/null 2>&1; then
  echo "[ERROR] Docker installation failed. Check logs."
  exit 1
fi
echo "[OK] Docker installed: $(docker --version)"

# 4) Detect HDD
echo "[4/12] Detecting external HDD..."
HDD_DEVICE=$(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}' | grep -v mmcblk | head -n1 || true)

if [ -z "$HDD_DEVICE" ]; then
  echo "[ERROR] No disk device found. Attach your HDD and retry."
  exit 1
fi
echo "[OK] Found disk: $HDD_DEVICE"

# 5) Create mount point
sudo mkdir -p "$STORJ_PATH"

# 6) Check if device has filesystem
FSTYPE=$(blkid -s TYPE -o value "$HDD_DEVICE" || true)
if [ -z "$FSTYPE" ]; then
  echo "[5/12] Device has no filesystem. Creating ext4 filesystem (mkfs.ext4)..."
  # create single partition + format: prefer writing fs on whole disk only if user expects raw disk
  # We'll format the whole device as ext4 (be careful: this destroys data).
  sudo mkfs.ext4 -F "$HDD_DEVICE"
  FSTYPE="ext4"
else
  echo "[5/12] Device filesystem detected: $FSTYPE (will mount without formatting)"
fi

# 7) Get UUID and add to /etc/fstab (if not present), then mount
UUID=$(blkid -s UUID -o value "$HDD_DEVICE" || true)
if [ -z "$UUID" ]; then
  # fallback: use device node
  echo "[WARN] No UUID found, using device path in fstab (less stable)"
  ENTRY="$HDD_DEVICE $STORJ_PATH ext4 defaults 0 2"
else
  ENTRY="UUID=$UUID $STORJ_PATH ext4 defaults 0 2"
fi

if ! grep -qs "$STORJ_PATH" /etc/fstab; then
  echo "$ENTRY" | sudo tee -a /etc/fstab
fi

echo "[6/12] Mounting $HDD_DEVICE -> $STORJ_PATH"
sudo mount "$STORJ_PATH" || ( echo "[ERROR] Mount failed"; exit 1 )

# 8) Find identity folder
echo "[7/12] Locating Storj identity..."
IDENTITY_FOUND=""
for p in "${IDENTITY_SEARCH[@]}"; do
  if [ -d "$p" ]; then
    ID_CAND="$p"
    # simple check: identity folder should contain files like 'ca.key' or 'identity.cert' or 'private.key' -- we'll accept any
    if compgen -G "$p/*" > /dev/null; then
      IDENTITY_FOUND="$p"
      break
    fi
  fi
done

if [ -z "$IDENTITY_FOUND" ]; then
  echo ""
  echo "===================== IDENTITY NOT FOUND ====================="
  echo "Script could not find Storj identity in the default locations."
  echo "Please copy your identity folder to one of these paths on the STB and re-run:"
  printf "  - /root/identity\n  - /home/armbian/identity\n  - /home/root/identity\n  - ./identity (current folder)\n"
  echo ""
  echo "Example from PC: scp -r /path/to/identity root@STB_IP:/root/identity"
  echo "Then re-run this script."
  echo "============================================================="
  exit 1
fi

echo "[OK] Identity found at: $IDENTITY_FOUND"

# 9) Copy identity into mountpoint (store identity under $STORJ_PATH/identity)
echo "[8/12] Copying identity to $STORJ_PATH/identity ..."
sudo mkdir -p "$STORJ_PATH/identity"
sudo rsync -a --delete "$IDENTITY_FOUND"/ "$STORJ_PATH/identity"/
# set ownership to UID 1000 (storagenode image uses 1000 by convention)
sudo chown -R 1000:1000 "$STORJ_PATH/identity"

# 10) Prepare storage folder
echo "[9/12] Preparing storage folder..."
sudo mkdir -p "$STORJ_PATH/storagenode"
sudo chown -R 1000:1000 "$STORJ_PATH/storagenode"

# 11) Detect public IP
echo "[10/12] Detecting public IP..."
PUBLIC_IP=$(curl -s https://api64.ipify.org || true)
if [ -z "$PUBLIC_IP" ]; then
  echo "[WARN] Public IP could not be detected automatically. Please set manually in config"
else
  echo "[OK] Public IP: $PUBLIC_IP"
fi

# 12) Create docker compose + prometheus grafana config
echo "[11/12] Writing docker-compose and prometheus config..."
cat > "$STORJ_PATH/docker-compose.yml" <<EOF
version: '3.8'
services:
  storagenode:
    image: storjlabs/storagenode:latest
    container_name: storagenode
    restart: unless-stopped
    environment:
      - WALLET=$WALLET
      - EMAIL=$EMAIL
      - ADDRESS=${PUBLIC_IP:-0.0.0.0}:28967
      - STORAGE=/mnt/storj/storagenode
      - IDENTITY=/mnt/storj/identity
      - BANDWIDTH=100TB
      - LOG_LEVEL=info
    ports:
      - "28967:28967"
      - "14002:14002"
    volumes:
      - $STORJ_PATH/storagenode:/mnt/storj/storagenode
      - $STORJ_PATH/identity:/mnt/storj/identity

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    ports:
      - "9090:9090"
    volumes:
      - $STORJ_PATH/prometheus.yml:/etc/prometheus/prometheus.yml:ro

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    ports:
      - "3000:3000"
    volumes:
      - $STORJ_PATH/grafana:/var/lib/grafana
EOF

cat > "$STORJ_PATH/prometheus.yml" <<'PROM'
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'storj'
    metrics_path: /metrics
    static_configs:
      - targets: ['storagenode:14002']
PROM

# 13) Configure msmtp (email alerts)
echo "[12/12] Configuring msmtp for alert emails..."
sudo bash -c "cat > /etc/msmtprc" <<EOF
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
account        default
host           $SMTP_SERVER
port           $SMTP_PORT
user           $SMTP_USER
password       $SMTP_PASS
from           $SMTP_USER
logfile        /var/log/msmtp.log
EOF
sudo chmod 600 /etc/msmtprc

# 14) Start docker compose
echo "[FINAL] Starting containers with docker compose..."
cd "$STORJ_PATH"
# prefer 'docker compose' (plugin). If not available, try 'docker-compose'
if docker compose version >/dev/null 2>&1; then
  sudo docker compose up -d
else
  if command -v docker-compose >/dev/null 2>&1; then
    sudo docker-compose up -d
  else
    echo "[ERROR] docker compose not available. Please install docker-compose-plugin."
    exit 1
  fi
fi

# 15) Check port reachability (28967)
echo "[INFO] Checking port 28967 from this host..."
if [ -n "${PUBLIC_IP:-}" ]; then
  if nc -z -w5 "$PUBLIC_IP" 28967 >/dev/null 2>&1; then
    echo "[OK] Port 28967 appears open to public IP ($PUBLIC_IP)."
  else
    echo "[WARN] Port 28967 does NOT appear open from this host to $PUBLIC_IP."
    echo "Sending alert email to $ALERT_EMAIL..."
    echo -e "Subject: Storj Setup Alert - port closed\n\nPort 28967 appears closed on $PUBLIC_IP. Please configure port forwarding to this STB." | msmtp "$ALERT_EMAIL" || true
  fi
else
  echo "[WARN] Public IP unknown; skip remote port check. Check router port-forwarding to the STB manually."
fi

echo ""
echo "======================================="
echo "[✓] Setup finished!"
echo "Storj identity: $STORJ_PATH/identity"
echo "Storage dir   : $STORJ_PATH/storagenode"
echo "Grafana       : http://<STB_IP>:3000  (default admin/admin)"
echo "Prometheus    : http://<STB_IP>:9090"
echo "Check Storj logs: sudo docker logs -f storagenode"
echo "======================================="
