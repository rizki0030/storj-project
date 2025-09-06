#!/bin/bash
set -e

### === Konfigurasi User ===
DOMAIN="YOUR_DOMAIN_DUCKDNS"
DUCKDNS_TOKEN="YOUR_TOKEN_DUCKDNS"
EMAIL="YOUR_EMAIL"
WALLET="YOUR_WALLET"
NODE_NAME="storjnode"
STORAGE="/srv/storj/node01"
HDD_DEV="/dev/sda1"
STORAGE_SIZE="900GB"   # Sesuaikan kapasitas HDD

### === [1/7] Update Sistem ===
echo "[1/7] Update sistem..."
apt-get update && apt-get upgrade -y
apt-get install -y docker.io curl ufw wget cron netcat

### === [2/7] Mount HDD ===
echo "[2/7] Mount HDD ke $STORAGE ..."
mkdir -p $STORAGE
mount $HDD_DEV $STORAGE || true
grep -q "$HDD_DEV" /etc/fstab || echo "$HDD_DEV $STORAGE ext4 defaults 0 2" >> /etc/fstab

### === [3/7] Siapkan Folder Storj ===
echo "[3/7] Siapkan direktori Storj..."
mkdir -p $STORAGE/identity $STORAGE/storage

### === [4/7] Setup DuckDNS Updater ===
echo "[4/7] Setup DuckDNS updater..."
mkdir -p /opt/duckdns
cat <<EOF > /opt/duckdns/duck.sh
#!/bin/bash
echo url="https://www.duckdns.org/update?domains=${DOMAIN%%.*}&token=$DUCKDNS_TOKEN&ip=" | curl -k -o /opt/duckdns/duck.log -K -
EOF
chmod +x /opt/duckdns/duck.sh
# Tambah ke cron job (update tiap 5 menit, hapus duplikat dulu)
crontab -l 2>/dev/null | grep -v 'duck.sh' | crontab -
(crontab -l 2>/dev/null; echo "*/5 * * * * /opt/duckdns/duck.sh >/dev/null 2>&1") | crontab -

### === [5/7] Deploy Storj Node Docker ===
echo "[5/7] Deploy Storj node Docker..."
# Bersih container lama
docker stop $NODE_NAME || true
docker rm $NODE_NAME || true

docker run -d --restart unless-stopped --stop-timeout 300 \
--name $NODE_NAME \
-p 28967:28967/tcp \
-p 28967:28967/udp \
-p 14002:14002 \
-e WALLET="$WALLET" \
-e EMAIL="$EMAIL" \
-e ADDRESS="$DOMAIN:28967" \
-e STORAGE="$STORAGE_SIZE" \
--mount type=bind,source=$STORAGE/identity,destination=/app/identity \
--mount type=bind,source=$STORAGE/storage,destination=/app/config \
storjlabs/storagenode:latest

### === [6/7] Firewall ===
echo "[6/7] Konfigurasi firewall..."
ufw allow 28967/tcp
ufw allow 28967/udp
ufw allow 14002/tcp
ufw --force enable

### === [7/7] Cek Port ===
echo "[7/7] Mengecek port terbuka..."
if nc -z -v -w5 $DOMAIN 28967; then
  echo "✅ Port 28967 terbuka dan dapat diakses!"
else
  echo "❌ Port 28967 masih tertutup. Periksa port forwarding di router!"
fi

### === Selesai ===
echo "=== Setup selesai! ==="
echo "📊 Dashboard Lokal  : http://$(hostname -I | awk '{print $1}'):14002"
echo "🌍 Dashboard Publik : http://$DOMAIN:14002"
echo "🔗 Node address     : $DOMAIN:28967"
