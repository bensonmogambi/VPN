#!/usr/bin/env bash
# WireGuard VPN + ad-blocking DNS + multi-device manager (wgctl) + hardening.
# Run as root on a fresh Ubuntu 22.04/24.04 VM (works on Oracle Cloud Free Tier):
#   sudo bash setup-vpn-plus.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

PORT=51820
NET=10.8.0
IFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
PUBIP=$(curl -s https://api.ipify.org)

# ---- packages ----
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
mkdir -p /etc/dnsmasq.d
cat > /etc/dnsmasq.d/vpn.conf <<EOF
listen-address=$NET.1
bind-dynamic
no-resolv
server=1.1.1.1
server=9.9.9.9
cache-size=2000
addn-hosts=/etc/dnsmasq-blocklist.hosts
EOF
apt-get update -y
apt-get install -y wireguard qrencode iptables iptables-persistent dnsmasq fail2ban unattended-upgrades curl

# ---- server keys + config ----
umask 077
mkdir -p /etc/wireguard/clients && cd /etc/wireguard
wg genkey | tee server.key | wg pubkey > server.pub
cat > params <<EOF
PUBIP=$PUBIP
PORT=$PORT
NET=$NET
EOF

cat > wg0.conf <<EOF
[Interface]
Address = $NET.1/24
ListenPort = $PORT
PrivateKey = $(cat server.key)
PostUp = iptables -I FORWARD -i wg0 -j ACCEPT; iptables -I FORWARD -o wg0 -j ACCEPT; iptables -I INPUT -i wg0 -p udp --dport 53 -j ACCEPT; iptables -I INPUT -i wg0 -p tcp --dport 53 -j ACCEPT; iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -D INPUT -i wg0 -p udp --dport 53 -j ACCEPT; iptables -D INPUT -i wg0 -p tcp --dport 53 -j ACCEPT; iptables -t nat -D POSTROUTING -o $IFACE -j MASQUERADE
EOF

echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wg.conf
sysctl --system >/dev/null

# open VPN port ahead of Oracle's default reject rule, and persist it
iptables -C INPUT -p udp --dport $PORT -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport $PORT -j ACCEPT
netfilter-persistent save
command -v ufw >/dev/null && ufw allow $PORT/udp || true

# ---- ad/tracker blocking DNS ----
cat > /usr/local/bin/update-blocklist <<'EOF'
#!/usr/bin/env bash
curl -fsS https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts \
  | grep '^0.0.0.0 ' | grep -v '^0.0.0.0 0.0.0.0$' > /etc/dnsmasq-blocklist.hosts.new \
  && mv /etc/dnsmasq-blocklist.hosts.new /etc/dnsmasq-blocklist.hosts \
  && systemctl reload dnsmasq 2>/dev/null || true
EOF
chmod +x /usr/local/bin/update-blocklist
touch /etc/dnsmasq-blocklist.hosts
/usr/local/bin/update-blocklist || true
echo "0 4 * * 0 root /usr/local/bin/update-blocklist" > /etc/cron.d/update-blocklist

mkdir -p /etc/systemd/system/dnsmasq.service.d
cat > /etc/systemd/system/dnsmasq.service.d/override.conf <<EOF
[Unit]
After=wg-quick@wg0.service
Wants=wg-quick@wg0.service
EOF
systemctl daemon-reload

# ---- hardening ----
systemctl enable --now fail2ban
echo 'APT::Periodic::Update-Package-Lists "1"; APT::Periodic::Unattended-Upgrade "1";' > /etc/apt/apt.conf.d/20auto-upgrades

# ---- wgctl: multi-device manager ----
cat > /usr/local/bin/wgctl <<'EOF'
#!/usr/bin/env bash
# wgctl add <name> | remove <name> | list | show <name>
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
cd /etc/wireguard; source params; umask 077
cmd=${1:-}; name=${2:-}

case "$cmd" in
add)
  [ -n "$name" ] || { echo "usage: wgctl add <name>"; exit 1; }
  [ ! -f clients/$name.conf ] || { echo "$name already exists"; exit 1; }
  n=2; while grep -qs "Address = $NET.$n/" clients/*.conf; do n=$((n+1)); done
  [ $n -lt 255 ] || { echo "subnet full"; exit 1; }
  priv=$(wg genkey); pub=$(echo "$priv" | wg pubkey); psk=$(wg genpsk)
  printf '\n# %s\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s.%s/32\n' \
    "$name" "$pub" "$psk" "$NET" "$n" >> wg0.conf
  echo "$psk" > /tmp/psk.$$ && wg set wg0 peer "$pub" preshared-key /tmp/psk.$$ allowed-ips "$NET.$n/32"; rm -f /tmp/psk.$$
  echo "$pub" > clients/$name.pub
  cat > clients/$name.conf <<CONF
[Interface]
PrivateKey = $priv
Address = $NET.$n/24
DNS = $NET.1

[Peer]
PublicKey = $(cat server.pub)
PresharedKey = $psk
Endpoint = $PUBIP:$PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
CONF
  # Linux/macOS client variant with kill switch (blocks all traffic if tunnel drops)
  { sed '/^DNS/q' clients/$name.conf; \
    echo 'PostUp = iptables -I OUTPUT ! -o %i -m mark ! --mark $(wg show %i fwmark) -m addrtype ! --dst-type LOCAL -j REJECT'; \
    echo 'PreDown = iptables -D OUTPUT ! -o %i -m mark ! --mark $(wg show %i fwmark) -m addrtype ! --dst-type LOCAL -j REJECT'; \
    sed -n '/^$/,$p' clients/$name.conf; } > clients/$name-linux-killswitch.conf
  echo "Added '$name' ($NET.$n). Config: /etc/wireguard/clients/$name.conf"
  qrencode -t ansiutf8 < clients/$name.conf
  ;;
remove)
  [ -f clients/$name.conf ] || { echo "no such client"; exit 1; }
  wg set wg0 peer "$(cat clients/$name.pub)" remove
  awk -v n="$name" 'BEGIN{RS="";ORS="\n\n"} $0 !~ "^# "n"\n"' wg0.conf > wg0.new && mv wg0.new wg0.conf
  rm -f clients/$name.*  clients/$name-linux-killswitch.conf
  echo "Removed '$name'"
  ;;
show)
  [ -f clients/$name.conf ] || { echo "no such client"; exit 1; }
  qrencode -t ansiutf8 < clients/$name.conf; cat clients/$name.conf
  ;;
list)
  for f in clients/*.conf; do
    [ -e "$f" ] || continue
    b=$(basename "$f" .conf); case $b in *-linux-killswitch) continue;; esac
    pub=$(cat clients/$b.pub)
    printf '%-14s %-12s ' "$b" "$(grep ^Address $f | awk '{print $3}')"
    wg show wg0 dump | awk -v p="$pub" '$1==p {printf "last-seen:%s  rx:%.1fMB tx:%.1fMB\n", ($5==0?"never":strftime("%F %T",$5)), $6/1048576, $7/1048576}'
  done
  ;;
*) echo "usage: wgctl add|remove|show <name> | wgctl list"; exit 1;;
esac
EOF
chmod +x /usr/local/bin/wgctl

# ---- go ----
systemctl enable --now wg-quick@wg0
systemctl enable --now dnsmasq && systemctl restart dnsmasq

wgctl add phone
echo
echo "Done. Manage devices with:  sudo wgctl add laptop | list | show <name> | remove <name>"
echo "Kill-switch configs for Linux/macOS: /etc/wireguard/clients/<name>-linux-killswitch.conf"
