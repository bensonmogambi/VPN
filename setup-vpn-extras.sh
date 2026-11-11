#!/usr/bin/env bash
# Extras for the WireGuard VPN: IPv6, split tunneling, status dashboard,
# usage alerts, port-443 mode. Run AFTER setup-vpn-plus.sh, as root:
#   sudo bash setup-vpn-extras.sh
set -euo pipefail
cd /etc/wireguard
source params   # PUBIP, PORT, NET from the earlier script

# =========================================================
# 1. IPv6 inside the tunnel (stops IPv6 leaks, adds v6 reachability)
# =========================================================
V6NET="fd42:42:42::"
grep -q "Address = $NET.1/24,$V6NET""1/64" wg0.conf || \
  sed -i "s#Address = $NET.1/24#Address = $NET.1/24, ${V6NET}1/64#" wg0.conf

IFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
if ! grep -q "ip6tables" wg0.conf; then
  sed -i "/^PostUp/ s#\$# ; sysctl -w net.ipv6.conf.all.forwarding=1 ; ip6tables -I FORWARD -i wg0 -j ACCEPT ; ip6tables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE#" wg0.conf
  sed -i "/^PostDown/ s#\$# ; ip6tables -D FORWARD -i wg0 -j ACCEPT ; ip6tables -t nat -D POSTROUTING -o $IFACE -j MASQUERADE#" wg0.conf
fi
systemctl restart wg-quick@wg0 || true
echo "[1/5] IPv6 inside the tunnel: done (server has v6 only if the VM itself does)."

# =========================================================
# 2. Split tunneling support in wgctl (wgctl split <name> <cidr1,cidr2,...>)
# =========================================================
if ! grep -q "^split)" /usr/local/bin/wgctl; then
python3 - <<'PYEOF'
import re
p = "/usr/local/bin/wgctl"
s = open(p).read()
addition = '''
split)
  [ -n "$name" ] && [ -n "${3:-}" ] || { echo "usage: wgctl split <name> <cidr1,cidr2,...>"; exit 1; }
  [ -f clients/$name.conf ] || { echo "no such client"; exit 1; }
  ranges="$3"
  sed -i "s#^AllowedIPs = 0.0.0.0/0, ::/0#AllowedIPs = $ranges#" clients/$name.conf
  echo "Client '$name' now only routes: $ranges (everything else uses the device's normal connection)"
  echo "Re-share clients/$name.conf with the device."
  ;;
'''
s = s.replace('*) echo "usage: wgctl add|remove|show <name> | wgctl list"; exit 1;;',
              addition + '*) echo "usage: wgctl add|remove|show|split <name> | wgctl list"; exit 1;;')
open(p, "w").write(s)
PYEOF
fi
echo "[2/5] Split tunneling: use 'sudo wgctl split <name> 192.168.1.0/24,10.0.0.0/8'"

# =========================================================
# 3. Read-only status dashboard (password protected, port 8080)
# =========================================================
apt-get install -y apache2-utils python3 >/dev/null
DASH_USER="admin"
DASH_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
htpasswd -bc /etc/wireguard/dash.htpasswd "$DASH_USER" "$DASH_PASS" >/dev/null 2>&1

mkdir -p /opt/wg-dash
cat > /opt/wg-dash/server.py <<'PYEOF'
import subprocess, base64, http.server, socketserver, html

PORT = 8080
AUTH_FILE = "/etc/wireguard/dash.htpasswd"

def check_auth(header):
    if not header or not header.startswith("Basic "):
        return False
    try:
        user_pass = base64.b64decode(header.split(" ",1)[1]).decode()
    except Exception:
        return False
    user, _, pw = user_pass.partition(":")
    with open(AUTH_FILE) as f:
        line = f.read().strip()
    stored_user, _, _ = line.partition(":")
    # simple compare against the htpasswd-set password via apache2-utils' own bcrypt check
    import crypt
    stored_hash = line.split(":",1)[1]
    return user == stored_user and crypt.crypt(pw, stored_hash) == stored_hash

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if not check_auth(self.headers.get("Authorization")):
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="VPN Status"')
            self.end_headers()
            return
        out = subprocess.run(["wg", "show", "wg0"], capture_output=True, text=True).stdout
        body = f"<html><body><h2>WireGuard Status</h2><pre>{html.escape(out)}</pre></body></html>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(body.encode())
    def log_message(self, *a): pass

with socketserver.TCPServer(("", PORT), Handler) as httpd:
    httpd.serve_forever()
PYEOF

cat > /etc/systemd/system/wg-dash.service <<EOF
[Unit]
Description=WireGuard status dashboard
After=network.target
[Service]
ExecStart=/usr/bin/python3 /opt/wg-dash/server.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now wg-dash
iptables -C INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 8080 -j ACCEPT
netfilter-persistent save
echo "[3/5] Dashboard: http://$PUBIP:8080  user=$DASH_USER  pass=$DASH_PASS  (also saved in /etc/wireguard/dash-credentials.txt)"
echo "user=$DASH_USER pass=$DASH_PASS" > /etc/wireguard/dash-credentials.txt
chmod 600 /etc/wireguard/dash-credentials.txt

# =========================================================
# 4. Usage / downtime alerts via ntfy.sh (free, no signup)
# =========================================================
TOPIC="vpn-alerts-$(tr -dc 'a-z0-9' </dev/urandom | head -c 10)"
cat > /usr/local/bin/wg-watchdog <<EOF
#!/usr/bin/env bash
TOPIC="$TOPIC"
if ! systemctl is-active --quiet wg-quick@wg0; then
  curl -s -d "WireGuard is DOWN on \$(hostname)" "https://ntfy.sh/\$TOPIC" >/dev/null
fi
EOF
chmod +x /usr/local/bin/wg-watchdog
echo "*/10 * * * * root /usr/local/bin/wg-watchdog" > /etc/cron.d/wg-watchdog
echo "[4/5] Alerts: install the ntfy app or visit https://ntfy.sh/$TOPIC and subscribe to topic '$TOPIC' to get a push if the VPN goes down."

# =========================================================
# 5. Port-443 mode (helps on networks that block non-standard VPN ports)
# =========================================================
read -p "Switch WireGuard to listen on port 443 as well (helps evade port-based blocking)? [y/N] " yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
  iptables -t nat -C PREROUTING -p udp --dport 443 -j REDIRECT --to-port "$PORT" 2>/dev/null || \
    iptables -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-port "$PORT"
  netfilter-persistent save
  iptables -I INPUT -p udp --dport 443 -j ACCEPT
  netfilter-persistent save
  echo "[5/5] Port 443 also forwards to WireGuard. In client configs, set Endpoint = $PUBIP:443 where needed."
else
  echo "[5/5] Skipped port-443 redirect."
fi

echo
echo "All extras installed. Summary saved to /etc/wireguard/extras-summary.txt"
{
  echo "Dashboard: http://$PUBIP:8080 (user=$DASH_USER pass=$DASH_PASS)"
  echo "Alerts topic: $TOPIC (subscribe at https://ntfy.sh/$TOPIC)"
  echo "Split tunneling: sudo wgctl split <name> <cidr1,cidr2,...>"
  echo "Port 443 fallback: Endpoint = $PUBIP:443"
} > /etc/wireguard/extras-summary.txt
