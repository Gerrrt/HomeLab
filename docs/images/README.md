# Screenshots

Dashboard screenshots go here and are referenced from the root `README.md`.

They are deliberately absent rather than faked — a mocked-up dashboard image in
a monitoring repository is worse than none, because it cannot be checked against
the JSON that produced it.

## Capturing them

Once the stack has a few days of real data:

```bash
make up
# open http://<monitoring-host>:3000, log in, HomeLab folder
```

For each dashboard, set the time range to something with visible activity
(24h works well), then use Grafana's **Share → Export → Save as image**, or take
a full-page browser screenshot.

Save as:

| File | Dashboard |
| --- | --- |
| `host-overview.png` | Host Overview |
| `docker-containers.png` | Docker Containers |
| `network-snmp.png` | Network & Firewall |
| `ups-power.png` | UPS & Power |
| `logs-explorer.png` | Logs |

Then uncomment the screenshot block in the root `README.md`.

## Before publishing

These are going into a public repository. Check each image for:

- Full MAC addresses in table panels
- The WAN IP address in any interface panel
- Hostnames or usernames in log lines
- Anything in a Grafana annotation or query bar you did not mean to publish

Crop or blur rather than re-shooting — it is easier to be thorough.
