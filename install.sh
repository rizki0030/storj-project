#!/bin/bash
# ==========================================
# Storj Miner Setup - STB B860H + HDD 1TB
# Fixed & Final Version (Auto + Monitoring)
# ==========================================

# CONFIG: Ganti sesuai kebutuhan
WALLET="0x5534E4Dc87F591076843F2Cfbbfb842a91096ec6"
EMAIL="rizkiwahyuariyanto0030@gmail.com"
ALERT_EMAIL="YOUR_ALERT_EMAIL@gmail.com"
SMTP_SERVER="smtp.gmail.com"
SMTP_PORT="587"
SMTP_USER="rizkiwahyuariyanto0030@gmail.com"
SMTP_PASS="@Linux090593"

STORJ_PATH="/mnt/storj"
IDENTITY_SRC="/root/identity"

echo "[*] Updating system & installing dependencies..."
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y docker.io docker-compose curl jq netcat msmtp

sudo systemctl enable docker
sudo systemctl start docker

# 1️⃣ Deteksi HDD otomatis
echo "[*] Detecting external HDD..."
HDD_DEVICE=$(lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep "disk" | grep -v "mmc" | awk '{print "/dev/"$1}' | head -n 1)

if [ -z "$HDD_DEVICE" ]; then
    echo "[ERROR] No external HDD detected!"
    exit 1
fi
echo "[OK] Found HDD: $HDD_DEVICE"

# 2️⃣ Mount HDD
echo "[*] Preparing and mounting HDD..."
sudo mkdir -p $STORJ_PATH
sudo mkfs.ext4 -F $HDD_DEVICE
sudo mount $HDD_DEVICE $STORJ_PATH

if ! grep -qs "$STORJ_PATH" /etc/fstab; then
    echo "$HDD_DEVICE $STORJ_PATH ext4 defaults 0 2" | sudo tee -a /etc/fstab
fi

# 3️⃣ Copy identity
if [ ! -d "$IDENTITY_SRC" ]; then
    echo "[ERROR] Identity folder not found at $IDENTITY_SRC"
    exit 1
fi

echo "[*] Copying Storj identity..."
sudo mkdir -p $STORJ_PATH/identity
sudo cp -r $IDENTITY_SRC/* $STORJ_PATH/identity/
sudo chown -R 1000:1000 $STORJ_PATH/identity

# 4️⃣ Storage folder
echo "[*] Preparing storage folder..."
sudo mkdir -p $STORJ_PATH/storagenode
sudo chown -R 1000:1000 $STORJ_PATH/storagenode

# 5️⃣ Get Public IP automatically
PUBLIC_IP=$(curl -s https://api64.ipify.org)
if [ -z "$PUBLIC_IP" ]; then
    echo "[ERROR] Cannot detect public IP"
    exit 1
fi
echo "[OK] Public IP detected: $PUBLIC_IP"

# 6️⃣ Create docker-compose.yml
echo "[*] Creating docker-compose.yml..."
cat <<EOF > $STORJ_PATH/docker-compose.yml
version: '3.7'

services:
  storagenode:
    image: storjlabs/storagenode:latest
    container_name: storagenode
    restart: unless-stopped
    environment:
      - WALLET=$WALLET
      - EMAIL=$EMAIL
      - ADDRESS=$PUBLIC_IP:28967
      - STORAGE=/mnt/storj/storagenode
      - IDENTITY=/mnt/storj/identity
      - BANDWIDTH=100TB
      - LOG_LEVEL=info
    ports:
      - "28967:28967"
      - "14002:14002"
    volumes:
      - /mnt/storj/storagenode:/mnt/storj/storagenode
      - /mnt/storj/identity:/mnt/storj/identity

  prometheus:
    image: prom/prometheus
    container_name: prometheus
    restart: unless-stopped
    ports:
      - "9090:9090"
    volumes:
      - /mnt/storj/prometheus.yml:/etc/prometheus/prometheus.yml

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    ports:
      - "3000:3000"
    volumes:
      - /mnt/storj/grafana:/var/lib/grafana
EOF

# 7️⃣ Prometheus config
cat <<EOF > $STORJ_PATH/prometheus.yml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'storj'
    static_configs:
      - targets: ['storagenode:14002']
EOF

# 8️⃣ Setup Email Alert via msmtp
echo "[*] Configuring email alert..."
cat <<EOF | sudo tee /etc/msmtprc
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

chmod 600 /etc/msmtprc

# 9️⃣ Start all containers
echo "[*] Starting Storj + Monitoring..."
cd $STORJ_PATH
sudo docker-compose up -d

# 🔟 Check port 28967
echo "[*] Checking port 28967 connectivity..."
nc -z -v -w5 $PUBLIC_IP 28967
if [ $? -eq 0 ]; then
    echo "[✓] Port 28967 is OPEN and reachable!"
else
    echo "[!] Port 28967 is CLOSED."
    echo "    -> Pastikan port forwarding di router ke STB sudah diatur."
    echo "    -> IP publik: $PUBLIC_IP"
    echo "Mengirim notifikasi email..."
    echo "Warning: Port 28967 closed on $PUBLIC_IP" | msmtp $ALERT_EMAIL
fi

echo ""
echo "======================================="
echo "[✓] Storj Miner setup complete!"
echo "Wallet   : $WALLET"
echo "Email    : $EMAIL"
echo "PublicIP : $PUBLIC_IP"
echo "Identity : $STORJ_PATH/identity"
echo "Storage  : $STORJ_PATH/storagenode"
echo "Grafana  : http://$PUBLIC_IP:3000 (admin/admin)"
echo "Prometheus: http://$PUBLIC_IP:9090"
echo "======================================="
echo "Check Storj logs: sudo docker logs -f storagenode"
