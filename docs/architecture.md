# Architecture

## Network topology

Every segment terminates on pfSense. There is no route between segments unless a
rule creates one, and only two such rules exist.

```mermaid
graph TB
    INET([Internet])
    GW[ISP Gateway<br/>bridge mode]
    FW{{"morpheus<br/>pfSense · FreeBSD 15<br/>HP ProDesk 600 G4"}}
    SW[neo · MokerLink 26-port<br/>802.1Q trunk]

    INET --- GW --- FW --- SW

    subgraph V99["VLAN 99 · Winterfell · Management"]
        MON["prometheus · 10.0.99.20<br/><b>observability stack</b>"]
        UPS["mjolnir · APC Smart-UPS"]
        SPARE["oracle · spare"]
    end

    subgraph V50["VLAN 50 · Hicks · Trusted"]
        WS["workstations · laptops · phones"]
    end

    subgraph V40["VLAN 40 · CasaBonita · Media"]
        TV["TV · consoles · streaming"]
    end

    subgraph V30["VLAN 30 · ImaginationLAN · Lab"]
        HV["Saruman · ProLiant DL360 Gen9<br/>Proxmox VE<br/>BMC: shiva"]
    end

    subgraph V20["VLAN 20 · Skids · IoT"]
        IOT["cameras · assistants · sensors"]
    end

    subgraph V10["VLAN 10 · Degens · Guest"]
        GUEST["guest devices"]
    end

    SW --- V99
    SW --- V50
    SW --- V40
    SW --- V30
    SW --- V20
    SW --- V10

    WS -.->|"management access<br/>(the only inbound path)"| V99
    WS -.->|lab access| V30

    %% Fill is the patch-cable colour in the rack — see network.md, ADR-0009.
    %% A dashed border marks a terminal segment: traffic goes out, nothing
    %% comes back in. Grey is not a segment; it carries every VLAN.
    %% stroke-dasharray must be last on its line and space-separated — a comma
    %% is the property delimiter and would truncate the value.
    classDef vlan99 fill:#6e2c2c,stroke:#f85149,color:#fff
    classDef vlan50 fill:#7a3f12,stroke:#db6d28,color:#fff
    classDef vlan30 fill:#1f6f4a,stroke:#2ea043,color:#fff
    classDef infra  fill:#30363d,stroke:#8b949e,color:#e6edf3
    classDef vlan40 fill:#a87f00,stroke:#e3b341,color:#0d1117,stroke-dasharray: 6 4
    classDef vlan20 fill:#1f4e79,stroke:#388bfd,color:#fff,stroke-dasharray: 6 4
    classDef vlan10 fill:#4a3f7a,stroke:#a371f7,color:#fff,stroke-dasharray: 6 4

    class MON,UPS,SPARE vlan99
    class WS vlan50
    class HV vlan30
    class TV vlan40
    class IOT vlan20
    class GUEST vlan10
    class GW,FW,SW infra

    %% classDef is unreliable on subgraphs (mermaid-js/mermaid#1726), so the
    %% clusters are styled explicitly and the dash is applied to their inner
    %% nodes as well — the cue survives either way.
    style V99 fill:#161b22,stroke:#f85149,stroke-width:2px,color:#f85149
    style V50 fill:#161b22,stroke:#db6d28,stroke-width:2px,color:#db6d28
    style V30 fill:#161b22,stroke:#2ea043,stroke-width:2px,color:#2ea043
    style V40 fill:#161b22,stroke:#e3b341,stroke-width:2px,color:#e3b341,stroke-dasharray: 6 4
    style V20 fill:#161b22,stroke:#388bfd,stroke-width:2px,color:#388bfd,stroke-dasharray: 6 4
    style V10 fill:#161b22,stroke:#a371f7,stroke-width:2px,color:#a371f7,stroke-dasharray: 6 4
```

Everything reaches the internet. Nothing reaches anything else, with two
exceptions drawn as dotted lines above: trusted workstations may administer
management, and may reach the lab. IoT, media and guest are terminal — traffic
goes out, nothing comes back in.

Segment colour is the patch-cable colour in the rack, so the diagram and the
hardware can be read against each other. A dashed border marks a terminal
segment. Grey is not a segment: the gateway, firewall and switch carry every
VLAN at once. Reasoning in
[ADR-0009](adr/0009-colour-vlans-by-cable-not-by-trust.md).

The full device inventory is in [`network.md`](network.md); the reasoning behind
the split is in [`security.md`](security.md).

## Observability data flow

