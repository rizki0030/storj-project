#!/bin/bash
set -e

### === Konfigurasi User ===
DOMAIN="your domain"
DUCKDNS_TOKEN="your tokens"
EMAIL="yor email"
WALLET="your wallet"
NODE_NAME="storjnode"
STORAGE="/srv/storj/node01"
HDD_DEV="/dev/sda1"
STORAGE_SIZE="900GB"   # Sesuaikan kapasitas HDD

install_node() {
    echo "[1/7] Update sistem..."
    apt-get update && apt-get upgrade -y
    apt-get install -y docker.io curl ufw wget cron netcat

    echo "[2/7] Mount HDD ke $STORAGE ..."
    mkdir -p $STORAGE
    mount $HDD_DEV $STORAGE || true
    grep -q "$HDD_DEV" /etc/fstab || echo "$HDD_DEV $STORAGE ext4 defaults 0 2" >> /etc/fstab

    echo "[3/7] Siapkan direktori Storj..."
    mkdir -p $STORAGE/identity
    mkdir -p $STORAGE/storage/blobs
    mkdir -p $STORAGE/storage/temp
    mkdir -p $STORAGE/storage/trash

    echo "[4/7] Setup DuckDNS updater..."
    mkdir -p /opt/duckdns
    cat <<EOF > /opt/duckdns/duck.sh
#!/bin/bash
echo url="https://www.duckdns.org/update?domains=${DOMAIN%%.*}&token=$DUCKDNS_TOKEN&ip=" | curl -k -o /opt/duckdns/duck.log -K -
EOF
    chmod +x /opt/duckdns/duck.sh
    crontab -l 2>/dev/null | grep -v 'duck.sh' | crontab -
    (crontab -l 2>/dev/null; echo "*/5 * * * * /opt/duckdns/duck.sh >/dev/null 2>&1") | crontab -

    echo "[5/7] Deploy Storj node Docker..."
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

    echo "[6/7] Konfigurasi firewall..."
    ufw allow 28967/tcp
    ufw allow 28967/udp
    ufw allow 14002/tcp
    ufw --force enable

    echo "[7/7] Mengecek port terbuka..."
    if nc -z -v -w5 $DOMAIN 28967; then
      echo "✅ Port 28967 terbuka dan dapat diakses!"
    else
      echo "❌ Port 28967 masih tertutup. Periksa port forwarding di router!"
    fi

    echo "=== Setup selesai! ==="
    echo "📊 Dashboard Lokal  : http://$(hostname -I | awk '{print $1}'):14002"
    echo "🌍 Dashboard Publik : http://$DOMAIN:14002"
    echo "🔗 Node address     : $DOMAIN:28967"
}

reset_node() {
    echo "[1/3] Stop & hapus container lama..."
    docker stop $NODE_NAME || true
    docker rm $NODE_NAME || true

    echo "[2/3] Hapus isi folder storage lama..."
    rm -rf $STORAGE/storage
    mkdir -p $STORAGE/storage/blobs
    mkdir -p $STORAGE/storage/temp
    mkdir -p $STORAGE/storage/trash

    echo "[3/3] Folder identity tetap aman di: $STORAGE/identity"
    echo "✅ Reset selesai. Jalankan kembali menu Install untuk deploy ulang."
}

check_port() {
    echo "🔍 Mengecek port 28967 di $DOMAIN ..."
    if nc -z -v -w5 $DOMAIN 28967; then
      echo "✅ Port 28967 terbuka dan dapat diakses!"
    else
      echo "❌ Port 28967 masih tertutup. Periksa port forwarding di router!"
    fi
}

while true; do
    clear
    echo "=== Storj Node Manager ==="
    echo "1) Install / Setup Node"
    echo "2) Reset Node (hapus storage, simpan identity)"
    echo "3) Cek Port 28967"
    echo "4) Keluar"
    read -p "Pilih menu [1-4]: " choice

    case $choice in
        1) install_node ;;
        2) reset_node ;;
        3) check_port ;;
        4) exit 0 ;;
        *) echo "Pilihan tidak valid"; sleep 2 ;;
    esac

    read -p "Tekan [Enter] untuk kembali ke menu..."
done
