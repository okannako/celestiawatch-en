# Celestia Validator + Fibre Health Check and Telegram Alerts

* A single-file health check and alert tool for operators running a Validator and Fibre server on Celestia Mainnet Beta and Mocha (mocha-5).
* It does two things: the `doctor` command checks your whole setup end to end, and in the background it watches your node every minute and alerts you on Telegram when something goes wrong.
* Tested on a live Mocha validator running celestia-app v10.5.0-mocha with Fibre.
* If you have any questions during or after setup, you can reach me via Telegram, Mail or Discord. Contributions on GitHub are welcome.

## Security

This tool is deliberately limited:

- **Read-only.** It never changes your node config and never stops or starts services.
- **No transactions.** It never sends a tx to the chain and never runs wallet or key commands.
- **No open ports.** It only reads the server's own `127.0.0.1:26657` RPC and sends messages to Telegram.
- **Unprivileged user.** The alert service does not run as root. It runs as a separate `celestiawatch` user that cannot see `/root` or `/home`, so it has no access to your keys. CPU (20%) and RAM (100 MB) usage are capped.
- **Protected Telegram token.** The token is stored in a file readable only by root and the celestiawatch user.
- **Privacy.** Telegram messages never contain your IP or hostname, only the name you choose. In the `doctor` report your IP is masked (like `65.109.*.*:7980`), so you can share it safely.
- **Fully removable.** `sudo celestiawatch uninstall` removes everything. Your node is not touched.

## What It Checks

| Check | Alert when |
|---|---|
| Node RPC | Not responding |
| Sync | catching_up: true |
| Block progress | Block height has not moved for 3 minutes |
| Missed blocks | 5 or more blocks missed in one check |
| Active set | Validator drops out of the active set (jailed or unbonded) |
| Peers | Fewer than 3 |
| celestia-appd / Fibre / Bridge service | Not running |
| Fibre port (7980) | Fibre is running but not listening on the port |
| Sensitive ports (9090, 26669, 26657, 26658, 1317) | Exposed to the internet |
| Disk | Over 85% full |
| Clock (NTP) | Not synced |

- You get 🔴 when a problem starts and 🟢 when it is resolved. Ongoing problems are repeated every hour.
- A short status summary arrives every morning after 09:00 (configurable, or can be turned off).
- Fibre and Bridge services are detected automatically during setup, even with custom names (`fibre`, `fibre-mocha5`, `celestia-bridge`, etc.). Only enabled or running services are watched, so leftover unused service files from old setups don't trigger alerts.

On top of these, the `doctor` command also checks:
- Are you on the latest release for your network (mainnet or mocha)?
- Does your on-chain Fibre address (set-host) point to this server?
- Is bbr enabled?

## Example Output

### Telegram Status Message
```
[Validator-Mocha] 📊 Status
Network: mocha-5 | Block: 2157414 | Synced: yes
Peers: 13 | Voting power: 21105026 (in active set) | app v10
celestia-appd: running
fibre-mocha5: running (listening on 7980)
Disk /: 50%
Sensitive ports: closed (127.0.0.1 only)
```

### Telegram Alerts
```
[Validator-Mocha] 🔴 Missed 6 of the last 30 blocks checked.
[Validator-Mocha] 🟢 Resolved: Missed 6 of the last 30 blocks checked.
```

### doctor Report
```
Node
  ✔ RPC responding (http://127.0.0.1:26657)
  - Network: mocha-5 | Block: 2157449 | Peers: 13
  ✔ Synced
  ✔ app_version 10 (Fibre supported)
  ✔ In active set, voting power 21105026

Services
  ✔ celestia-appd running
  ✔ fibre-mocha5 running

Versions
  - celestia-appd: 10.5.0-mocha
  - fibre: version: 10.5.0-mocha
  ✔ Running the latest release (v10.5.0-mocha)

Fibre
  ✔ Listening on port 7980
  ✔ Fibre address registered on-chain: 65.109.*.*:7980
  ✔ Registered address points to this server

Security
  ✔ 9090 / 26669 / 26657 / 26658 / 1317 not exposed
  ✔ Clock synced (NTP)
  ✔ bbr enabled

Disk
  ✔ / 50% full
```

## Installation

### 1. Create a Telegram Bot
- Message **@BotFather** on Telegram, create a bot with `/newbot` and save the **token** it gives you.
- Send `/start` to your new bot once. Without this, the bot cannot message you.
- Message **@userinfobot**. The **Id** it shows you is your Chat ID.

### 2. Install the Tool
- Run this on your validator server. It will ask for the token, Chat ID and the name shown in messages.
- Don't use your IP or city as the name. If you have multiple servers, use distinct names like `Validator-Mainnet` and `Validator-Mocha`.
```
curl -s https://raw.githubusercontent.com/okannako/celestiawatcheng/refs/heads/main/celestiawatcheng.sh > celestiawatcheng.sh && chmod +x celestiawatcheng.sh && sudo ./celestiawatcheng.sh install
```

- A test message arrives on Telegram when setup is done.
- After setup, all commands use `celestiawatch` (for example `sudo celestiawatch doctor`).

### Updating
- Run the same install command again. Your settings are kept, and only the tool is updated without asking questions.

## Usage

### Detailed Health Report
```
sudo celestiawatch doctor
```

### Current Status
```
celestiawatch status
```

### Send a Test Message to Telegram
```
sudo celestiawatch test
```

### Changing Settings
- Thresholds, the name in messages (`NODE_LABEL`) and the daily report hour (`DAILY_REPORT_HOUR`, leave empty to turn off) are in this file. Changes apply on the next check, nothing else to do.
```
sudo nano /etc/celestiawatch/config.env
```

### Testing Alerts
- To test alerts without touching your node, temporarily lower the disk threshold. A 🔴 message arrives within 1 minute.
```
sudo sed -i 's/^DISK_ALERT_PERCENT=.*/DISK_ALERT_PERCENT=10/' /etc/celestiawatch/config.env
```

- Set it back. A 🟢 Resolved message arrives within 1 minute.
```
sudo sed -i 's/^DISK_ALERT_PERCENT=.*/DISK_ALERT_PERCENT=85/' /etc/celestiawatch/config.env
```

### Viewing Logs
```
journalctl -u celestiawatch -f
```

### Uninstalling
```
sudo celestiawatch uninstall
```

## Troubleshooting

- **No Telegram messages:** Check the logs with `journalctl -u celestiawatch -n 20 --no-pager`. The reason is shown there:
  - Wrong token
  - Wrong Chat ID, or `/start` not sent to the bot
  - Internet/DNS problem
  
  Fix it in `sudo nano /etc/celestiawatch/config.env` and try again with `sudo celestiawatch test`.
- **No Fibre section in the report:** If `doctor` finds your Fibre service, it prints the command to fix the config. If not, set `FIBRE_SERVICE="your-service-name"` in config.env yourself.
- **"No Fibre address found on-chain":** You may not have run `celestia-appd tx valaddr set-host` yet.

## Notes

- The server cannot test whether its own Fibre port is reachable from the internet. Test it from your own computer:
  - Linux/Mac: `nc -vz SERVER_IP 7980`
  - Windows PowerShell: `Test-NetConnection SERVER_IP -Port 7980` (should show `TcpTestSucceeded : True`)
- Requirements: Ubuntu 22.04 or 24.04, `curl`, `jq`, `iproute2`. Setup installs any missing ones.