```mermaid
graph LR
    subgraph Sources["Monitored estate"]
        direction TB
        PF["morpheus<br/>pfSense"]
        UPSD["mjolnir<br/>APC UPS"]
        SWD["neo<br/>switch"]
        ILO["shiva<br/>iLO"]
        HOSTS["Linux hosts<br/>+ Docker"]
    end

    subgraph Stack["prometheus · 10.0.99.20 · one compose stack"]
        direction TB
        SNMP["snmp-exporter<br/>:9116"]
        ALLOY["Alloy<br/>cAdvisor · node · logs"]
        PROM[("Prometheus<br/>:9090 · 30d")]
        LOKI[("Loki<br/>:3100 · 30d")]
        AM["Alertmanager<br/>:9093"]
        GRAF["Grafana<br/>:3000"]
    end

    OUT([Webhook<br/>notification])

    PF -->|SNMP v2c| SNMP
    UPSD -->|SNMP v2c| SNMP
    SWD -->|SNMP v2c| SNMP
    ILO -->|SNMP v2c| SNMP
    HOSTS -->|metrics + logs| ALLOY

    SNMP -->|scrape /snmp| PROM
    ALLOY -->|remote_write| PROM
    ALLOY -->|push| LOKI
    PROM -->|alerts| AM
    AM --> OUT
    PROM --> GRAF
    LOKI --> GRAF

    %% Deliberately outside the VLAN palette — this diagram is about data
    %% paths, not segments, and reusing a cable colour here would read as a
    %% claim about which segment a component is on. Grey means the same thing
    %% in both diagrams: plumbing. No dashes — that means "terminal" now.
    classDef store fill:#1b3a3f,stroke:#39c5cf,color:#e6edf3,stroke-width:2px
    classDef agent fill:#30363d,stroke:#8b949e,color:#e6edf3,stroke-width:2px
    class PROM,LOKI store
    class SNMP,ALLOY agent
```

Two collection paths, because the estate has two kinds of device:

- **Things that run an agent.** Linux hosts get a Grafana Alloy agent, which
  gathers node metrics, cAdvisor container metrics, the systemd journal, syslog
  and `auth.log`, then pushes to Loki and remote-writes to Prometheus. The same
  `config.alloy` runs everywhere; only two environment variables differ.
- **Things that cannot.** The firewall, switch, UPS and BMC are polled over SNMP
  through `snmp-exporter`, which Prometheus scrapes as a proxy.

Remote-write rather than scrape for agents means a new host appears in
Prometheus as soon as its agent starts — no target list to edit, no firewall
hole from the monitoring VLAN into the monitored one.

## Host and stack mapping

| Host | VLAN | Stack | Contents |
| --- | --- | --- | --- |
| `prometheus` (10.0.99.20) | 🔴 99 | [`stacks/observability`](../stacks/observability) | Prometheus, Alertmanager, Loki, Grafana, snmp-exporter, blackbox-exporter, Alloy |
| `Saruman` (10.0.30.110) | 🟢 30 | *(none yet)* | Proxmox VE 9.2.11, no guests — see [roadmap](roadmap.md) |
| `oracle` (10.0.99.30) | 🔴 99 | *(none yet)* | Undecided |

One directory per stack, not one per service. A stack is the unit that gets
deployed together; a second host means a second directory under `stacks/`, not a
re-shard of everything. Reasoning in
[ADR-0004](adr/0004-one-compose-stack-per-host.md).

## Ports

| Service | Port | Bound to | Notes |
| --- | --- | --- | --- |
| Grafana | 3000 | `${BIND_ADDR}` | The only UI meant to be opened by a human |
| Prometheus | 9090 | `${BIND_ADDR}` | Also the remote-write receiver for agents |
| Loki | 3100 | `${BIND_ADDR}` | Push endpoint for agents |
| Alertmanager | 9093 | `${BIND_ADDR}` | |
| Alloy | 12345 | `127.0.0.1` | Debug UI, deliberately not exposed |
| Alloy syslog | 1514/udp | `${BIND_ADDR}` | Network syslog receiver — pfSense pushes here |
| snmp-exporter | 9116 | *compose network only* | Never published to a host interface |
| blackbox-exporter | 9115 | *compose network only* | Never published — an open prober is an SSRF primitive |

`BIND_ADDR` defaults to `0.0.0.0` and is set in `.env`. Setting it to the host's
VLAN 99 address confines the whole stack to the management segment; the
published ports exist because agents on other hosts need to reach Prometheus and
Loki.

## Reference diagrams

The Mermaid diagrams above are the maintained ones — they render on GitHub, diff
as text, and cannot drift out of sync with the repo without a visible change.

- [Current topology export](diagrams/current/matrix_elysium.png) — detailed
  physical drawing, 9871×4466. Its editable `.drawio` source was lost in an
  earlier commit, which is a large part of why the diagrams above are Mermaid.
  **It predates the rack colour scheme and cannot be recoloured** — with no
  source file there is nothing to edit. Treat the Mermaid diagrams and
  [`network.md`](network.md) as authoritative for colour; this one is
  authoritative only for physical layout.
- [Previous topology](diagrams/previous/Network_Diagram.png)
