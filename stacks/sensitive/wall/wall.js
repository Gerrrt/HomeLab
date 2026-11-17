// The Elysian Wall (ADR-0119). Every number here is the answer to a fixed
// question at /api/q/NAME, written out in the sensitive tier's Caddyfile. The
// page chooses WHICH question, never the PromQL, and holds no token.
//
// Every value is written with textContent, never innerHTML: label values come
// from Prometheus, and anything that can push a series could otherwise put
// markup on the wall.
"use strict";

(() => {
  const POLL_MS = 30_000;
  // A source with no good answer for this long is shown as stale, and three
  // times this as dead, so a frozen number is never mistaken for a live one.
  const STALE_MS = 150_000;
  // Reload the page now and then, so a change merged to main reaches the wall
  // without anyone touching the Pi.
  const RELOAD_MS = 6 * 60 * 60 * 1000;

  // The eight tiles, in the order they sit. `cpu` hosts are node_exporter
  // hosts, keyed by `instance`; `snmp` devices by the `device` label in
  // prometheus/targets/snmp.yaml.
  const HOSTS = [
    { name: "morpheus", src: "snmp", role: "firewall" },
    { name: "Saruman", src: "cpu", role: "hypervisor" },
    { name: "trinity", src: "cpu", role: "sensitive tier" },
    { name: "prometheus", src: "cpu", role: "monitoring" },
    { name: "oracle", src: "cpu", role: "wiki, off-host jobs" },
    { name: "smaug", src: "cpu", role: "NAS" },
    { name: "neo", src: "snmp", role: "core switch" },
    { name: "mjolnir", src: "snmp", role: "UPS" },
  ];

  const QUESTIONS = ["alerts", "cpu", "snmp", "wan", "wan_hour", "rtt", "ups", "pi_temp"];
  const answers = {};   // name -> data.result of the last good answer
  const lastOk = {};    // name -> Date.now() of the last good answer

  const $ = (id) => document.getElementById(id);
  const el = (tag, cls, text) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  };
  const num = (r) => Number(r && r.value && r.value[1]);

  // ---------- layout: scale the 1920x1080 stage to the window ----------
  const stage = $("stage");
  function fit() {
    const vp = $("viewport");
    const s = Math.min(vp.clientWidth / 1920, vp.clientHeight / 1080);
    stage.style.transform = `translate(${-960 * s}px, ${-540 * s}px) scale(${s})`;
  }
  addEventListener("resize", fit);
  fit();

  // ---------- clock: minutes only, so nothing ticks every second ----------
  const days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  const months = ["January", "February", "March", "April", "May", "June", "July",
    "August", "September", "October", "November", "December"];
  function tick() {
    const d = new Date();
    const h = d.getHours();
    $("hm").textContent = `${h % 12 || 12}:${String(d.getMinutes()).padStart(2, "0")}`;
    $("ampm").textContent = h < 12 ? "AM" : "PM";
    $("date").textContent = `${days[d.getDay()]}, ${months[d.getMonth()]} ${d.getDate()}`;
  }
  tick();
  setInterval(tick, 10_000);

  // ---------- fetching ----------
  async function ask(name) {
    try {
      const res = await fetch(`/api/q/${name}`, { cache: "no-store" });
      if (!res.ok) return;
      const body = await res.json();
      if (body.status !== "success") return;
      answers[name] = body.data.result;
      lastOk[name] = Date.now();
    } catch (_) {
      // Network or parse failure: keep the last answer, and let the status
      // bar say how old it is.
    }
  }

  const fresh = (name) => lastOk[name] !== undefined && Date.now() - lastOk[name] < STALE_MS;

  // ---------- alerts and the verdict ----------
  const SEVERITY_RANK = { critical: 0, warning: 1, info: 2 };
  function renderAlerts() {
    const body = $("alerts-body");
    const verdict = $("verdict");
    const text = $("verdict-text");
    body.replaceChildren();

    if (!fresh("alerts")) {
      verdict.dataset.state = "broken";
      text.textContent = "No answer from Prometheus";
      const b = el("div", "broken", "Cannot read alerts");
      b.append(el("small", null, "The wall has no recent answer from Prometheus, so nothing here can be trusted."));
      body.append(b);
      return;
    }

    const all = answers.alerts || [];
    const watchdog = all.some((a) => a.metric.alertname === "Watchdog");
    // Without Watchdog firing, rule evaluation has stopped, and "no alerts"
    // would mean nothing. Say so instead of looking calm.
    if (!watchdog) {
      verdict.dataset.state = "broken";
      text.textContent = "Alerting has stopped";
      const b = el("div", "broken", "Watchdog is not firing");
      b.append(el("small", null, "Prometheus answered, but its rules are not being evaluated."));
      body.append(b);
      return;
    }

    const faults = all
      .filter((a) => a.metric.alertname !== "Watchdog")
      .sort((a, b) => (SEVERITY_RANK[a.metric.severity] ?? 3) - (SEVERITY_RANK[b.metric.severity] ?? 3));

    if (faults.length === 0) {
      verdict.dataset.state = "ok";
      text.textContent = "All quiet";
      const q = el("div", "quiet", "All quiet");
      q.append(el("small", null, "Nothing is firing."));
      body.append(q);
      return;
    }

    const worst = faults[0].metric.severity === "critical" ? "critical" : "warning";
    verdict.dataset.state = worst;
    text.textContent = `${faults.length} alert${faults.length === 1 ? "" : "s"} firing`;

    const SHOWN = 7;
    for (const a of faults.slice(0, SHOWN)) {
      const m = a.metric;
      const row = el("div", `al ${m.severity || ""}`);
      row.append(el("i", "sev"));
      const msg = el("div", "m", m.alertname);
      const where = m.instance || m.host || m.device || m.name || m.job || "";
      msg.append(el("small", null, [m.severity, where].filter(Boolean).join(" · ")));
      row.append(msg);
      body.append(row);
    }
    if (faults.length > SHOWN) body.append(el("div", "more", `+${faults.length - SHOWN} more`));
  }

  // ---------- nodes ----------
  function renderNodes() {
    const grid = $("nodes");
    grid.replaceChildren();
    const cpu = new Map((answers.cpu || []).map((r) => [r.metric.instance, num(r)]));
    const snmp = new Map((answers.snmp || []).map((r) => [r.metric.device, num(r)]));
    const charge = (answers.ups || []).find((r) => r.metric.__name__ === "upsEstimatedChargeRemaining");

    for (const h of HOSTS) {
      const tile = el("div", "node");
      const dot = el("i", "dot");
      const name = el("div", "name", h.name);
      const role = el("div", "role", h.role);
      const val = el("div", "val");
      let state = "ok";

      if (h.src === "cpu") {
        if (!fresh("cpu")) state = "unknown";
        else if (!cpu.has(h.name)) state = "down";
        if (state === "ok") {
          const pct = cpu.get(h.name);
          val.textContent = `${Math.round(pct)}%`;
          val.append(el("small", null, "cpu"));
          if (pct >= 90) state = "warning";
        } else {
          val.textContent = state === "down" ? "no data" : "—";
        }
      } else {
        if (!fresh("snmp")) state = "unknown";
        else if (snmp.get(h.name) !== 1) state = "down";
        if (state === "ok" && h.name === "mjolnir" && charge) {
          val.textContent = `${Math.round(num(charge))}%`;
          val.append(el("small", null, "charge"));
        } else {
          val.textContent = state === "ok" ? "up" : state === "down" ? "down" : "—";
        }
      }

      if (state !== "ok") tile.classList.add(state);
      tile.append(dot, name, role, val);
      grid.append(tile);
    }
  }

  // ---------- internet ----------
  const mbps = (bits) => (bits >= 100e6 ? Math.round(bits / 1e6) : (bits / 1e6).toFixed(1));
  function renderWan() {
    const wan = answers.wan || [];
    const dir = (d) => wan.find((r) => r.metric.direction === d);
    const down = dir("receive");
    const up = dir("transmit");
    $("wan-down").textContent = fresh("wan") && down ? mbps(num(down)) : "—";
    $("wan-up").textContent = fresh("wan") && up ? mbps(num(up)) : "—";
    const rtt = (answers.rtt || [])[0];
    $("wan-rtt").textContent = fresh("rtt") && rtt ? Math.round(num(rtt) * 1000) : "—";

    const svg = $("wan-spark");
    svg.replaceChildren();
    const series = (answers.wan_hour || [])[0];
    if (!fresh("wan_hour") || !series || series.values.length < 2) return;
    const ys = series.values.map((v) => Number(v[1]));
    const max = Math.max(...ys, 1);
    const step = 600 / (ys.length - 1);
    const pts = ys.map((y, i) => `${(i * step).toFixed(1)} ${(76 - (y / max) * 70).toFixed(1)}`);
    const ns = "http://www.w3.org/2000/svg";
    const fill = document.createElementNS(ns, "path");
    fill.setAttribute("class", "fill");
    fill.setAttribute("d", `M${pts.join(" L")} L600 80 L0 80 Z`);
    const line = document.createElementNS(ns, "path");
    line.setAttribute("class", "line");
    line.setAttribute("d", `M${pts.join(" L")}`);
    svg.append(fill, line);
  }

  // ---------- power ----------
  function renderPower() {
    const ups = new Map((answers.ups || []).map((r) => [r.metric.__name__, num(r)]));
    const card = document.querySelector(".power");
    if (!fresh("ups") || ups.size === 0) {
      card.dataset.state = "unknown";
      $("ups-state").textContent = "—";
      for (const id of ["ups-charge", "ups-runtime", "ups-load"]) $(id).textContent = "—";
      return;
    }
    const onBattery = (ups.get("upsSecondsOnBattery") || 0) > 0;
    card.dataset.state = onBattery ? "battery" : "mains";
    $("ups-state").textContent = onBattery ? "On battery" : "On mains";
    const v = (k, unit) => (ups.has(k) ? `${Math.round(ups.get(k))}${unit}` : "—");
    $("ups-charge").textContent = v("upsEstimatedChargeRemaining", "%");
    $("ups-runtime").textContent = v("upsEstimatedMinutesRemaining", " min");
    $("ups-load").textContent = v("upsOutputPercentLoad", "%");
  }

  // ---------- status bar: how old each answer is ----------
  function age(ms) {
    const s = Math.round(ms / 1000);
    return s < 90 ? `${s}s` : `${Math.round(s / 60)}m`;
  }
  function renderStatus() {
    const bar = $("status");
    bar.replaceChildren();
    const groups = [
      ["alerts", ["alerts"]],
      ["hosts", ["cpu", "snmp"]],
      ["internet", ["wan", "wan_hour", "rtt"]],
      ["power", ["ups"]],
    ];
    for (const [label, names] of groups) {
      const oldest = Math.min(...names.map((n) => lastOk[n] ?? 0));
      const span = el("span", "src");
      if (!oldest) {
        span.classList.add("dead");
        span.textContent = `${label} · never`;
      } else {
        const ms = Date.now() - oldest;
        if (ms >= 3 * STALE_MS) span.classList.add("dead");
        else if (ms >= STALE_MS) span.classList.add("stale");
        span.textContent = `${label} · ${age(ms)}`;
      }
      bar.append(span);
    }
    const t = (answers.pi_temp || [])[0];
    bar.append(el("span", "push", `heimdall · ${fresh("pi_temp") && t ? `${num(t).toFixed(0)}°C` : "—"}`));
  }

  function render() {
    renderAlerts();
    renderNodes();
    renderWan();
    renderPower();
    renderStatus();
  }

  async function poll() {
    await Promise.all(QUESTIONS.map(ask));
    render();
  }

  render();
  poll();
  setInterval(poll, POLL_MS);
  setInterval(renderStatus, 5_000);
  setTimeout(() => location.reload(), RELOAD_MS);
})();
