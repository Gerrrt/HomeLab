// The Elysian Wall (ADR-0119). Every number here is the answer to a fixed
// question: /api/q/NAME for Prometheus, /api/ha/NAME for one Home Assistant
// entity's state, each written out in the sensitive tier's Caddyfile. The
// page chooses WHICH question, never the query or the entity, and holds no
// token.
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
    // The UPS's tile carries what the Power card used to: mains or battery,
    // charge and runtime (renderNodes).
    { name: "mjolnir", src: "snmp", role: "UPS" },
  ];

  const QUESTIONS = ["alerts", "cpu", "snmp", "wan", "wan_hour", "rtt", "ups", "pi_temp"];
  // Home Assistant entities, by the names the Caddyfile gives them.
  const DOORS = [
    ["front_door", "Front"], ["garage_door", "Garage"],
    ["garden_door", "Garden"], ["patio_door", "Patio"],
  ];
  const WINDOWS = [["window_left", "Left"], ["window_right", "Right"]];
  // "forecast" is sensor.wall_weather: today's high and low, the next rain and
  // the next sunrise or sunset (home-assistant/packages/wall_weather.yaml).
  const HOUSE = ["weather", "forecast", "alarm", "office_light", ...DOORS.map((d) => d[0]), ...WINDOWS.map((w) => w[0])];
  // "today" is sensor.wall_today: the calendars' events for the next seven
  // days, gathered by home-assistant/packages/wall_calendar.yaml.
  const HA = [...HOUSE, "today"];
  const states = {};    // HA name -> the entity's state object
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

  // Keep the rows of a list that fit in its box, and say how many did not, so
  // no panel ever ends on half a row. `rowClass` marks what counts as a row;
  // `already` is how many were left out before rendering. A day heading
  // ("Tomorrow") with nothing under it goes too.
  function fitList(box, rowClass, already = 0) {
    let hidden = already;
    // Two pixels of slack: a glyph's descender can overhang its line box by a
    // pixel or so, and counting that as overflow drops a row that fits.
    const over = () => box.scrollHeight > box.clientHeight + 2;
    const isRow = (e) => e.classList.contains(rowClass);
    // A row is dropped even when it is the only thing left: one alert whose
    // name wraps past the box is counted as "+1 more", not clipped. What is
    // never dropped is a lone line that is not a row ("Nothing else today",
    // or the "+N more" itself), since an empty panel says less than it does.
    const canDrop = () => box.lastElementChild && (box.children.length > 1 || isRow(box.lastElementChild));
    const dropLast = () => {
      if (isRow(box.lastElementChild)) hidden += 1;
      box.lastElementChild.remove();
    };
    const dropHeading = () => {
      while (box.lastElementChild && box.lastElementChild.classList.contains("day")) box.lastElementChild.remove();
    };
    while (over() && canDrop()) dropLast();
    dropHeading();
    if (!hidden) return;
    const more = el("div", "more", "");
    for (;;) {
      more.textContent = `+${hidden} more`;
      box.append(more);
      if (!over() || box.children.length === 1) return;
      more.remove();
      dropLast();
      dropHeading();
    }
  }


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

  // One entity's state from Home Assistant. Kept under its own key in lastOk
  // ("ha:NAME") so the status bar can age the house apart from the lab.
  async function askHa(name) {
    try {
      const res = await fetch(`/api/ha/${name}`, { cache: "no-store" });
      if (!res.ok) return;
      const body = await res.json();
      if (typeof body.state !== "string") return;
      states[name] = body;
      lastOk[`ha:${name}`] = Date.now();
    } catch (_) {
      // Keep the last state; the status bar shows its age.
    }
  }

  const fresh = (name) => lastOk[name] !== undefined && Date.now() - lastOk[name] < STALE_MS;
  const haFresh = (name) => fresh(`ha:${name}`) && states[name]
    && states[name].state !== "unavailable" && states[name].state !== "unknown";

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

    // At most four, worst first, so a bad day cannot push the calendar off
    // the wall. The rest are counted, and so is any row the box cannot fit.
    const SHOWN = 4;
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
    fitList(body, "al", Math.max(0, faults.length - SHOWN));
  }

  // ---------- nodes ----------
  function renderNodes() {
    const grid = $("nodes");
    grid.replaceChildren();
    const cpu = new Map((answers.cpu || []).map((r) => [r.metric.instance, num(r)]));
    const snmp = new Map((answers.snmp || []).map((r) => [r.metric.device, num(r)]));
    const ups = new Map(fresh("ups") ? (answers.ups || []).map((r) => [r.metric.__name__, num(r)]) : []);

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
        if (state === "ok" && h.name === "mjolnir" && ups.size) {
          // On battery outranks everything else the tile could say, and does
          // not wait on the charge: a missing charge is only a "—".
          const onBattery = (ups.get("upsSecondsOnBattery") || 0) > 0;
          const runtime = ups.has("upsEstimatedMinutesRemaining")
            ? `${Math.round(ups.get("upsEstimatedMinutesRemaining"))} min` : "";
          if (onBattery) state = "battery";
          // Short enough to stay on one line in the tile.
          role.textContent = [onBattery ? "BATTERY" : "mains", runtime].filter(Boolean).join(" · ");
          if (ups.has("upsEstimatedChargeRemaining")) {
            val.textContent = `${Math.round(ups.get("upsEstimatedChargeRemaining"))}%`;
            val.append(el("small", null, "charge"));
          } else {
            val.textContent = "—";
          }
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
      ["house", HOUSE.map((n) => `ha:${n}`)],
      ["calendar", ["ha:today"]],
    ];
    for (const [label, names] of groups) {
      const oldest = Math.min(...names.map((n) => lastOk[n] ?? 0));
      const span = el("span", "src");
      // HA answers for a calendar it cannot read, with the state
      // "unavailable" (an expired Google sign-in, most often). That answer is
      // fresh and still says nothing, so it shows as dead.
      if (label === "calendar" && oldest && states.today && states.today.state === "unavailable") {
        span.classList.add("dead");
        span.textContent = "calendar · unavailable";
      } else if (!oldest) {
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

  // ---------- weather (header) ----------
  const CONDITIONS = {
    "clear-night": "Clear", cloudy: "Cloudy", exceptional: "Severe weather", fog: "Fog",
    hail: "Hail", lightning: "Lightning", "lightning-rainy": "Thunderstorms",
    partlycloudy: "Partly cloudy", pouring: "Heavy rain", rainy: "Rain",
    snowy: "Snow", "snowy-rainy": "Sleet", sunny: "Sunny", windy: "Windy",
    "windy-variant": "Windy",
  };
  function renderWeather() {
    const w = states.weather;
    if (!haFresh("weather")) {
      $("wx-temp").textContent = "—";
      $("wx-cond").textContent = "—";
      $("wx-sub").textContent = "";
      $("wx-sub2").textContent = "";
      return;
    }
    const a = w.attributes || {};
    const unit = a.temperature_unit || "°";
    $("wx-temp").textContent = a.temperature !== undefined ? `${Math.round(a.temperature)}${unit.startsWith("°") ? "°" : unit}` : "—";
    $("wx-cond").textContent = CONDITIONS[w.state] || w.state;

    // Line one: the day ahead, from sensor.wall_weather when it answers, the
    // present's humidity when it does not. Line two: the next sun event and
    // the wind.
    const f = haFresh("forecast") ? states.forecast.attributes || {} : null;
    const line1 = [];
    const line2 = [];
    const deg = (v) => `${Math.round(Number(v))}°`;
    if (f && f.high != null && f.low != null) line1.push(`H ${deg(f.high)} · L ${deg(f.low)}`);
    else if (a.humidity !== undefined) line1.push(`${Math.round(a.humidity)}% humidity`);
    if (f && f.rain_at) {
      const at = new Date(f.rain_at);
      line1.push(at <= new Date() ? "rain now" : `rain by ${hm(at)}`);
    }
    if (f) {
      // Whichever comes first, so the line always says what is next. The
      // sensor is up to fifteen minutes old, so a time already past is
      // dropped rather than shown as next.
      const now = new Date();
      const sun = [["sunrise", f.next_rising], ["sunset", f.next_setting]]
        .filter(([, t]) => t)
        .map(([k, t]) => [k, new Date(t)])
        .filter(([, t]) => t > now)
        .sort((x, y) => x[1] - y[1]);
      if (sun.length) line2.push(`${sun[0][0]} ${hm(sun[0][1])}`);
    }
    if (a.wind_speed !== undefined) line2.push(`wind ${Math.round(a.wind_speed)} ${a.wind_speed_unit || ""}`.trim());
    $("wx-sub").textContent = line1.join(" · ");
    $("wx-sub2").textContent = line2.join(" · ");
  }

  // ---------- home row ----------
  // Quiet when all is shut: each item says so in neutral text. An open door
  // or window turns its item amber; a triggered alarm turns it red.
  const ALARM = {
    disarmed: ["Disarmed", ""], armed_home: ["Home", ""], armed_away: ["Away", ""],
    armed_night: ["Night", ""], arming: ["Arming", "warn"], pending: ["Entry delay", "alert"],
    triggered: ["TRIGGERED", "alert"],
  };
  function homeItem(label, value, cls) {
    const span = el("span", `item ${cls || ""}`, label);
    span.append(el("b", null, value));
    return span;
  }
  function openOf(list) {
    let unknown = false;
    const open = [];
    for (const [name, label] of list) {
      if (!haFresh(name)) { unknown = true; continue; }
      if (states[name].state === "on") open.push(label);
    }
    return { open, unknown };
  }
  function renderHome() {
    const row = $("home");
    row.replaceChildren();

    if (haFresh("alarm")) {
      const [text, cls] = ALARM[states.alarm.state] || [states.alarm.state, "warn"];
      row.append(homeItem("Alarm", text, cls));
    } else {
      row.append(homeItem("Alarm", "—", "unknown"));
    }

    const doors = openOf(DOORS);
    if (doors.open.length) row.append(homeItem("Open", doors.open.join(", "), "warn"));
    else row.append(homeItem("Doors", doors.unknown ? "—" : "all closed", doors.unknown ? "unknown" : ""));

    const wins = openOf(WINDOWS);
    if (wins.open.length) row.append(homeItem("Window open", wins.open.join(", "), "warn"));
    else row.append(homeItem("Windows", wins.unknown ? "—" : "closed", wins.unknown ? "unknown" : ""));

    if (haFresh("office_light")) {
      row.append(homeItem("Office lights", states.office_light.state === "on" ? "on" : "off"));
    } else {
      row.append(homeItem("Office lights", "—", "unknown"));
    }
  }

  // ---------- today: the calendar ----------
  // Events come as HA wrote them: an all-day event's start is a date
  // ("2026-11-18"), which Date would read as UTC midnight, so it is split by
  // hand into local midnight. Anything else is an ISO time with its offset.
  const localDay = (s) => { const [y, m, d] = s.split("-").map(Number); return new Date(y, m - 1, d); };
  const evStart = (e) => (e.all_day ? localDay(e.start) : new Date(e.start));
  const evEnd = (e) => (e.all_day ? localDay(e.end) : new Date(e.end));
  const hm = (d) => {
    const h = d.getHours();
    return `${h % 12 || 12}:${String(d.getMinutes()).padStart(2, "0")} ${h < 12 ? "AM" : "PM"}`;
  };
  const shortDays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const midnight = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate());
  // Whole days from today's midnight to the event's start: 0 today (or
  // earlier, for something still going), 1 tomorrow, and so on.
  const dayOf = (e, now) => Math.max(0, Math.round((midnight(evStart(e)) - midnight(now)) / 86_400_000));

  function eventRow(e, now, later) {
    const start = evStart(e);
    const going = start <= now;
    const cls = `ev c${Number(e.cal) % 6}${going && !e.all_day ? " now" : ""}${later ? " later" : ""}`;
    const row = el("div", cls);
    const t = e.all_day ? "All day" : going ? "Now" : hm(start);
    row.append(el("span", "bar"), el("span", "t", t), el("span", "what", String(e.title || "Busy")));
    if (e.location) row.append(el("span", "where", String(e.location)));
    return row;
  }

  // The sensor is up to five minutes old, so drop what has ended since.
  function upcoming(now) {
    if (!haFresh("today")) return null;
    return ((states.today.attributes || {}).events || [])
      .filter((e) => evEnd(e) > now)
      .sort((a, b) => evStart(a) - evStart(b));
  }

  // Today and tomorrow in full; then the rest of the week, one dim line per
  // event under its day, for as long as the box has room. fitList takes the
  // overflow from the far end, so the week shortens before today does.
  function renderToday() {
    const box = $("today");
    box.replaceChildren();
    const now = new Date();
    const evs = upcoming(now);
    if (!evs) {
      box.append(el("div", "none", "—"));
      return;
    }
    const byDay = new Map();
    for (const e of evs) {
      const d = dayOf(e, now);
      if (!byDay.has(d)) byDay.set(d, []);
      byDay.get(d).push(e);
    }

    const todays = byDay.get(0) || [];
    if (todays.length) for (const e of todays) box.append(eventRow(e, now, false));
    else box.append(el("div", "none", "Nothing else today"));
    for (const d of [...byDay.keys()].filter((k) => k > 0).sort((a, b) => a - b)) {
      const date = new Date(now.getFullYear(), now.getMonth(), now.getDate() + d);
      box.append(el("div", "day", d === 1 ? "Tomorrow" : `${shortDays[date.getDay()]} ${date.getDate()}`));
      for (const e of byDay.get(d)) box.append(eventRow(e, now, d > 1));
    }

    fitList(box, "ev");
  }

  // ---------- up next: the header's countdown ----------
  // The next timed event that has not started. The ring is the last hour:
  // full an hour out, empty at the start, amber inside fifteen minutes.
  const RING = 188.5; // 2πr, r = 30, as in index.html
  function renderNext() {
    const card = $("next");
    const arc = $("next-arc");
    const now = new Date();
    const evs = upcoming(now);
    const next = evs && evs.find((e) => !e.all_day && evStart(e) > now);
    if (!next) {
      card.dataset.state = "none";
      $("next-what").textContent = evs ? "Nothing this week" : "—";
      $("next-when").textContent = "";
      arc.setAttribute("stroke-dashoffset", String(RING));
      return;
    }
    const start = evStart(next);
    const mins = Math.max(0, Math.round((start - now) / 60_000));
    const d = dayOf(next, now);
    let when;
    if (d === 0 && mins < 60) when = `in ${mins} min · ${hm(start)}`;
    else if (d === 0) when = `in ${Math.floor(mins / 60)} h ${mins % 60} min · ${hm(start)}`;
    else if (d === 1) when = `tomorrow · ${hm(start)}`;
    else when = `${shortDays[start.getDay()]} · ${hm(start)}`;
    card.dataset.state = mins <= 15 ? "soon" : "later";
    $("next-what").textContent = String(next.title || "Busy");
    $("next-when").textContent = when;
    arc.setAttribute("stroke-dashoffset", String(RING * (1 - Math.min(mins, 60) / 60)));
  }

  // ---------- context: one card, whichever matters now ----------
  // In order of precedence. The first whose `when` is true gets the card; the
  // others that are also true are named on its last line, so nothing that
  // matters is hidden without a word. The last entry always applies, so the
  // card is never empty. Later cards (commute, Shabbat, trash, deliveries,
  // now playing) slot in above it as their sources arrive.
  const CONTEXT = [
    { title: "Word of the day", short: "word", when: () => true, render: renderWord },
  ];

  // A static list, so nothing is fetched: one word a day, by day of the year.
  // Hebrew without niqqud, the transliteration, the meaning.
  const WORDS = [
    ["סבלנות", "savlanut", "patience"], ["שלום", "shalom", "peace; hello"],
    ["תודה", "todah", "thank you"], ["בוקר", "boker", "morning"],
    ["ערב", "erev", "evening"], ["לילה", "laylah", "night"],
    ["משפחה", "mishpachah", "family"], ["חבר", "chaver", "friend"],
    ["בית", "bayit", "home, house"], ["אהבה", "ahavah", "love"],
    ["שמחה", "simchah", "joy"], ["תקווה", "tikvah", "hope"],
    ["אמונה", "emunah", "faith"], ["חכמה", "chochmah", "wisdom"],
    ["אומץ", "ometz", "courage"], ["כבוד", "kavod", "respect, honour"],
    ["צדקה", "tzedakah", "charity, justice"], ["חסד", "chesed", "kindness"],
    ["אמת", "emet", "truth"], ["ברכה", "brachah", "blessing"],
    ["שבת", "Shabbat", "Sabbath, rest"], ["מנוחה", "menuchah", "rest"],
    ["עבודה", "avodah", "work"], ["מחשב", "machshev", "computer"],
    ["רשת", "reshet", "network"], ["שרת", "sharat", "server"],
    ["סיסמה", "sisma", "password"], ["מפתח", "mafteach", "key"],
    ["ענן", "anan", "cloud"], ["גשם", "geshem", "rain"],
    ["שמש", "shemesh", "sun"], ["ירח", "yareach", "moon"],
    ["כוכב", "kochav", "star"], ["ים", "yam", "sea"],
    ["הר", "har", "mountain"], ["עץ", "etz", "tree"],
    ["כלב", "kelev", "dog"], ["חתול", "chatul", "cat"],
    ["ספר", "sefer", "book"], ["מים", "mayim", "water"],
    ["לחם", "lechem", "bread"], ["קפה", "kafeh", "coffee"],
    ["זמן", "zman", "time"], ["שעה", "sha'ah", "hour"],
    ["יום", "yom", "day"], ["שבוע", "shavua", "week"],
    ["חודש", "chodesh", "month"], ["שנה", "shanah", "year"],
    ["לאט", "le'at", "slowly"], ["בסדר", "beseder", "okay, in order"],
    ["סבבה", "sababa", "great, cool"], ["תיקון", "tikkun", "repair"],
    ["דרך", "derech", "way, path"], ["שאלה", "she'elah", "question"],
    ["תשובה", "teshuvah", "answer; return"], ["התחלה", "hatchalah", "beginning"],
    ["כוח", "koach", "strength"], ["ביחד", "beyachad", "together"],
  ];
  function renderWord(box) {
    const now = new Date();
    const dayOfYear = Math.round((midnight(now) - new Date(now.getFullYear(), 0, 1)) / 86_400_000);
    const [he, tr, en] = WORDS[dayOfYear % WORDS.length];
    const w = el("div", "word", he);
    w.lang = "he";
    w.dir = "rtl";
    const sub = el("div", "word-sub");
    sub.append(el("b", null, tr), document.createTextNode(` · ${en}`));
    box.append(w, sub);
  }

  function renderContext() {
    const box = $("context");
    box.replaceChildren();
    const live = CONTEXT.filter((c) => c.when());
    const top = live[0];
    $("h-context").textContent = top.title;
    top.render(box);
    const rest = live.slice(1, -1).map((c) => c.short);
    $("context-also").textContent = rest.length ? `also: ${rest.join(" · ")}` : "";
  }

  function render() {
    renderWeather();
    renderHome();
    renderAlerts();
    // After the alerts: they take the height they need, and the calendar
    // fits itself into what is left.
    renderToday();
    renderNext();
    renderNodes();
    renderWan();
    renderContext();
    renderStatus();
  }

  async function poll() {
    await Promise.all([...QUESTIONS.map(ask), ...HA.map(askHa)]);
    render();
  }

  render();
  poll();
  setInterval(poll, POLL_MS);
  setInterval(renderStatus, 5_000);
  setTimeout(() => location.reload(), RELOAD_MS);
})();
