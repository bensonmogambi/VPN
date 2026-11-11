# Personal VPN on Oracle Cloud (Free Forever)

This sets up a WireGuard VPN you fully control, running on an Oracle Cloud
Always Free VM. Total cost: $0/month.

Files you need (all in this folder):
- `setup-vpn-plus.sh` — core VPN: WireGuard, ad-blocking DNS, multi-device
  manager, kill switch, hardening
- `setup-vpn-extras.sh` — IPv6, split tunneling, web dashboard, downtime
  alerts, port-443 fallback

---

## 1. Create your Oracle Cloud account

1. Go to **oracle.com/cloud/free** and sign up.
2. You'll need a card for identity verification — it's a temporary hold,
   not a charge, as long as you stay on the free tier.
3. Pick your **Home Region** carefully — this is permanent and can't be
   changed later. Choose whichever Always-Free-enabled region is closest
   to you (for East Africa, Johannesburg is usually the best option).

## 2. Create the VM (compute instance)

1. In the Oracle Cloud Console: **Menu → Compute → Instances → Create
   Instance**.
2. **Image:** Ubuntu 22.04 or 24.04 (minimal).
3. **Shape:** click "Change shape" and pick one marked **Always Free
   eligible** — `VM.Standard.E2.1.Micro` works fine for a VPN. If that
   shape shows "out of capacity," try the Ampere `VM.Standard.A1.Flex`
   free shape instead, or retry the E2 shape again later (capacity frees
   up over time).
4. **Networking:** keep the default VCN, and make sure "Assign a public
   IPv4 address" is checked.
5. **SSH keys:** let Oracle generate a key pair and **download the
   private key** — you'll need it to connect. Save it somewhere safe,
   e.g. `~/oracle-vpn-key.pem`.
6. Click **Create**, and wait a minute or two for the instance to go
   "Running." Note its **public IP address** on the instance details page.

## 3. Open the VPN port in Oracle's cloud firewall

Oracle blocks all inbound traffic by default, separately from the VM's
own firewall — this step is required or nothing will connect.

1. On the instance's detail page, click the subnet link under
   "Primary VNIC."
2. Go to **Security Lists → Default Security List → Add Ingress Rules**.
3. Add a rule:
   - **Source CIDR:** `0.0.0.0/0`
   - **IP Protocol:** UDP
   - **Destination Port Range:** `51820`
4. If you plan to use the port-443 fallback or the web dashboard later,
   also add:
   - UDP `443` (fallback VPN port)
   - TCP `8080` (status dashboard)

## 4. Connect to the VM

From your computer's terminal (Mac/Linux, or Windows with WSL/PowerShell
+ OpenSSH):

```bash
chmod 400 ~/oracle-vpn-key.pem
ssh -i ~/oracle-vpn-key.pem ubuntu@<YOUR_PUBLIC_IP>
```

## 5. Upload and run the core setup script

From your computer (a new terminal tab, not the SSH session):

```bash
scp -i ~/oracle-vpn-key.pem setup-vpn-plus.sh ubuntu@<YOUR_PUBLIC_IP>:~
```

Back in the SSH session on the VM:

```bash
sudo bash setup-vpn-plus.sh
```

This installs WireGuard, sets up ad-blocking DNS, creates your first
device (`phone`), and prints a QR code on screen.

**Connect your phone:** install the WireGuard app (iOS/Android), tap
"+", scan the QR code, and toggle the tunnel on.

**Add more devices** any time:
```bash
sudo wgctl add laptop      # prints a new QR code
sudo wgctl list            # see all devices + data usage
sudo wgctl remove laptop   # revoke a device
```

## 6. Upload and run the extras script

```bash
scp -i ~/oracle-vpn-key.pem setup-vpn-extras.sh ubuntu@<YOUR_PUBLIC_IP>:~
```

On the VM:
```bash
sudo bash setup-vpn-extras.sh
```

It will ask one yes/no question (port-443 fallback) and then print:
- Your **dashboard URL and password** — visit it in a browser
  (`http://<YOUR_PUBLIC_IP>:8080`)
- Your **ntfy.sh alert topic** — subscribe to it in the ntfy app for a
  push notification if the VPN ever goes down

Everything it prints is also saved on the VM at
`/etc/wireguard/extras-summary.txt`.

## 7. Verify it's working

- Visit **ipify.org** or **whatismyip.com** with the VPN on — it should
  show your Oracle VM's IP, not your real one.
- Visit **dnsleaktest.com** — results should point to the VPN's DNS.
- Open any ad-heavy site — ads should be blocked.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| "Out of capacity" creating the VM | Try the other free shape, or retry in a few hours |
| Card rejected at signup | Try a different card, or a virtual card from your bank |
| WireGuard app won't handshake | Double-check the ingress rule in Step 3 — this is the #1 cause |
| Can't SSH in | Check `chmod 400` was applied to the key, and you're using `ubuntu@` not `root@` |
| Dashboard won't load | Make sure you added the TCP 8080 ingress rule in Step 3 |

If you get stuck on any step, paste the exact error back and I'll help
you debug it.
