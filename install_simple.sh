#!/bin/bash
set -e

echo "=== Setup Storj Node (Simple Version) ==="

# --- Konfigurasi manual ---
NODE_NAME="node01"
WALLET="0xISI_WALLET_KAMU"
EMAIL="emailkamu@example.com"
STORAGE="900GB"                       # kapasitas HDD yg dipakai
MOUNTPOINT="/mnt/hdd1"                # lokasi HDD
ADDRESS="$(curl -s ifconfig.me):28967" # auto detect IP publik

# --- Persiapan paket dasar ---
apt-get update
apt-get install -y \
    curl gnupg ca-certificates unzip \
    apt-transport-https software-properties-common

# --- Install Docker ---
if ! command -v docker &> /dev/null; then
    echo "Install Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
fi

# --- Buat folder node ---
mkdir -p /srv/storj/${NODE_NAME}/identity
mkdir -p /srv/storj/${NODE_NAME}/storage

# --- Copy identity kalau ada ---
if [ -d "$HOME/.local/share/storj/identity/storagenode" ]; then
    cp -r $HOME/.local/share/storj/identity/storagenode/* /srv/storj/${NODE_NAME}/identity/
    echo "Identity berhasil dicopy ke /srv/storj/${NODE_NAME}/identity/"
else
    echo "!!! Identity belum ada. Generate dulu pakai:"
    echo "    identity create storagenode"
    exit 1
fi

# --- Jalankan node ---
docker run -d --restart unless-stopped --stop-timeout 300 \
    -p 28967:28967/tcp \
    -p 28967:28967/udp \
    -p 14002:14002 \
    -e WALLET="${WALLET}" \
    -e EMAIL="${EMAIL}" \
    -e ADDRESS="${ADDRESS}" \
    -e STORAGE="${STORAGE}" \
    --mount type=bind,source=/srv/storj/${NODE_NAME}/identity,destination=/app/identity \
    --mount type=bind,source=/srv/storj/${NODE_NAME}/storage,destination=/app/config \
    --name ${NODE_NAME} \
    storjlabs/storagenode:latest

echo "=== Storj Node ${NODE_NAME} berhasil dijalankan ==="
echo "Dashboard lokal: http://<IP-STB>:14002/"
