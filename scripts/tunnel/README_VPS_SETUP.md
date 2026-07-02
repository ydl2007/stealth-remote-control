# VPS Relay Server Setup Guide

Set up a cheap Linux VPS as an SSH relay for stealth RDP tunneling. The SSH server listens
on **port 443** (HTTPS) to blend with normal web traffic — firewalls almost never block it.

---

## 1. Choose a VPS Provider

Any provider with a public IPv4 address works. Pick the cheapest tier (~€5/mo):

| Provider  | Cheapest Plan     | Notes                                    |
|-----------|-------------------|------------------------------------------|
| DigitalOcean | Basic Droplet $6/mo | Good docs, wide region choice          |
| Vultr     | Cloud Compute $6/mo | Hourly billing available               |
| Hetzner   | CX22 €3.99/mo      | Best value, but limited regions        |
| Linode    | Nanode $5/mo       | Reliable, good for beginners           |

**OS:** Ubuntu 22.04 LTS or Debian 12 — both have OpenSSH built-in.

---

## 2. Initial Server Setup

### 2.1 Connect for the first time

```bash
# Use the root password emailed to you (or set via provider dashboard)
ssh root@<VPS_IP>
```

### 2.2 Create a non-root user (recommended)

```bash
adduser tunneladmin       # pick a strong password
usermod -aG sudo tunneladmin
su - tunneladmin
```

### 2.3 Install OpenSSH server

```bash
sudo apt update && sudo apt install openssh-server -y
```

---

## 3. Configure SSH Server for Stealth Tunneling

Edit the SSH daemon config:

```bash
sudo nano /etc/ssh/sshd_config
```

Set or uncomment the following lines:

```ini
# Listen on port 443 (HTTPS) — blends with web traffic, rarely blocked
Port 443

# Allow reverse port forwarding (required for the Host → VPS tunnel)
GatewayPorts yes

# Disable password authentication — key-only access
PasswordAuthentication no

# Allow TCP forwarding (tunneling)
AllowTcpForwarding yes

# Optional: only allow specific users to tunnel
# AllowUsers tunneladmin
```

> **Why port 443?** Corporate/ school firewalls almost always let HTTPS (443) through.
> SSH-over-443 is indistinguishable from HTTPS to a passive observer.
> If 443 is already in use by a web server, use 2222 or 8443 instead.

### 3.1 Restart SSH

```bash
sudo systemctl restart sshd
```

Verify it's listening on 443:

```bash
sudo ss -tlnp | grep 443
```

Expected output: `LISTEN 0 128 0.0.0.0:443 0.0.0.0:* users:(("sshd",pid=...,fd=...))`

---

## 4. Firewall Configuration

### 4.1 Using UFW (recommended)

```bash
sudo ufw allow 443/tcp comment 'SSH stealth tunnel'
sudo ufw enable          # enable if not already active
sudo ufw status verbose  # verify
```

### 4.2 Using iptables (if UFW is not available)

```bash
sudo iptables -A INPUT -p tcp --dport 443 -j ACCEPT
sudo iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
# Save rules (Ubuntu/Debian)
sudo apt install iptables-persistent -y
sudo netfilter-persistent save
```

---

## 5. SSH Key Authentication

### 5.1 Generate a key pair on the **Host** (exam PC)

Run **`setup_ssh_key.bat`** on the Windows machine — it generates an Ed25519 key pair.

Or do it manually:

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\stealth_remote" -N ""
```

### 5.2 Add the public key to the VPS

```bash
# On the VPS:
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "<paste the contents of stealth_remote.pub here>" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Or copy from Windows:

```powershell
type "%USERPROFILE%\.ssh\stealth_remote.pub" | ssh tunneladmin@<VPS_IP> "cat >> ~/.ssh/authorized_keys"
```

### 5.3 Test the key

```powershell
ssh -i "%USERPROFILE%\.ssh\stealth_remote" tunneladmin@<VPS_IP> -p 443
```

You should connect **without a password prompt**.

---

## 6. Security Hardening

### 6.1 MFA on the SSH key (recommended for production)

Add an extra factor by requiring the SSH key **and** a passphrase:

```bash
# On the VPS — edit the key line in ~/.ssh/authorized_keys
# Prepend: restrict,command="false"  (see man sshd for details)
```

Or generate the key with a passphrase:

```powershell
ssh-keygen -t ed25519 -f "%USERPROFILE%\.ssh\stealth_remote"   # leave -N "" off to prompt for passphrase
```

Then use `ssh-agent` or `start-ssh-agent` to cache it so you don't type it every time.

### 6.2 Restrict by source IP (if the host has a static IP)

```bash
# In /etc/ssh/sshd_config:
Match Address 203.0.113.0/24
    AuthenticationMethods publickey
```

### 6.3 Additional hardening (optional)

```bash
# Limit login attempts
sudo sed -i 's/^#MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config
# Limit sessions per connection
sudo sed -i 's/^#MaxSessions.*/MaxSessions 2/' /etc/ssh/sshd_config
# Disable root login (already disabled if PasswordAuthentication no)
sudo sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

sudo systemctl restart sshd
```

### 6.4 Optional: Use fail2ban

```bash
sudo apt install fail2ban -y
sudo systemctl enable fail2ban --now
```

---

## 7. Verify the Relay Works

From the **Host** (exam PC), open a terminal and run:

```powershell
ssh -i "%USERPROFILE%\.ssh\stealth_remote" -R 3390:127.0.0.1:3390 -N -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new tunneladmin@<VPS_IP> -p 443
```

From the **Client** (helper PC), open a second terminal and run:

```powershell
ssh -i "%USERPROFILE%\.ssh\stealth_remote" -L 3390:127.0.0.1:3390 -N -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new tunneladmin@<VPS_IP> -p 443
```

Then in a third terminal on the Client:

```powershell
mstsc /v:127.0.0.1:3390
```

If RDP is running on the Host, the Remote Desktop client on the Client should connect.

---

## 8. Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `ssh: connect to host <VPS_IP> port 443: Connection refused` | SSH not listening on 443 | Check `sshd_config` for `Port 443`, restart sshd, check firewall |
| `channel_setup_fwd: forwarding failed` | Port 3390 already bound on VPS | Run `sudo ss -tlnp \| grep 3390`, kill the old SSH process |
| `Permission denied (publickey)` | Key not in authorized_keys | Double-check `~/.ssh/authorized_keys` contents and permissions (600) |
| Tunnel connects but RDP shows blank/black screen | Host RDP not listening on 3390 | Run `netstat -an \| findstr 3390` on Host — start RDP on alternate port |
| `ServerAliveInterval` drops after 10 min | NAT/firewall timeout | Reduce interval: `-o ServerAliveInterval=15` or use `-o TCPKeepAlive=yes` |

---

> **Pro tip:** Wrap the tunnel commands in the provided `.bat` scripts (see `tunnel_host.bat`
> and `tunnel_client.bat`) to get auto-reconnect, logging, and one-click operation.
