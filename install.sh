#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/srv/storj"
NODE_ID="node01"
NODE_DIR="$BASE_DIR/$NODE_ID"
IDENTITY_NAME="storagenode"
ARCH="arm64"

# ====== Input user ======
read -rp "Wallet address (0x…): " WALLET
read -rp "Email untuk Storj: " EMAIL
read -rp "Public address (FQDN/IP:28967) [auto-detect jika kosong]: " ADDRESS
read -rp "Kapasitas storage (mis: 900GB): " STORAGE
read -rp "Device HDD (contoh: /dev/sda1): " HDD_DEV

# ====== Auto detect IP publik jika kosong ======
if [ -z "$ADDRESS" ]; then
  PUBIP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || echo "0.0.0.0")
  ADDRESS="${PUBIP}:28967"
  echo "📡 Public address otomatis terdeteksi: $ADDRESS"
fi

# ====== Install Docker & Compose ======
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg unzip
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
fi

# ====== Mount HDD ke /srv/storj/node01 ======
sudo mkdir -p "$NODE_DIR"
UUID=$(blkid -s UUID -o value "$HDD_DEV")
if ! grep -q "$UUID" /etc/fstab; then
  echo "UUID=$UUID  $NODE_DIR  ext4  defaults  0  2" | sudo tee -a /etc/fstab
fi
sudo mount -a

# ====== Buat folder ======
mkdir -p "$NODE_DIR"/{identity,config,logs}

# ====== Identity binary (arm64) ======
if ! command -v identity >/dev/null; then
  curl -L "https://github.com/storj/storj/releases/latest/download/identity_linux_${ARCH}.zip" -o /tmp/identity.zip
  unzip -o /tmp/identity.zip -d /tmp/
  chmod +x /tmp/identity
  sudo mv /tmp/identity /usr/local/bin/identity
fi

# ====== Generate identity ======
IDENTITY_SRC="$HOME/.local/share/storj/identity/$IDENTITY_NAME"
IDENTITY_DST="$NODE_DIR/identity/$IDENTITY_NAME"

if [ ! -d "$IDENTITY_SRC" ]; then
  echo "🔑 Membuat identity baru..."
  identity create "$IDENTITY_NAME"
fi

if [ ! -d "$IDENTITY_DST" ]; then
  echo "📂 Menyalin identity ke $IDENTITY_DST"
  mkdir -p "$IDENTITY_DST"
  cp -r "$IDENTITY_SRC"/* "$IDENTITY_DST/"
fi

# ====== .env file ======
cat > "$NODE_DIR/.env" <<EOF
UID=$(id -u)
GID=$(id -g)
WALLET=$WALLET
EMAIL=$EMAIL
ADDRESS=$ADDRESS
STORAGE=$STORAGE
NODE_DIR=$NODE_DIR
IDENTITY_NAME=$IDENTITY_NAME
EOF

# ====== docker-compose.yml node ======
cat > "$NODE_DIR/docker-compose.yml" <<'YAML'
services:
  storagenode:
    image: storjlabs/storagenode:latest
    container_name: storagenode
    restart: unless-stopped
    stop_grace_period: 300s
    user: "${UID}:${GID}"
    ports:
      - "28967:28967/tcp"
      - "28967:28967/udp"
      - "127.0.0.1:14002:14002"
    environment:
      - WALLET=${WALLET}
      - EMAIL=${EMAIL}
      - ADDRESS=${ADDRESS}
      - STORAGE=${STORAGE}
    volumes:
      - ${NODE_DIR}/identity/${IDENTITY_NAME}:/app/identity
      - ${NODE_DIR}/config:/app/config
      - ${NODE_DIR}/logs:/app/logs
YAML

# ====== Setup node (sekali) ======
docker pull storjlabs/storagenode:latest
docker run --rm -e SETUP="true" \
  --user "$(id -u)":"$(id -g)" \
  --mount type=bind,source="${NODE_DIR}/identity/${IDENTITY_NAME}",destination=/app/identity \
  --mount type=bind,source="${NODE_DIR}/config",destination=/app/config \
  storjlabs/storagenode:latest || true

# ====== Monitoring stack ======
MON_DIR="$BASE_DIR/monitoring"
mkdir -p "$MON_DIR"
cat > "$MON_DIR/docker-compose.yml" <<'YAML'
services:
  storj-exporter:
    image: anclrii/storj-exporter:latest
    container_name: storj-exporter
    restart: unless-stopped
    ports:
      - "9651:9651"
    environment:
      - STORJ_HOST=storagenode

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    ports:
      - "3000:3000"
YAML

cat > "$MON_DIR/prometheus.yml" <<'YAML'
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: "storj"
    static_configs:
      - targets: ["storj-exporter:9651"]
YAML

# ====== systemd service ======
sudo tee /etc/systemd/system/storj.service >/dev/null <<EOF
[Unit]
Description=Storj Node (docker compose)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$NODE_DIR
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reexec
sudo systemctl enable storj.service
sudo systemctl start storj.service

echo "====================================================="
echo "✅ Instalasi Storj Node selesai!"
echo "Dashboard node : http://127.0.0.1:14002"
echo "Prometheus     : http://<IP_STB>:9090"
echo "Grafana        : http://<IP_STB>:3000 (admin/admin)"
echo "HDD mounted ke : $NODE_DIR"
echo "Identity aktif : $NODE_DIR/identity/$IDENTITY_NAME"
echo "Public address : $ADDRESS"
echo "====================================================="
