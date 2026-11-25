// Read-only status page of octo-devstack. All text goes through textContent; nothing from the API is parsed as HTML.
//
// Views (hash routes, so every place has a link; dashboard_open opens them, Dashboard.Views names them):
//   #/stack[/<slot>]   the board (stack x service: the shared stack, the lane stacks) and the sheet of the selected stack:
//                      facts, lease, services (where they run from, who started them), logs
//   #/lanes[/<lane>]   every lane (lane_list) and the sheet of the selected one: repos, lane stack, its last setup, the shared
//                      stack's services that run its build (UC-A) and its jobs with their evidence
//   #/builds[/<id>]    the jobs: refusals, running builds and test runs with progress, history (also of earlier daemon runs) with
//                      outcome and evidence (what the job ran on), for a test run its tests (failed ones first, per project),
//                      errors, time per repo and phase, and the output per repo (GET /api/builds/<id>/output); what repos
//                      and test projects usually take (GET /api/tools/job_stats) and which running one is overdue
//   #/profiles         saved stack starts and which one runs
//   #/config[/<tab>]   configuration inspector (GET /api/config, loaded on demand); its Daemon tab also shows the running
//                      binaries, whether a restart is safe, the Docker VM size and the last starts and stops (GET /api/daemon)
"use strict";

const REFRESH_MS = 5000;
const VIEWS = ["stack", "lanes", "builds", "profiles", "config"];
const CONFIG_TABS = [
    ["daemon", "Daemon"], ["services", "Services"], ["profiles", "Profiles"], ["slots", "Slots"],
    ["running", "Running services"], ["lanes", "Lane manifests"]
];

const ui = {
    overview: null,
    overviewText: "",
    lastOk: null,
    lastRender: 0,
    stale: false,
    log: null,                  // { key, slot, service, pid, node } - the one open service log
    buildDetails: new Map(),    // build id -> details of GET /api/builds/<id>
    buildOutputs: new Map(),    // build id -> GET /api/builds/<id>/output of the selected repo (or the job log)
    buildRepo: new Map(),       // build id -> the repo whose log is shown (absent: the job log)
    daemon: null,               // GET /api/daemon
    config: null,
    configLoadedAt: null,
    configError: null,
    configLoading: false,
    openFolds: new Set(),       // disclosure keys the reader opened (kept across renders)
    envFilter: "",
    onlyDifferences: false,
    showGone: false,            // builds view: also list finished runs whose lane or folder no longer exists
    durations: null             // builds view: GET /api/tools/job_stats { rows | error, loadedAt, loading }
};

const $ = (id) => document.getElementById(id);

function el(tag, props = {}, ...children) {
    const node = document.createElement(tag);
    for (const [k, v] of Object.entries(props || {})) {
        if (v === undefined || v === null || v === false) continue;
        if (k === "class") node.className = v;
        else if (k === "text") node.textContent = v;
        else node.setAttribute(k, v === true ? "" : v);
    }
    for (const c of children.flat(Infinity)) if (c !== null && c !== undefined && c !== false) node.append(c);
    return node;
}

// ---------- formatting ----------

const time = (iso) => iso ? new Date(iso).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hourCycle: "h23" }) : "";
const timeSec = (d) => d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23" });

// Local time; the date only when it is not today.
function dateTime(iso) {
    if (!iso) return "";
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return String(iso);
    const today = new Date();
    const sameDay = d.getFullYear() === today.getFullYear() && d.getMonth() === today.getMonth() && d.getDate() === today.getDate();
    return sameDay ? time(iso) : `${d.toLocaleDateString([], { year: "numeric", month: "2-digit", day: "2-digit" })} ${time(iso)}`;
}

function duration(fromIso, toIso) {
    if (!fromIso) return "";
    const s = Math.max(0, Math.round(((toIso ? new Date(toIso) : new Date()) - new Date(fromIso)) / 1000));
    if (s < 60) return `${s}s`;
    const m = Math.floor(s / 60);
    if (m < 60) return `${m}m`;
    const h = Math.floor(m / 60);
    return h < 48 ? `${h}h ${m % 60}m` : `${Math.floor(h / 24)}d ${h % 24}h`;
}

const seconds = (s) => {
    if (s === null || s === undefined) return "";
    const v = Math.round(s);
    if (v < 60) return `${v}s`;
    const m = Math.floor(v / 60);
    return m < 60 ? `${m}m ${v % 60}s` : `${Math.floor(m / 60)}h ${m % 60}m`;
};

const count = (n, one, many) => `${n} ${n === 1 ? one : (many || one + "s")}`;

// Windows paths: '\\' or '/' as separator, drive letter and folders compared case-insensitively. Results use '/'.
const isWindowsPath = (p) => /^[A-Za-z]:[\\/]/.test(p) || p.startsWith("\\\\");

function relative(path, base) {
    if (!path || !base) return path || "";
    if (isWindowsPath(path) || isWindowsPath(base)) {
        const norm = (p) => p.replace(/\\/g, "/");
        const p = norm(path);
        const b = norm(base).replace(/\/+$/, "") + "/";
        return p.toLowerCase().startsWith(b.toLowerCase()) ? p.slice(b.length) : path;
    }
    const b = base.endsWith("/") ? base : base + "/";
    return path.startsWith(b) ? path.slice(b.length) : path;
}

function tilde(path, home) {
    if (!home || !path) return path || "";
    const rel = relative(path, home);
    return rel !== path ? "~/" + rel : path;
}

// A path as the reader knows it: relative to the root folder, else to the home folder.
function place(path, o) {
    if (!path) return "";
    const rel = relative(path, o.rootPath);
    return rel !== path ? rel : tilde(path, o.home);
}

// ---------- shared components ----------

const STATE_LABEL = {
    healthy: "Healthy", starting: "Starting", unhealthy: "Not answering", exited: "Exited", off: "Not running", disabled: "Disabled",
    "stopped-for-build": "Stopped for a job"
};

// The one signal used everywhere: fill = state, ring = a process octo-devstack did not start.
function lamp(state, { foreign = false, title = null } = {}) {
    return el("span", { class: `lamp${foreign ? " foreign" : ""}`, "data-state": state, title },
        el("span", { class: "sr", text: `${foreign ? "foreign, " : ""}${STATE_LABEL[state] || state}` }));
}

const tag = (text, kind = null) => el("span", { class: `tag${kind ? " " + kind : ""}`, text });
const code = (text) => el("code", { text });
const note = (text, kind = null) => el("p", { class: `note${kind ? " " + kind : ""}`, text });
const empty = (text) => el("p", { class: "empty", text });

function copyButton(label, text, key) {
    const button = el("button", { type: "button", class: "btn", "data-fk": `copy:${key || text}`, title: `Copies ${text}`, text: label });
    button.addEventListener("click", async () => {
        try {
            await navigator.clipboard.writeText(text);
            button.textContent = "Copied";
            button.classList.add("done");
        } catch {
            button.textContent = text;   // no clipboard permission: show it, so it can be selected
        }
    });
    return button;
}

// A scalar the way every view shows it: masked secrets are named, not shown as asterisks.
function scalar(v) {
    if (v === "***") return el("span", { class: "masked", title: "Secret-looking value, masked by the daemon", text: "masked" });
    if (v === "") return el("span", { class: "muted", text: "(empty)" });
    if (typeof v === "boolean" || typeof v === "number") return el("span", { class: "lit", text: String(v) });
    return document.createTextNode(String(v));
}

function value(v) {
    if (v === null || v === undefined) return el("span", { class: "muted", text: "not set" });
    if (Array.isArray(v)) {
        if (v.length === 0) return el("span", { class: "muted", text: "none" });
        if (v.every((x) => x === null || typeof x !== "object")) {
            return el("span", { class: "list" }, v.map((x) => el("span", { class: "list-item" }, scalar(x))));
        }
        return el("div", { class: "nested" }, v.map((x) => value(x)));
    }
    if (typeof v === "object") {
        return Object.keys(v).length === 0 ? el("span", { class: "muted", text: "none" }) : kv(v, { nested: true });
    }
    return scalar(v);
}

// Key-value detail. pairs: object or [key, value|Node] list; null values are left out.
function kv(pairs, { nested = false, mono = false, skip = [] } = {}) {
    const dl = el("dl", { class: `kv${nested ? " nested" : ""}${mono ? " mono" : ""}` });
    const entries = Array.isArray(pairs) ? pairs : Object.entries(pairs || {});
    for (const [k, v] of entries) {
        if (v === null || v === undefined || skip.includes(k)) continue;
        dl.append(el("dt", { text: k }), el("dd", {}, v instanceof Node ? v : value(v)));
    }
    return dl;
}

// Disclosure that stays open across renders.
function fold(key, summary, body, { open = false } = {}) {
    const d = el("details", { class: "fold" });
    d.open = ui.openFolds.has(key) || (open && !ui.openFolds.has(`closed:${key}`));
    d.addEventListener("toggle", () => {
        if (d.open) { ui.openFolds.add(key); ui.openFolds.delete(`closed:${key}`); }
        else { ui.openFolds.delete(key); ui.openFolds.add(`closed:${key}`); }
    });
    d.append(el("summary", { "data-fk": `fold:${key}` }, summary), el("div", { class: "fold-body" }, body));
    return d;
}

function section(title, ...children) {
    return el("section", { class: "block" }, el("h2", { text: title }), children);
}

function table(headers, rows, cls = "") {
    return el("div", { class: "table-wrap" }, el("table", { class: `grid ${cls}` },
        el("thead", {}, el("tr", {}, headers.map((h) => el("th", { scope: "col", class: h.cls, text: h.text })))),
        el("tbody", {}, rows)));
}

// ---------- model ----------

function originShort(origin) {
    if (!origin) return "Another process";
    if (origin.kind === "start-octo") return "Start-Octo";
    if (origin.kind === "orphan") return "Leftover process";
    if (origin.kind === "session") return "Claude Code session";
    return origin.launcherCommand || "Another process";
}

function sessionText(session) {
    if (!session) return "";
    const parts = [];
    if (session.agent) parts.push(session.agent);
    if (session.sessionId) parts.push(session.sessionId.slice(0, 8));
    return parts.join(", ");
}

const externalSlot = (x) => x.slotHint || "default";

// One row per stack: the shared stack (slot "default") first, then the lane stacks (a lane's stack is the slot named after
// it) and named slots.
function slotRows(o) {
    const envs = o.lanes || [];
    const rows = (o.slots || []).map((s) => ({ name: s.name, slot: s, env: envs.find((e) => e.slot === s.name) || null }));
    if (!rows.some((r) => r.name === "default")) rows.unshift({ name: "default", slot: null, env: null });
    for (const e of envs) if (!rows.some((r) => r.name === e.slot)) rows.push({ name: e.slot, slot: null, env: e });
    for (const r of rows) {
        r.isDefault = r.name === "default";
        r.services = slotServices(o, r);
        const live = r.services.filter((m) => !m.dormant && !m.foreign);
        r.total = live.length;
        r.healthy = live.filter((m) => m.state === "healthy").length;
        r.outside = r.services.filter((m) => m.foreign).length;
        // Problems first, then what runs, then what is merely configured.
        const rank = (m) => m.dormant ? 2 : (m.state === "exited" || m.state === "unhealthy" || m.entryAssemblyProblem ? 0 : 1);
        r.services = r.services.map((m, i) => [m, i]).sort((a, b) => rank(a[0]) - rank(b[0]) || a[1] - b[1]).map((x) => x[0]);
        // The jobs of a lane (lane_build, lane_test) that run or wait.
        r.builds = o.builds.filter((b) => (b.state === "running" || b.state === "queued") && r.env && b.lane === r.env.name);
    }
    return rows;
}

// The services of a stack: what the daemon runs there, what runs on its ports without the daemon, and what is configured
// but not running. The shared stack's services come with every detail (stack_status), a lane stack's as the one-line rows
// of stack_status slots - both with runsFrom, health detail and who started them.
function slotServices(o, r) {
    const models = [];
    const groups = new Map(o.stack.external.groups.map((g) => [g.key, g]));
    const foreign = o.stack.external.services.filter((x) => externalSlot(x) === r.name);
    const own = r.isDefault ? o.stack.services : (r.slot ? r.slot.services : []);
    // Every stack lists the configured services that may run in it; services of the shared stack only have no place elsewhere.
    const configured = o.configured.filter((c) => r.isDefault || !c.exclusive).map((c) => c.name);
    const names = [...new Set([...configured, ...own.map((x) => x.name), ...foreign.map((x) => x.service)])];
    for (const name of names) {
        const conf = o.configured.find((c) => c.name === name);
        const inst = own.find((x) => x.name === name);
        const ext = foreign.filter((x) => x.service === name);
        if (inst) {
            let detail = "";
            if (inst.state === "exited") detail = `${inst.exitCode !== null && inst.exitCode !== undefined ? `exit code ${inst.exitCode}, ` : ""}${time(inst.exitedAt)}`;
            else if (inst.state !== "healthy") detail = inst.healthDetail || "";
            models.push({
                key: name, name, conf, state: inst.state, detail, health: inst.healthDetail || "", foreign: false,
                // Who started or overrode the service (startedBy, with its session and the call), else the daemon itself.
                startedBy: inst.startedBy || "octo-devstack",
                startedByDetail: [inst.startedBySession ? `session ${inst.startedBySession}` : "", inst.startedVia ? `via ${inst.startedVia}` : "",
                    inst.adopted ? "adopted after a daemon restart" : ""].filter(Boolean).join(", "),
                path: inst.source || inst.repoPath, runsFrom: inst.runsFrom || null, pid: inst.pid, processId: inst.processId || null,
                startedAt: inst.state === "exited" ? null : inst.startedAt, ports: inst.ports || [],
                command: inst.command ? `${inst.command} ${(inst.args || []).join(" ")}` : "", logFile: inst.logFile, hasLog: true,
                entryAssembly: inst.entryAssembly || null, entryAssemblyProblem: inst.entryAssemblyProblem || null
            });
        }
        for (const x of ext) {
            const g = groups.get(x.group);
            models.push({
                key: `${name}:${x.pid}`, name, conf, state: x.healthy ? "healthy" : "unhealthy", detail: x.healthy ? "" : (x.healthDetail || ""),
                health: x.healthDetail || "", foreign: true, startedBy: originShort(g?.origin), startedByDetail: sessionText(g?.origin?.session),
                path: x.source || x.repoPath || x.baseLane, runsFrom: null, pid: x.pid, logPid: x.pid, startedAt: x.startedAt,
                ports: x.ports || [], command: x.command || "", logFile: x.logFile, hasLog: !!x.logFile
            });
        }
        if (!inst && ext.length === 0) {
            models.push({
                key: name, name, conf, state: conf && conf.enabled ? "off" : "disabled", detail: "", dormant: true, foreign: false,
                startedBy: "", startedByDetail: "", ports: (conf?.ports || []).map((p) => p + (r.slot?.portOffset ?? r.env?.slotInfo?.portOffset ?? 0)), hasLog: true
            });
        }
    }
    return models;
}

function boardColumns(o, rows) {
    const names = o.configured.map((c) => c.name);
    for (const r of rows) for (const m of r.services) if (!names.includes(m.name)) names.push(m.name);
    return names;
}

const WORST = ["exited", "unhealthy", "starting", "healthy", "off", "disabled"];
function worstState(models) {
    if (models.length === 0) return null;
    return models.map((m) => m.state).sort((a, b) => WORST.indexOf(a) - WORST.indexOf(b))[0];
}

// The sources of a slot in one line: "branches/main" or "branches/main + wt-<env>: <repos>".
function sourcesLine(o, r) {
    const running = o.profiles.find((p) => p.activeIn === (r.isDefault ? "daemon" : `slot:${r.name}`));
    if (running && running.runsFrom) return running.runsFrom;
    if (r.env) {
        const repos = r.env.repos.map((x) => x.name);
        return `${r.env.base || "base lane"} + ${relative(r.env.path, o.rootPath)}${repos.length ? `: ${repos.join(", ")}` : ""}`;
    }
    const baseLane = r.isDefault ? o.stack.baseLane : r.slot?.baseLane;
    return baseLane ? place(baseLane, o) : "";
}

function route() {
    const parts = location.hash.replace(/^#\/?/, "").split("/").filter(Boolean).map(decodeURIComponent);
    const view = VIEWS.includes(parts[0]) ? parts[0] : "stack";
    return { view, arg: parts[1] || null };
}

// ---------- stack view ----------

function headline(o) {
    const s = o.stack;
    const ext = s.external;
    if (s.running) {
        const total = s.services.length;
        const healthy = s.services.filter((x) => x.state === "healthy").length;
        const exited = s.services.filter((x) => x.state === "exited").length;
        const where = `${place(s.baseLane, o)}, ${s.configuration}`;
        const p = s.profile;
        let text;
        if (p && p.exact) text = `The shared stack runs profile ${p.profile} (${where}), ${healthy} of ${total} healthy`;
        else if (p) text = `The shared stack runs from ${where}, differs from profile ${p.profile} in ${count(p.driftCount, "place")}, ${healthy} of ${total} healthy`;
        else text = `The shared stack runs from ${place(s.baseLane, o)} in ${s.configuration}, ${healthy} of ${total} services healthy`;
        if (exited > 0) text += `, ${exited} exited`;
        document.title = `${healthy}/${total} healthy, octo-devstack`;
        return text + ".";
    }
    if (ext.groups.length > 0) {
        const main = ext.groups[0];
        const answering = ext.services.filter((x) => x.healthy).length;
        const where = main.baseLane ? ` from ${place(main.baseLane, o)}` : "";
        const cfg = main.configuration ? ` in ${main.configuration}` : "";
        const looks = main.profile
            ? ` and looks like profile ${main.profile.profile}${main.profile.exact ? "" : ` (differs in ${count(main.profile.driftCount, "place")})`}`
            : "";
        document.title = `${answering}/${ext.services.length} answering (outside), octo-devstack`;
        return `A stack runs${where}${cfg} outside octo-devstack${looks}, ${answering} of ${ext.services.length} services answering.`;
    }
    document.title = "octo-devstack";
    return "The shared stack is not running.";
}

// The lease of a stack: the shared stack's from stack_status, a lane stack's from lane_list (both with last activity and idle
// minutes); a named slot only names its holder.
function leaseOf(o, r) {
    if (r.isDefault) return { holder: o.stack.lease.holder, queue: o.stack.lease.queue };
    return { holder: r.env?.lease || null, queue: [], name: r.slot?.leaseHolder || null };
}

function leaseText(o, r) {
    const { holder, queue, name } = leaseOf(o, r);
    const wait = queue.length ? `, ${count(queue.length, "session")} waiting` : "";
    if (!holder) return name || `free${wait}`;
    return `${holder.owner}${holder.session ? ` (${holder.session})` : ""}${holder.idleMinutes ? `, idle ${holder.idleMinutes} min` : ""}${wait}`;
}

// "last activity 14:02, idle 3 min, expires 14:32": when the holder last changed something and when the lease expires.
function leaseTimes(h) {
    return [
        h.lastActivityAt ? `last activity ${time(h.lastActivityAt)}` : "",
        h.idleMinutes !== undefined && h.idleMinutes !== null ? `idle ${count(h.idleMinutes, "minute")}` : "",
        h.expiresAt ? `expires ${time(h.expiresAt)}` : ""
    ].filter(Boolean).join(", ");
}

// The holder of a lease with its session, purpose (a lane's: "lane <name>; last change by <owner>") and times.
function leaseFact(holder, name = null) {
    if (holder) {
        return el("div", {},
            el("strong", { text: holder.owner }),
            holder.session ? el("span", { class: "sub", text: `session ${holder.session}` }) : null,
            holder.purpose ? el("span", { class: "sub", text: `for “${holder.purpose}”` }) : null,
            el("span", { class: "sub", text: leaseTimes(holder) }));
    }
    return name ? el("strong", { text: name }) : el("span", { class: "muted", text: "free" });
}

// The sessions waiting for a lease, first come first served.
function queueFact(queue) {
    return queue.length ? el("ol", { class: "plain" }, queue.map((w) => el("li", {}, el("strong", { text: w.owner }),
        w.session ? ` (session ${w.session})` : "", w.purpose ? ` for “${w.purpose}”` : "", ` since ${time(w.since)}`))) : null;
}

function renderBoard(o, rows, selected) {
    const columns = boardColumns(o, rows);
    const head = el("tr", {},
        el("th", { scope: "col", text: "Stack" }),
        el("th", { scope: "col", class: "lamps-head" }, el("div", { class: "lamps" },
            columns.map((n) => el("span", { class: "col-label" }, el("span", { text: n.replace(/Services$/, "") }))))),
        el("th", { scope: "col", text: "Healthy" }),
        el("th", { scope: "col", text: "Runs" }),
        el("th", { scope: "col", text: "Lease" }));

    const body = rows.map((r) => {
        const s = r.slot;
        const offset = s ? s.portOffset : r.env?.slotInfo?.portOffset;
        const sub = [];
        if (r.isDefault) sub.push("shared stack");
        else if (r.env) sub.push(`lane${r.env.workItem ? ` ${r.env.workItem}` : ""}`);
        else sub.push("slot (diagnostics)");
        if (offset) sub.push(`ports +${offset}`);
        const lamps = columns.map((n) => {
            const ms = r.services.filter((m) => m.name === n);
            if (ms.length === 0) return el("span", { class: "lamp-slot" });
            const live = ms.filter((m) => !m.dormant);
            const m = live.length ? live.sort((a, b) => WORST.indexOf(a.state) - WORST.indexOf(b.state))[0] : ms[0];
            const title = `${n}: ${(STATE_LABEL[m.state] || m.state).toLowerCase()}${m.foreign ? ", not started by octo-devstack" : ""}${m.ports.length ? `, ports ${m.ports.join(" ")}` : ""}`;
            return el("span", { class: "lamp-slot" }, lamp(m.state, { foreign: m.foreign, title }));
        });
        const running = r.total > 0;
        const runs = r.isDefault ? (o.stack.profile?.profile || (o.stack.running ? place(o.stack.baseLane, o) : "")) : (s?.profile || (s?.baseLane ? place(s.baseLane, o) : ""));
        const building = r.builds.find((b) => b.state === "running");
        const queued = r.builds.find((b) => b.state === "queued");
        return el("tr", { class: `board-row${r.name === selected ? " selected" : ""}${running ? "" : " idle"}` },
            el("th", { scope: "row", class: "slot-cell" },
                el("a", { href: `#/stack/${encodeURIComponent(r.name)}`, "aria-current": r.name === selected ? "true" : null, text: r.isDefault ? "shared" : r.name }),
                el("span", { class: "slot-sub", text: sub.join(", ") })),
            el("td", { class: "lamps-cell" }, el("div", { class: "lamps" }, lamps)),
            el("td", { class: "health-cell" }, running ? el("span", { class: r.healthy === r.total ? "ok" : "warn", text: `${r.healthy}/${r.total}` }) : (r.outside ? null : el("span", { class: "muted", text: "idle" })),
                r.outside ? el("span", { class: "outside", text: `${running ? "+" : ""}${r.outside} outside` }) : null),
            el("td", { class: "runs-cell" }, runs ? el("span", { text: runs }) : null,
                building ? el("a", { class: "chip work", href: `#/builds/${encodeURIComponent(building.id)}`, text: building.progress ? `${building.kind === "test" ? "testing" : "building"} ${progressIndex(building.progress)}/${progressCount(building.progress)}` : "building" }) : null,
                !building && queued ? el("a", { class: "chip", href: `#/builds/${encodeURIComponent(queued.id)}`, text: queued.kind === "test" ? "test run queued" : "build queued" }) : null),
            el("td", { class: "lease-cell", text: leaseText(o, r) }));
    });

    return el("div", { class: "plate board-plate" },
        el("table", { class: "board" }, el("thead", {}, head), el("tbody", {}, body)));
}

// Where a service runs from, as the daemon says it (runsFrom): a lane's build (linked to the lane), the base lane, or the
// folder of a source override; the folder itself below it.
function runsFromCell(o, m) {
    if (!m.path) return null;
    const from = m.runsFrom;
    const lane = from && from.startsWith("lane:") ? from.slice(5) : null;
    if (lane) {
        return el("span", { class: "path" }, el("a", { class: "tag ink", href: `#/lanes/${encodeURIComponent(lane)}`, text: from }),
            el("span", { class: "sub", text: place(m.path, o) }));
    }
    if (from === "base lane") return el("span", { class: "path" }, tag("base lane"), el("span", { class: "sub", text: place(m.path, o) }));
    // A folder of its own: a source override with a path, a plain worktree (or a process the daemon did not start).
    return el("span", { class: "path" }, el("span", { text: place(m.path, o) }), from ? tag("folder", "ink") : null);
}

// pid = the process octo-devstack started (on Windows the cmd.exe wrapper); processId = the service's own process below it (Windows).
function pidCell(m) {
    return el("td", { class: "num", title: m.processId ? "pid: the process octo-devstack started (the cmd.exe wrapper); process: the service itself" : null },
        m.pid ? String(m.pid) : "", m.processId && m.processId !== m.pid ? el("span", { class: "sub", text: `process ${m.processId}` }) : null);
}

// The cells of a service row after its name: state, who started it, where it runs from, pid, uptime, ports.
function serviceCells(o, m) {
    return [
        el("td", {}, el("span", { class: `state ${m.state}`, text: m.foreign && m.state === "healthy" ? "Answering" : (STATE_LABEL[m.state] || m.state) }),
            m.detail ? el("span", { class: "sub", text: m.detail }) : null),
        el("td", {}, m.startedBy ? el("span", { class: m.foreign ? "foreign-text" : null, text: m.startedBy }) : null,
            m.startedByDetail ? el("span", { class: "sub", text: m.startedByDetail }) : null),
        el("td", {}, runsFromCell(o, m), m.entryAssemblyProblem ? el("span", { class: "sub stop-text", text: "loaded another assembly" }) : null),
        pidCell(m),
        el("td", { class: "num", text: m.startedAt ? duration(m.startedAt) : "" }),
        el("td", { class: "num", text: m.ports.join(" ") })
    ];
}

const SERVICE_HEAD = [
    { text: "", cls: "lamp-td" }, { text: "Service" }, { text: "State" }, { text: "Started by" }, { text: "Runs from" },
    { text: "PID", cls: "num" }, { text: "Up", cls: "num" }, { text: "Ports", cls: "num" }
];

function serviceRows(o, r) {
    const out = [];
    for (const m of r.services) {
        const key = `${r.name}/${m.key}`;
        const open = ui.log && ui.log.key === key;
        const toggle = m.hasLog
            ? el("button", { type: "button", class: "row-toggle", "aria-expanded": String(!!open), "data-fk": `svc:${key}`, text: m.name })
            : el("span", { class: "row-name", text: m.name });
        if (m.hasLog) toggle.addEventListener("click", () => toggleLog(key, r.name, m));
        out.push(el("tr", { class: `service${m.dormant ? " dormant" : ""}${open ? " open" : ""}` },
            el("td", { class: "lamp-td" }, lamp(m.state, { foreign: m.foreign })),
            el("td", {}, toggle, m.conf?.description && !m.dormant ? el("span", { class: "sub", text: m.conf.description }) : null),
            serviceCells(o, m)));
        if (open) out.push(el("tr", { class: "detail-row" }, el("td", { colspan: "8" }, serviceFacts(o, m), ui.log.node)));
    }
    return out;
}

// A service row without its log (the lanes view): the name links to the stack's sheet, where the log is.
function plainServiceRows(o, r, models) {
    return models.map((m) => el("tr", { class: "service" },
        el("td", { class: "lamp-td" }, lamp(m.state, { foreign: m.foreign })),
        el("td", {}, el("a", { class: "row-name", href: `#/stack/${encodeURIComponent(r.name)}`, title: "Log and command line in the stack view", text: m.name })),
        serviceCells(o, m)));
}

// What the process is, above its log: rebuilt with every refresh (the log panel below it is kept).
function serviceFacts(o, m) {
    return el("div", { class: "service-facts" },
        m.entryAssemblyProblem ? note(`The process does not run the build of its folder: ${m.entryAssemblyProblem}. Restart the service to load the current build.`, "stop") : null,
        kv([
            ["Command", m.command ? code(m.command) : null],
            ["Loaded assembly", m.entryAssembly ? code(tilde(m.entryAssembly, o.home)) : null],
            ["Health check", m.health || null]
        ]));
}

function logPanel() {
    const grep = el("input", { type: "search", class: "log-grep", placeholder: "regex, e.g. error|exception", spellcheck: "false", "data-fk": "log-grep", "aria-label": "Filter log lines" });
    const previous = el("input", { type: "checkbox", class: "log-previous", "data-fk": "log-previous" });
    const node = el("div", { class: "log" },
        el("div", { class: "log-tools" },
            el("label", {}, "Filter ", grep),
            el("label", { class: "check" }, previous, " Previous run"),
            el("span", { class: "log-file" })),
        el("pre", { class: "output log-text", tabindex: "0", "data-fk": "log-text", text: "Loading…" }));
    let debounce;
    grep.addEventListener("input", () => { clearTimeout(debounce); debounce = setTimeout(() => loadLog(), 300); });
    previous.addEventListener("change", () => loadLog());
    return node;
}

function toggleLog(key, slot, m) {
    if (ui.log && ui.log.key === key) ui.log = null;
    else ui.log = { key, slot, service: m.name, pid: m.logPid || null, node: logPanel() };
    render();
    if (ui.log) loadLog(true);
}

async function loadLog(scrollToEnd = false) {
    const log = ui.log;
    if (!log) return;
    const pre = log.node.querySelector(".log-text");
    const grep = log.node.querySelector(".log-grep").value.trim();
    const previous = log.node.querySelector(".log-previous").checked;
    const atEnd = scrollToEnd || pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 8;
    const params = new URLSearchParams({ lines: "400" });
    if (log.pid) params.set("pid", String(log.pid));
    if (log.slot !== "default") params.set("slot", log.slot);
    if (grep) params.set("grep", grep);
    if (previous) params.set("previous", "true");
    try {
        const res = await fetch(`/api/logs/${encodeURIComponent(log.service)}?${params}`, { cache: "no-store" });
        const data = await res.json();
        if (ui.log !== log) return;
        const file = log.node.querySelector(".log-file");
        if (!res.ok) {
            pre.textContent = data.error || `The daemon answered HTTP ${res.status}.`;
            file.textContent = "";
            return;
        }
        file.textContent = tilde(data.logFile, ui.overview?.home);
        const text = data.text || (grep ? "No line matches the filter." : "The log is empty.");
        if (pre.textContent !== text) pre.textContent = text;
        if (atEnd) pre.scrollTop = pre.scrollHeight;
    } catch {
        if (ui.log === log) pre.textContent = "The daemon did not answer.";
    }
}

function foreignBlocks(o, r) {
    const groups = o.stack.external.groups
        .map((g) => ({ g, members: o.stack.external.services.filter((x) => x.group === g.key && externalSlot(x) === r.name) }))
        .filter((x) => x.members.length > 0);
    if (groups.length === 0) return null;
    return section("Not started by octo-devstack",
        note("octo-devstack never stops these processes. It cannot start its own services while they hold the ports."),
        groups.map(({ g, members }) => {
            const origin = g.origin || {};
            const ports = members.flatMap((m) => m.ports);
            return el("div", { class: "foreign-block" },
                el("p", { class: "foreign-title", text: origin.description || originShort(origin) }),
                kv([
                    ["Services", `${g.services.join(", ")}${ports.length ? ` on ${ports.join(", ")}` : ""}`],
                    ["Running", g.startedAt ? `${duration(g.startedAt)}, since ${dateTime(g.startedAt)}` : null],
                    ["From", g.baseLane ? `${place(g.baseLane, o)}${g.configuration ? ` in ${g.configuration}` : ""}` : null],
                    ["Looks like", g.profile ? `profile ${g.profile.profile}${g.profile.exact ? "" : `, differs in ${count(g.profile.driftCount, "place")}`}` : null],
                    ["Command", origin.launcherCommand ? code(origin.launcherCommand) : null],
                    ["Session folder", origin.session?.workingDirectory ? tilde(origin.session.workingDirectory, o.home) : null],
                    ["Stop it with", origin.stopHint ? el("span", { class: "inline" }, code(origin.stopHint), copyButton("Copy", origin.stopHint, `stop:${g.key}`)) : null]
                ]));
        }));
}

function profileFact(match) {
    if (!match) return null;
    const drift = match.drift || [];
    return el("div", {},
        el("span", {}, match.profile, " ", match.exact ? tag("exact", "clear") : tag(`differs in ${count(match.driftCount, "place")}`, "caution")),
        match.edited ? el("span", { class: "sub", text: "The profile was edited since the start." }) : null,
        drift.length ? el("ul", { class: "plain" }, drift.map((d) => el("li", { text: d.service ? `${d.service}: ${d.detail}` : d.detail }))) : null);
}

// The repositories of a lane: role, branch and folder (a worktree adopted in place lies outside the lane folder).
function laneRepos(o, e) {
    return e.repos.length ? table(
        [{ text: "Repository" }, { text: "Role" }, { text: "Branch" }, { text: "Folder" }],
        e.repos.map((x) => {
            const inside = relative(x.path, e.path) !== x.path;
            return el("tr", {},
                el("td", { class: "mono", text: x.name }),
                el("td", {}, tag(x.role, x.role === "feature" ? "ink" : null)),
                el("td", { class: "mono", text: x.branch || `detached at ${(x.baseCommit || "").slice(0, 8)}` }),
                el("td", {}, el("span", { class: "path", text: place(x.path, o) }), inside ? null : tag("in place", "caution")));
        }), "compact") : empty(`The lane holds no repository yet: lane_add_repo(owner, session, lane="${e.name}", repo).`);
}

function renderSheet(o, r) {
    const s = r.slot;
    const e = r.env;
    const st = o.stack;
    const running = r.total > 0;
    const idle = r.services.every((m) => m.dormant);
    const info = s || e?.slotInfo;
    const startedBy = r.isDefault ? st.startedBy : s?.startedBy;
    const lease = leaseOf(o, r);

    // UC-A: the shared stack's services that run a lane's build (runsFrom lane:<name>).
    const laneBuilds = r.isDefault ? r.services.filter((m) => m.runsFrom && m.runsFrom.startsWith("lane:")) : [];
    const facts = kv([
        ["Lane", e ? el("a", { href: `#/lanes/${encodeURIComponent(e.name)}`, text: `${e.name}${e.workItem ? ` (${e.workItem})` : ""}` }) : null],
        ["Sources", sourcesLine(o, r) || null],
        ["Lane builds", laneBuilds.length ? el("ul", { class: "plain" }, laneBuilds.map((m) => el("li", {}, `${m.name} from `,
            el("a", { href: `#/lanes/${encodeURIComponent(m.runsFrom.slice(5))}`, text: m.runsFrom })))) : null],
        ["Configuration", r.isDefault && st.running ? st.configuration : null],
        ["Profile", r.isDefault ? profileFact(st.running ? st.profile : null) : (s?.profile || null)],
        ["Started", r.isDefault && st.running ? `${dateTime(st.startedAt)}${startedBy ? ` by ${startedBy}` : ""}` : (startedBy ? `by ${startedBy}` : null)],
        ["Lease", leaseFact(lease.holder, lease.name)],
        ["Waiting", queueFact(lease.queue)],
        ["Ports", info ? `+${info.portOffset}${info.prefix ? `, prefix ${info.prefix}` : ""}${e && e.slotInfo && !e.slotInfo.reserved ? " (what the next start would get)" : ""}` : null],
        ["Logs", s?.logDirectory ? tilde(s.logDirectory, o.home) : null],
        ["Identity overlay", s?.artifacts ? tilde(s.artifacts.identityOverlay, o.home) : null],
        ["octo-cli installation", s?.artifacts ? tilde(s.artifacts.installation, o.home) : null]
    ]);

    const name = r.isDefault ? "the shared stack" : (e ? `the stack of lane ${e.name}` : `slot ${r.name}`);
    const title = el("div", { class: "sheet-head" },
        el("h2", {}, r.isDefault ? "Shared stack" : (e ? `Lane stack ${e.name}` : `Slot ${r.name}`)),
        running ? tag(`${r.healthy} of ${r.total} healthy`, r.healthy === r.total ? "clear" : "caution") : (r.outside ? null : tag("not running")),
        r.outside ? tag(`${r.outside} outside octo-devstack`, "foreign") : null,
        el("p", { class: "hint", text: r.isDefault ? "Change it with the MCP tools (and its lease)." : `Change it with the MCP tools (${e ? `lane="${e.name}"` : `slot="${r.name}"`}).` }));

    const serviceTable = r.services.length && !(idle && !r.isDefault)
        ? table(SERVICE_HEAD, serviceRows(o, r), "services")
        : empty(e
            ? `Nothing runs in ${name}. Start it with stack_start(owner, session, lane="${e.name}").`
            : `Nothing runs in ${name}. Start it with stack_start(owner, session, slot="${r.name}") (diagnostics; a lane has its own stack).`);

    return el("section", { class: "sheet", "aria-label": r.isDefault ? "Shared stack" : `Stack ${r.name}` },
        title,
        e?.problem ? note(e.problem, "stop") : null,
        el("div", { class: "sheet-grid" },
            el("div", { class: "sheet-facts" },
                facts,
                r.isDefault ? null : note("Use a separate browser profile for this stack's identity: cookies are not port-scoped.")),
            el("div", { class: "sheet-main" },
                el("div", { class: "plate" }, serviceTable),
                foreignBlocks(o, r))));
}

function attentionList(items) {
    return items.length ? el("ul", { class: "attention", "aria-label": "Needs attention" }, items.map((i) =>
        el("li", { class: i.level }, el("a", { href: i.href }, el("span", { class: "attention-mark", "aria-hidden": "true" }), el("span", { text: i.text }))))) : null;
}

function renderStack(o, arg) {
    const rows = slotRows(o);
    const selected = rows.find((r) => r.name === arg) || rows[0];
    // What needs the reader's eye, worst first: the daemon builds the list (Attention.cs), the same one stack_attention returns.
    const text = headline(o);
    return [
        el("h1", { text }),
        attentionList(o.attention || []),
        arg && selected.name !== arg ? note(`There is no stack or lane named ${arg}.`, "caution") : null,
        renderBoard(o, rows, selected.name),
        renderSheet(o, selected)
    ];
}

// ---------- lanes view ----------

const SETUP_STATE = { done: "clear", unchanged: null, failed: "stop", skipped: "caution" };

// The last setup of a lane stack (stack_setup, or the automatic one after its first healthy start): every step's outcome.
function setupBlock(l, setup) {
    if (!setup) {
        return empty(`No setup ran yet. The first start of the lane stack sets it up by itself (admin, octo-cli contexts, login, identity overlay); ` +
            `stack_setup(owner, session, lane="${l.name}") repeats it.`);
    }
    return el("div", {},
        el("p", { class: "sub", text: `${setup.success ? "Every step worked" : "A step failed"}: ${dateTime(setup.at)}, ${setup.trigger}.` }),
        el("div", { class: "plate" }, table([{ text: "Step" }, { text: "Status" }, { text: "What it did" }], setup.steps.map((x) => el("tr", {},
            el("td", { class: "mono", text: x.step }),
            el("td", {}, tag(x.status, SETUP_STATE[x.status])),
            el("td", { text: x.summary }))), "compact")),
        (setup.warnings || []).length ? el("ul", { class: "plain notes" }, setup.warnings.map((w) => el("li", { class: "caution-text", text: w }))) : null,
        setup.success ? null : note(`stack_setup(owner, session, lane="${l.name}", steps=[...]) repeats a failed step; setup_check names machine causes.`, "caution"));
}

// What a job ran on (evidence): the verdict, then per repository the short HEAD and whether its work tree was clean.
const shortHead = (h) => (h ? h.slice(0, 8) : "no HEAD");

function evidenceTag(e) {
    if (!e) return null;
    if (e.unchanged === true) return tag("unchanged", "clear");
    if (e.unchanged === false) return tag("changed", "caution");
    return tag("read at the start");
}

function evidenceLine(e) {
    if (!e || !e.repos.length) return null;
    const shown = e.repos.slice(0, 3).map((x) => {
        const s = x.end || x.start;
        return `${x.repo} ${shortHead(s?.head)}${s?.clean === false ? " (changes)" : ""}`;
    });
    const more = e.repos.length - shown.length + (e.omitted || 0);
    return el("span", { class: "sub mono", text: `${shown.join(", ")}${more > 0 ? `, ${more} more` : ""}` });
}

function workTreeTag(s) {
    if (!s) return null;
    if (s.error) return el("span", { class: "stop-text", text: s.error });
    if (s.clean === true) return tag("clean", "clear");
    if (s.clean === false) return tag(count(s.changes ?? 0, "change"), "caution");
    return null;
}

function evidenceBlock(o, e) {
    if (!e || !e.repos.length) return null;
    const verdict = e.unchanged === true
        ? "Unchanged: every repository had the same HEAD and the same changes at the start and at the end of the job - a later edit is not covered; check the work tree again before relying on it now."
        : e.unchanged === false
            ? "Changed: a repository's HEAD or its changes differ between the start and the end of the job."
            : "Read at the start of the job; the end follows when it ends.";
    return el("div", {},
        el("h3", { text: "Ran on" }),
        el("p", { class: "sub", text: verdict }),
        table([{ text: "Repository" }, { text: "HEAD" }, { text: "Branch" }, { text: "At the start" }, { text: "At the end" }, { text: "" }],
            e.repos.map((x) => {
                const a = x.start?.head;
                const b = x.end?.head;
                return el("tr", {},
                    el("td", {}, el("span", { class: "mono", text: x.repo }), el("span", { class: "sub", text: place(x.path, o) })),
                    el("td", { class: "mono", text: a && b && a !== b ? `${shortHead(a)} → ${shortHead(b)}` : shortHead(b || a) }),
                    el("td", { class: "mono", text: (x.end || x.start)?.branch || "detached" }),
                    el("td", {}, workTreeTag(x.start)),
                    el("td", {}, workTreeTag(x.end)),
                    el("td", {}, x.unchanged === true ? tag("unchanged", "clear") : x.unchanged === false ? tag("changed", "caution") : null));
            }), "compact"),
        e.omitted ? el("p", { class: "sub", text: `${count(e.omitted, "more repository", "more repositories")} unchanged; job_status(id, repo="...") lists one.` }) : null);
}

// What a job is: a lane's (lane_build, lane_test) or the base lane's (base_build, base_test), a build or a test run, and its size.
function jobKind(b) {
    const what = b.kind === "test" ? "test run" : (b.kind === "lane" ? "build" : `${b.kind} build`);
    const p = b.progress;
    const size = !p ? "" : b.kind === "test"
        ? (p.projectCount ? count(p.projectCount, "test project") : "")
        : (p.repoCount ? count(p.repoCount, "repository", "repositories") : "");
    return [tag(b.lane ? "lane" : "base", b.lane ? "ink" : null), " ", what, size ? el("span", { class: "sub", text: size }) : null];
}

function laneJobRows(o, jobs) {
    return jobs.map((b) => el("tr", {},
        el("td", {}, el("a", { class: "row-name", href: `#/builds/${encodeURIComponent(b.id)}`, text: b.id }),
            b.outcome?.summary ? el("span", { class: `sub${b.state === "failed" ? " stop-text" : ""}`, text: b.outcome.summary }) : null),
        el("td", {}, jobKind(b)),
        el("td", {}, tag(buildStateText(b), BUILD_KIND[b.state])),
        el("td", { class: "mono", text: b.owner }),
        el("td", {}, evidenceTag(b.evidence), evidenceLine(b.evidence)),
        el("td", { class: "num", text: b.times.startedAt ? dateTime(b.times.startedAt) : `queued ${time(b.times.queuedAt)}` }),
        el("td", { class: "num", text: b.times.startedAt ? duration(b.times.startedAt, b.times.finishedAt) : "" })));
}

const JOB_HEAD = [{ text: "Job" }, { text: "Kind" }, { text: "State" }, { text: "Owner" }, { text: "Ran on" }, { text: "Started", cls: "num" }, { text: "Took", cls: "num" }];

// The sheet of one lane: its facts and lease, the repositories, the lane stack with its last setup, the shared stack's
// services that run its build (UC-A, inSharedStack of lane_list) and its jobs.
function laneSheet(o, l) {
    const rows = slotRows(o);
    const r = rows.find((x) => x.env && x.env.name === l.name);
    const live = r ? r.services.filter((m) => !m.dormant) : [];
    const sharedRow = rows.find((x) => x.isDefault);
    const shared = sharedRow ? sharedRow.services.filter((m) => !m.foreign && (l.inSharedStack || []).includes(m.name)) : [];
    const slot = (o.slots || []).find((s) => s.name === l.slot) || null;
    const jobs = o.builds.filter((b) => b.lane === l.name);
    const info = l.slotInfo;

    const title = el("div", { class: "sheet-head" },
        el("h2", { text: `Lane ${l.name}` }),
        l.workItem ? tag(l.workItem, "ink") : null,
        l.running ? tag(`lane stack ${l.healthy} of ${l.total} healthy`, l.healthy === l.total ? "clear" : "caution") : tag("lane stack not running"),
        shared.length ? tag(`${count(shared.length, "service")} in the shared stack`, "work") : null,
        el("p", { class: "hint", text: `Change it with the MCP tools (lane="${l.name}").` }));

    const ports = info ? `ports +${info.portOffset}${info.prefix ? `, prefix ${info.prefix}` : ""}${info.reserved ? "" : " (what the next start would get)"}` : l.slot;
    const facts = kv([
        ["Work item", l.workItem || null],
        ["Owner", l.owner || null],
        ["Created", l.created ? dateTime(l.created) : null],
        ["Folder", tilde(l.path, o.home)],
        ["Base lane", l.base || null],
        ["Lane stack", el("a", { href: `#/stack/${encodeURIComponent(l.slot)}`, text: ports })],
        ["Lease", leaseFact(l.lease || null)],
        ["Jobs now", (l.builds || []).length ? el("ul", { class: "plain" }, l.builds.map((b) => el("li", { text: b }))) : null]
    ]);

    const laneStack = live.length
        ? el("div", { class: "plate" }, table(SERVICE_HEAD, plainServiceRows(o, r, live), "services"))
        : empty(`Nothing runs in the lane stack. Start it with stack_start(owner, session, lane="${l.name}").`);
    const inShared = shared.length
        ? el("div", { class: "plate" }, table(SERVICE_HEAD, plainServiceRows(o, sharedRow, shared), "services"))
        : empty(`No service of the shared stack runs this lane's build. UC-A: lane_build, lease_acquire, then service_restart(owner, session, ` +
            `services=[<service>], overrides={<service>: {source: "lane:${l.name}"}}).`);

    return el("section", { class: "sheet", "aria-label": `Lane ${l.name}` },
        title,
        l.problem ? note(l.problem, "stop") : null,
        el("div", { class: "sheet-grid" },
            el("div", { class: "sheet-facts" }, facts),
            el("div", { class: "sheet-main" },
                section("Repositories", el("div", { class: "plate" }, laneRepos(o, l))),
                section("Lane stack", laneStack),
                section("Last setup of the lane stack", setupBlock(l, slot?.setup || null)),
                section("In the shared stack", inShared),
                section("Jobs", jobs.length ? el("div", { class: "plate" }, table(JOB_HEAD, laneJobRows(o, jobs), "builds"))
                    : empty(`No job of this lane yet: lane_build(owner, session, lane="${l.name}"), then lane_test.`)))));
}

function renderLanes(o, arg) {
    const lanes = o.lanes || [];
    const running = lanes.filter((l) => l.running).length;
    if (!lanes.length) {
        return [el("h1", { text: "No lane." }),
            empty("A lane is the workspace of one work item (octo-tools: feature environment): lane_create(owner, session, lane, repos, branch, workItem) creates one.")];
    }
    const selected = lanes.find((l) => l.name === arg) || lanes[0];
    // The attention items of the lanes and their stacks (the daemon's list, as on the stack view).
    const items = (o.attention || []).filter((i) => i.kind === "lane" || lanes.some((l) => i.slot === l.slot));
    const rows = lanes.map((l) => {
        const active = (l.builds || []).length;
        const shared = (l.inSharedStack || []).length;
        const current = l.name === selected.name;
        return el("tr", { class: current ? "active" : null },
            el("td", {}, el("a", { class: "row-name", href: `#/lanes/${encodeURIComponent(l.name)}`, "aria-current": current ? "true" : null, text: l.name }),
                l.problem ? el("span", { class: "sub stop-text", text: l.problem }) : null),
            el("td", { text: l.workItem || "" }),
            el("td", { class: "mono", text: l.owner || "" }),
            el("td", { text: l.repos.map((x) => x.name).join(", ") }),
            el("td", {}, l.running ? tag(`${l.healthy}/${l.total} healthy`, l.healthy === l.total ? "clear" : "caution") : el("span", { class: "muted", text: "not running" }),
                l.slotInfo ? el("span", { class: "sub", text: `ports +${l.slotInfo.portOffset}` }) : null),
            el("td", {}, l.lease ? el("span", { text: l.lease.session || l.lease.owner }) : el("span", { class: "muted", text: "free" }),
                l.lease ? el("span", { class: "sub", text: `idle ${count(l.lease.idleMinutes ?? 0, "minute")}` }) : null),
            el("td", {}, active ? tag(`${active} running or queued`, "work") : null, shared ? tag(`${shared} in the shared stack`, "work") : null));
    });
    return [
        el("h1", { text: `${count(lanes.length, "lane")}, ${running ? `${count(running, "lane stack")} running` : "no lane stack running"}.` }),
        attentionList(items),
        arg && selected.name !== arg ? note(`There is no lane named ${arg}.`, "caution") : null,
        el("div", { class: "plate" }, table([{ text: "Lane" }, { text: "Work item" }, { text: "Owner" }, { text: "Repositories" }, { text: "Lane stack" },
            { text: "Lease" }, { text: "Jobs" }], rows, "lanes")),
        laneSheet(o, selected)
    ];
}

// ---------- builds view (the jobs) ----------

const PHASES = { stopping: "stopping services", build: "building", tests: "compiling tests", packages: "copying packages", restarting: "restarting services",
    lock: "waiting for the docker test lock" };

const phaseText = (b, phase) => (b.kind === "test" && phase === "tests" ? "running tests" : PHASES[phase] || phase);

function buildStateText(b) {
    if (b.state === "queued") return `queued, ${b.queue ? b.queue.position : "?"}. in line`;
    if (b.state === "running" && b.progress) return phaseText(b, b.progress.phase) || b.state;
    return b.state;
}

const TEST_STATE = { passed: "clear", failed: "stop", error: "stop", running: "work", noMatch: null, noTests: "caution" };

// The tests of a test run: totals, the projects (failed ones first, as the daemon orders them), then every failed
// test by name with its first error message and stack frame, and run-level errors (broken build, crashed host).
function testsBlock(t) {
    if (!t) return null;
    const num = (v) => (v === undefined || v === null ? "" : String(v));
    const failing = t.projects.filter((p) => p.failedTests.length || (p.errors || []).length);
    return el("div", { class: "build-tests" },
        el("p", { class: "sub", text: `${count(t.total, "test")}: ${t.passed} passed, ${t.failed} failed, ${t.skipped} skipped.` }),
        t.lockWait ? note(`${t.lockWait}.`, "caution") : null,
        t.dockerWarning ? note(t.dockerWarning, "caution") : null,
        t.docker ? note(`Docker check ${t.docker.check}` +
            (t.docker.freeGiB != null ? `: ${t.docker.freeGiB} GiB free of ${t.docker.memoryGiB ?? "?"} GiB, minimum ${t.docker.minFreeGiB ?? "?"} GiB` : "") +
            (t.docker.containers ? `; biggest containers: ${t.docker.containers.join(", ")}` : "") +
            (t.docker.limits ? `; limits: ${t.docker.limits}${t.docker.limited ? ` (${count(t.docker.limited, "container")}${t.docker.limitFailed ? `, ${t.docker.limitFailed} failed` : ""})` : ""}` : "") +
            (t.docker.message && t.docker.check !== "ok" ? `. ${t.docker.message}` : "."),
        t.docker.check === "refused" ? "stop" : t.docker.check === "warned" ? "caution" : null) : null,
        failing.map((p) => el("div", {},
            el("h3", { text: `${p.project}: ${p.failedTests.length ? count(p.failed ?? p.failedTests.length, "failed test") : p.state}` }),
            (p.errors || []).length ? el("ul", { class: "plain notes" }, p.errors.map((e) => el("li", { class: "stop-text", text: e }))) : null,
            p.failedTests.length ? table([{ text: "Test" }, { text: "Message" }], p.failedTests.map((f) => el("tr", {},
                el("td", { class: "mono", text: f.name }),
                el("td", {}, f.message || "", f.stackFrame ? el("span", { class: "sub mono", text: f.stackFrame }) : null))), "compact") : null,
            p.moreFailed ? el("p", { class: "sub", text: `${p.moreFailed} more failed; job_status(id, project="${p.project}") lists them.` }) : null)),
        table([{ text: "Test project" }, { text: "State" }, { text: "Tests", cls: "num" }, { text: "Passed", cls: "num" }, { text: "Failed", cls: "num" },
            { text: "Skipped", cls: "num" }, { text: "Time", cls: "num" }],
        t.projects.map((p) => el("tr", {},
            el("td", { class: "mono" }, p.project, p.runner ? tag(p.runner) : null, p.docker ? tag("docker") : null, p.buildReason ? el("span", { class: "sub", text: `build: ${p.buildReason}` }) : null,
                p.note ? el("span", { class: "sub", text: p.note }) : null),
            el("td", {}, tag(p.state, TEST_STATE[p.state])),
            el("td", { class: "num", text: num(p.total) }), el("td", { class: "num", text: num(p.passed) }), el("td", { class: "num", text: num(p.failed) }),
            el("td", { class: "num", text: num(p.skipped) }), el("td", { class: "num", text: p.seconds ? seconds(p.seconds) : "" }))), "compact"));
}

const BUILD_KIND = { running: "work", queued: null, succeeded: "clear", failed: "stop", canceled: null };

const phaseSeconds = (v) => v ? seconds(v) : "";

// Why a lane build left a repository out.
const SKIP_REASON = { unchanged: "unchanged since its last build", notSelected: "not selected", excluded: "excluded", nothingToBuild: "nothing to build" };

// The parts of a step (octo-tools AB#8831): "catalogs 120 s, restore 4 s, compile 9 s" below the step's time; nothing without them.
function parts(list) {
    const shown = list.filter(([, v]) => v !== undefined && v !== null && v >= 0.05);
    return shown.length ? el("span", { class: "sub", text: shown.map(([name, v]) => `${name} ${seconds(v)}`).join(", ") }) : null;
}

// Where the time of a build went: per repo its phases (from the cmdlet's repoDone events) and the whole time.
function repoTable(p) {
    const head = [{ text: "Repository" }, { text: "State" }, { text: "Test projects" }, { text: "Build", cls: "num" }, { text: "Test compile", cls: "num" },
        { text: "Packages", cls: "num" }, { text: "Total", cls: "num" }, { text: "Copied", cls: "num" }];
    const rows = p.repos.map((x) => {
        // A parallel lane build has several repos building at once (p.running); else the one in p.current.
        const now = (p.running || (p.current ? [p.current] : [])).find((r) => r.repo === x.repo);
        const current = !!now;
        const ended = x.state === "done" || x.state === "failed";
        const total = current ? seconds(now.seconds) : (ended ? phaseSeconds(x.seconds ?? ((x.buildSeconds || 0) + (x.testSeconds || 0) + (x.packageSeconds || 0))) : "");
        const usual = current ? usualText(now) : null;
        return el("tr", { class: `repo ${x.state}` },
            el("td", { class: "mono", text: x.repo }),
            el("td", {}, el("span", { class: `repo-state ${x.state}`, title: x.reason ? `Reason: ${x.reason}` : null,
                text: current && x.phase ? `${x.state} (${x.phase})` : (x.state === "skipped" && x.reason ? `skipped: ${SKIP_REASON[x.reason] || x.reason}` : x.state) })),
            el("td", { class: x.tests === "notCompiled" ? "caution-text" : "muted", text: x.tests === "notCompiled" ? "not compiled" : (x.tests || "") }),
            el("td", { class: "num" }, ended ? phaseSeconds(x.buildSeconds) : "", ended ? parts([["catalogs", x.catalogSeconds], ["restore", x.restoreSeconds], ["compile", x.compileSeconds]]) : null),
            el("td", { class: "num" }, ended ? phaseSeconds(x.testSeconds) : "", ended ? parts([["restore", x.testRestoreSeconds]]) : null),
            el("td", { class: "num", text: ended ? phaseSeconds(x.packageSeconds) : "" }),
            el("td", { class: `num${current && now.overdue ? " stop-text" : ""}` }, total, usual ? el("span", { class: "sub", text: usual }) : null),
            el("td", { class: "num", text: x.copied !== undefined && x.copied !== null ? String(x.copied) : "" }));
    });
    const t = p.totals;
    return [
        table(head, rows, "compact"),
        t ? el("p", { class: "sub", text: `Build ${seconds(t.build)}, test compile ${seconds(t.tests)}, packages ${seconds(t.packages)}${t.slowest ? `; slowest: ${t.slowest}` : ""}.` }) : null,
        p.repos.some((x) => x.tests) ? el("p", { class: "sub", text: "A build runs no tests: \"compiled\" means the test projects compile. lane_test / base_test run them." }) : null,
        p.repos.some((x) => x.state === "skipped" && x.reason)
            ? el("p", { class: "sub", text: `${count(p.repos.filter((x) => x.state === "skipped" && x.reason).length, "repository", "repositories")} not built.` }) : null
    ];
}

// A build's progress counts repos (repoIndex/repoCount), a test run's test projects (projectIndex/projectCount).
function progressIndex(p) { return p.repoIndex ?? p.projectIndex ?? 0; }
function progressCount(p) { return p.repoCount ?? p.projectCount ?? 0; }

// What a running repo or test project usually takes (job_stats): "usually 5m 10s", "usually 5m 10s, overdue after 14m".
function usualText(now) {
    if (!now || now.typicalSeconds === undefined || now.typicalSeconds === null) return null;
    return `usually ${seconds(now.typicalSeconds)}${now.limitSeconds ? `, overdue after ${seconds(now.limitSeconds)}` : ""}`;
}

// The running repos or test projects that run far longer than usual - they probably hang.
function overdueNote(b) {
    const p = b.progress;
    const late = (p.running || (p.current ? [p.current] : [])).filter((r) => r.overdue);
    if (!late.length) return null;
    const what = b.kind === "test" ? "test project" : "repository";
    return note(late.map((r) => `The ${what} ${r.project ?? r.repo} has run for ${seconds(r.seconds)}; it usually takes ${seconds(r.typicalSeconds)}. It may hang: ` +
        `job_output(id="${b.id}", repo="${r.project ?? r.repo}") shows its log, job_cancel stops the job.`).join(" "), "stop");
}

function runningBuild(o, b) {
    const p = b.progress;
    const elapsed = b.times.elapsedSeconds || 0;
    const eta = b.times.etaSeconds;
    const known = eta !== null && eta !== undefined;
    const overdue = (p.running || (p.current ? [p.current] : [])).some((r) => r.overdue);
    // A test run has no ETA; what its current project usually takes stands in its place.
    const usual = b.kind === "test" && !p.running ? usualText(p.current) : null;
    return el("div", { class: "plate running-build" },
        el("div", { class: "running-head" },
            el("a", { class: "build-target", href: `#/builds/${encodeURIComponent(b.id)}`, text: place(b.target, o) }),
            el("span", {}, jobKind(b).slice(0, 3)), tag(phaseText(b, p.phase), p.phase === "lock" ? "caution" : "work"),
            p.running ? tag(`${p.running.length} repos at once`, "work") : null,
            overdue ? tag("overdue", "stop") : null,
            el("span", { class: "muted", text: `${b.kind === "test" ? "project" : "repo"} ${progressIndex(p)} of ${progressCount(p)}${p.running ? ` (${p.running.map((r) => r.repo ?? r.project).join(", ")})` : ""}, ${seconds(elapsed)}${known ? `, about ${seconds(eta)} left` : (b.kind === "test" ? "" : ", no estimate yet")}` +
                (usual ? `; ${p.current.project}: ${seconds(p.current.seconds)}, ${usual}` : "") })),
        overdueNote(b),
        known
            ? el("progress", { max: "100", value: String(Math.min(99, Math.round(100 * elapsed / Math.max(1, elapsed + eta)))), "aria-label": "Build progress" })
            : el("progress", { max: String(Math.max(1, progressCount(p))), value: String(Math.max(0, progressIndex(p) - 1)), "aria-label": "Build progress by repository" }),
        b.kind === "test" ? testsBlock(b.tests) : repoTable(p),
        el("p", { class: "sub", text: `Started ${time(b.times.startedAt)} by ${b.owner}; progress from ${p.source === "events" ? (b.kind === "test" ? "test events" : "build events") : "the repos' logs"}.` }));
}

function errorGroups(d) {
    if (!d.diagnostics || d.diagnostics.errors.length === 0) return null;
    const byRepo = new Map();
    for (const e of d.diagnostics.errors) {
        if (!byRepo.has(e.repo)) byRepo.set(e.repo, []);
        byRepo.get(e.repo).push(e);
    }
    return el("div", { class: "build-errors" },
        el("p", { class: "sub", text: `${count(d.diagnostics.errorCount, "error")}, ${count(d.diagnostics.warningCount, "warning")}` }),
        [...byRepo].map(([repo, errors]) => el("div", {},
            el("h3", { text: repo }),
            table([{ text: "Where" }, { text: "Code" }, { text: "Message" }], errors.map((e) => el("tr", {},
                el("td", { class: "mono", text: e.file ? `${e.file.split(/[\\/]/).slice(-2).join("/")}${e.line ? `:${e.line}` : ""}` : (e.project || "") }),
                el("td", { class: "mono err-code", text: e.code }),
                el("td", { text: e.message }))), "compact"))));
}

function buildDetail(o, b) {
    const d = ui.buildDetails.get(b.id);
    const packages = b.packages;
    const facts = kv([
        ["Target", tilde(b.target, o.home)],
        ["Kind", el("span", {}, jobKind(b))],
        ["Owner", b.owner],
        ["Configuration", b.configuration],
        ["Queued", dateTime(b.times.queuedAt)],
        ["Started", b.times.startedAt ? dateTime(b.times.startedAt) : null],
        ["Finished", b.times.finishedAt ? dateTime(b.times.finishedAt) : null],
        ["Lane", b.lane ? el("a", { href: `#/lanes/${encodeURIComponent(b.lane)}`, text: b.lane }) : null],
        ["Packages", packages ? `${place(packages.path, o)}${packages.isolated ? " (isolated)" : ""}` : null],
        ["Feed", packages?.feed ? place(packages.feed, o) : null],
        ["Stopped services", b.stoppedServices && b.stoppedServices.length ? b.stoppedServices : null],
        ["Job log", b.logs?.job ? tilde(b.logs.job, o.home) : null]
    ]);
    const lines = [b.outcome?.summary, b.outcome?.hint, b.catalogs ? `CK catalogs - ${b.catalogs}.` : null, b.queue?.waitingFor ? `Waiting: ${b.queue.waitingFor}.` : null, ...(b.notes || [])].filter(Boolean);
    return el("div", { class: "build-detail" },
        facts,
        lines.length ? el("ul", { class: "plain notes" }, lines.map((l) => el("li", { text: l }))) : null,
        evidenceBlock(o, (d && d.evidence) || b.evidence),
        b.kind === "test" && b.state !== "running" ? testsBlock((d && d.tests) || b.tests) : null,
        d ? errorGroups(d) : null,
        b.kind !== "test" && b.progress && b.state !== "running" ? repoTable(b.progress) : null,
        buildOutput(b));
}

// The output of a build: one log at a time - the job's own, or a repo's (repos with errors first). The daemon keeps
// the repos' logs in its state folder, so they are here after the build ended and after a daemon restart.
function buildOutput(b) {
    const out = ui.buildOutputs.get(b.id);
    const log = out && !out.error ? out.log : null;
    // Nothing picked: the daemon shows what happens now - the log of the repository (or test project) that runs -
    // because the job log stays nearly empty while the cmdlet works. "@job" is the reader's explicit pick of the job log.
    const chosen = ui.buildRepo.get(b.id) || null;
    const selected = chosen === "@job" ? null : (chosen || (log && log.selected) || null);
    const pick = (repo, label, title) => {
        const button = el("button", { type: "button", class: `btn${(repo || null) === selected ? " on" : ""}`, "aria-pressed": String((repo || null) === selected),
            "data-fk": `build-log:${b.id}:${repo || ""}`, title, text: label });
        button.addEventListener("click", () => {
            if (repo) ui.buildRepo.set(b.id, repo); else if (b.state === "running") ui.buildRepo.set(b.id, "@job"); else ui.buildRepo.delete(b.id);
            ui.buildOutputs.delete(b.id);
            render(true);
            loadBuild(b.id);
        });
        return button;
    };
    const repos = out && !out.error ? out.repos.filter((x) => x.hasLog) : [];
    const text = !out ? "Loading…" : out.error ? out.error
        : log.lines.length ? log.lines.join("\n")
            : (log.source === "none" ? "The daemon holds no log of this repository (it was not built, or wrote none)." : "No output yet.");
    const where = log ? [
        log.selected ? `${log.selected}: ` : "Job log: ",
        log.source === "kept" ? "kept by the daemon when the repository's build ended" : log.source === "live" ? `${b.kind === "test" ? "the test log" : "the repository's Invoke-Build.log"}, still being written (refreshed every few seconds)` : "what the cmdlet printed",
        log.truncated ? `; the last ${log.lines.length} lines` : "",
        log.path ? ` (${tilde(log.path, ui.overview.home)})` : ""
    ].join("") : null;
    return el("div", { class: "build-logs" },
        el("div", { class: "log-picker", role: "group", "aria-label": "Output to show" },
            pick(null, "Job log", "What the build cmdlet printed"),
            repos.map((x) => pick(x.repo, x.errorCount ? `${x.repo} (${count(x.errorCount, "error")})` : x.repo,
                `${x.state}${x.warningCount ? `, ${count(x.warningCount, "warning")}` : ""}`))),
        where ? el("p", { class: "sub", text: where }) : null,
        el("pre", { class: "output build-output", tabindex: "0", "data-fk": `build-out:${b.id}:${selected || ""}`, text }));
}

async function loadBuild(id) {
    const repo = ui.buildRepo.get(id);
    const get = async (url) => {
        try {
            const res = await fetch(url, { cache: "no-store" });
            const data = await res.json();
            return res.ok ? data : { error: data.error || `The daemon answered HTTP ${res.status}.` };
        } catch {
            return { error: "The daemon did not answer." };
        }
    };
    const [detail, output] = await Promise.all([
        get(`/api/builds/${encodeURIComponent(id)}`),
        get(`/api/builds/${encodeURIComponent(id)}/output?lines=600${repo ? `&repo=${encodeURIComponent(repo)}` : ""}`)
    ]);
    ui.buildDetails.set(id, detail);
    if ((ui.buildRepo.get(id) || null) === (repo || null)) ui.buildOutputs.set(id, output);   // the reader may have picked another log meanwhile
    if (route().view === "builds" && route().arg === id) render(true);
}

function renderBuilds(o, arg) {
    const refusals = (o.buildRefusals || []).filter((x) => x.conflicts.length > 0).slice(0, 3);
    const running = o.builds.filter((b) => b.state === "running" && b.progress);
    const waiting = o.builds.filter((b) => b.state === "queued").sort((a, b) => (a.queue ? a.queue.position : 0) - (b.queue ? b.queue.position : 0));
    const rows = [];
    // Runs whose lane or folder no longer exists stay hidden unless the reader asks for them (or opened one).
    const gone = o.builds.filter((b) => b.gone);
    const shown = o.builds.filter((b) => !b.gone || ui.showGone || b.id === arg);
    for (const b of shown) {
        const t = b.times;
        const open = arg === b.id;
        rows.push(el("tr", { class: `build${open ? " open" : ""}` },
            el("td", {}, el("a", { class: "row-toggle", href: open ? "#/builds" : `#/builds/${encodeURIComponent(b.id)}`, "aria-expanded": String(open), text: place(b.target, o) }),
                b.gone ? el("span", { class: "sub", text: `Gone: ${b.gone}.` }) : null,
                b.state === "failed" && b.outcome?.summary && !b.gone ? el("span", { class: "sub stop-text", text: b.outcome.summary }) : null,
                b.state === "queued" && b.queue?.waitingFor ? el("span", { class: "sub", text: b.queue.waitingFor }) : null),
            el("td", {}, jobKind(b)),
            el("td", {}, tag(buildStateText(b), b.gone ? null : BUILD_KIND[b.state]), b.gone ? tag("gone") : null),
            el("td", { text: b.owner }),
            el("td", {}, evidenceTag(b.evidence), evidenceLine(b.evidence)),
            el("td", { class: "num", text: t.startedAt ? dateTime(t.startedAt) : `queued ${time(t.queuedAt)}` }),
            el("td", { class: "num", text: t.startedAt ? duration(t.startedAt, t.finishedAt) : "" })));
        if (open) rows.push(el("tr", { class: "detail-row" }, el("td", { colspan: "7" }, buildDetail(o, b))));
    }
    return [
        el("h1", { text: running.length ? `${count(running.length, "job")} running${waiting.length ? `, ${waiting.length} queued` : ""}.` : (waiting.length ? `${count(waiting.length, "job")} queued.` : "No build or test run is running.") }),
        refusals.length ? el("ul", { class: "attention" }, refusals.map((x) => el("li", { class: "caution" }, el("span", { class: "attention-body" },
            el("span", { class: "attention-mark", "aria-hidden": "true" }),
            el("span", {}, el("strong", { text: `Refused at ${time(x.at)}: ` }), `${x.kind} build of ${place(x.target, o)} by ${x.owner}. `,
                x.conflicts.map((c) => `${c.service} (${c.repo}) runs from it, started by ${c.startedBy}${c.stopHint ? `; stop: ${c.stopHint}` : ""}`).join("; "), "."))))) : null,
        arg && !o.builds.some((b) => b.id === arg) ? note(`The daemon no longer knows job ${arg}.`, "caution") : null,
        running.map((b) => runningBuild(o, b)),
        section("History",
            gone.length ? goneToggle(gone.length) : null,
            shown.length
                ? el("div", { class: "plate" }, table([{ text: "Target" }, { text: "Kind" }, { text: "State" }, { text: "Owner" }, { text: "Ran on" }, { text: "Started", cls: "num" }, { text: "Took", cls: "num" }], rows, "builds"))
                : empty(o.builds.length ? "Only runs of removed lanes or folders; show them above." : "No builds or test runs yet. Start one with lane_build / base_build (check build_plan first), lane_test or base_test.")),
        durationsSection()
    ];
}

// What repository builds and test projects usually take (GET /api/tools/job_stats), read at most once a minute while the
// jobs view is open.
async function loadDurations() {
    ui.durations = { ...(ui.durations || {}), loading: true };
    try {
        const res = await fetch("/api/tools/job_stats", { cache: "no-store" });
        ui.durations = res.ok ? { rows: await res.json(), loadedAt: Date.now() } : { error: `HTTP ${res.status}`, loadedAt: Date.now() };
    } catch {
        ui.durations = { error: "the daemon did not answer", loadedAt: Date.now() };
    }
    if (route().view === "builds") render();
}

function durationsSection() {
    const d = ui.durations;
    if (!d || (!d.loading && Date.now() - (d.loadedAt || 0) > 60000)) loadDurations();
    if (!d || (!d.rows && !d.error)) return section("Usual durations", empty("Reading the durations…"));
    if (d.error) return section("Usual durations", note(`Could not read the durations: ${d.error}.`, "caution"));
    const rows = d.rows;
    const builds = rows.filter((r) => r.kind === "build").length;
    const head = [{ text: "Repository" }, { text: "Test project" }, { text: "Configuration" }, { text: "Samples", cls: "num" }, { text: "Median", cls: "num" },
        { text: "p90", cls: "num" }, { text: "Max", cls: "num" }, { text: "Last", cls: "num" }, { text: "Overdue after", cls: "num" }];
    const body = rows.map((r) => el("tr", {},
        el("td", { class: "mono" }, r.repo, el("span", { class: "sub", text: r.kind === "test" ? "test run" : "build" })),
        el("td", { class: "mono" }, r.project || "",
            r.compilesFirst === true || r.compilesFirst === false ? el("span", { class: "sub", text: r.compilesFirst ? "compiles first" : "on its last build" }) : null),
        el("td", { text: r.configuration }),
        el("td", { class: "num", text: String(r.samples) }),
        el("td", { class: "num", text: seconds(r.medianSeconds) }),
        el("td", { class: "num", text: seconds(r.p90Seconds) }),
        el("td", { class: "num", text: seconds(r.maxSeconds) }),
        el("td", { class: `num${r.lastSeconds > r.p90Seconds ? " caution-text" : ""}` }, seconds(r.lastSeconds), r.lastAt ? el("span", { class: "sub", text: dateTime(r.lastAt) }) : null),
        el("td", { class: "num", text: r.limitSeconds ? seconds(r.limitSeconds) : "" })));
    return section("Usual durations",
        rows.length
            ? fold("durations", `${count(builds, "repository build")}, ${count(rows.length - builds, "test project")}, slowest first`,
                [note("From the last 30 successful builds per repository (every lane) and the test projects of unfiltered test runs; a test project's runs that compile it first and those on its last build are kept apart. A running repository or test project beyond \"overdue after\" (twice p90, at least median + 2 minutes; from three samples on) is marked overdue: it probably hangs."),
                    table(head, body, "compact")])
            : empty("No durations yet: they are recorded when a build or an unfiltered test run ends."));
}

// The switch that shows the runs whose lane or folder no longer exists (hidden by default).
function goneToggle(n) {
    const box = el("input", { type: "checkbox", "data-fk": "builds-gone" });
    box.checked = ui.showGone;
    box.addEventListener("change", () => { ui.showGone = box.checked; render(true); });
    return el("div", { class: "toolbar" }, el("label", { class: "check" }, box, ` Show ${count(n, "run")} of removed lanes or folders`));
}

// ---------- profiles view ----------

// Where a profile runs: the shared stack, a lane stack (a lane's stack is the slot named after it) or another slot, or a
// stack outside the daemon that looks like it.
function activeTag(o, activeIn) {
    if (!activeIn) return null;
    if (activeIn === "daemon") return tag("running in the shared stack", "clear");
    if (activeIn.startsWith("slot:")) {
        const slot = activeIn.slice(5);
        const lane = (o.lanes || []).find((l) => l.slot === slot);
        return tag(lane ? `running in the stack of lane ${lane.name}` : `running in slot ${slot}`, "clear");
    }
    return tag("an outside stack looks like it", "foreign");
}

function renderProfiles(o) {
    const s = o.stack;
    let match = s.running ? s.profile : null;
    let outside = false;
    if (!match) {
        const g = s.external.groups.find((x) => x.profile);
        if (g) { match = g.profile; outside = true; }
    }
    const lead = match
        ? `${outside ? "The stack outside octo-devstack looks like" : "The shared stack runs"} ${match.profile}${match.exact ? "" : `, differing in ${count(match.driftCount, "place")}`}.`
        : "No profile is running in the shared stack.";
    const rows = o.profiles.map((p) => el("tr", { class: p.activeIn ? "active" : null },
        el("td", {}, el("span", { class: "row-name", text: p.name }), " ", activeTag(o, p.activeIn),
            p.description ? el("span", { class: "sub", text: p.description }) : null,
            p.error ? el("span", { class: "sub stop-text", text: `Invalid: ${p.error}` }) : null),
        el("td", {}, el("span", { text: count(p.services.length, "service") }),
            el("span", { class: "sub", text: p.services.map((x) => x.replace(/Services$/, "")).join(", ") }),
            p.instances.length ? el("span", { class: "sub", text: `instances: ${p.instances.join(", ")}` }) : null),
        el("td", {}, el("span", { text: p.runsFrom || p.baseLane }), el("span", { class: "sub", text: p.configuration })),
        el("td", { class: "actions" }, copyButton("Copy start command", `stack_start(profile="${p.name}")`, `profile:${p.name}`),
            el("a", { class: "more", href: "#/config/profiles", text: "Definition" }))));
    return [
        el("h1", { text: lead }),
        match && match.edited ? note("The profile was edited since the start.", "caution") : null,
        match && match.drift.length ? el("ul", { class: "attention" }, match.drift.map((d) => el("li", { class: "caution" }, el("span", { class: "attention-body" },
            el("span", { class: "attention-mark", "aria-hidden": "true" }), el("span", { text: d.service ? `${d.service}: ${d.detail}` : d.detail }))))) : null,
        o.profiles.length
            ? el("div", { class: "plate" }, table([{ text: "Profile" }, { text: "Services" }, { text: "Runs from" }, { text: "" }], rows, "profiles"))
            : empty("No profiles in the configuration. Save the running stack with admin_profile_save(capture=\"daemon\").")
    ];
}

// ---------- configuration view (GET /api/config, loaded on demand) ----------

function foldTitle(name, ...tags) {
    return el("span", { class: "fold-title" }, el("span", { class: "fold-name", text: name }), tags.filter(Boolean));
}

const configViews = {
    daemon(c) {
        const d = c.daemon;
        return [
            daemonProcess(),
            section("Daemon", kv([
                ["Config file", d.configPath], ["Root", d.rootPath], ["octo-tools", d.octoToolsPath], ["Base lane", d.baseLane],
                ["Configuration", d.configuration], ["Target framework", d.targetFramework], ["Log directory", d.logDirectory],
                ["Stop timeout", d.stopTimeoutSeconds !== undefined && d.stopTimeoutSeconds !== null ? `${d.stopTimeoutSeconds} s` : null],
                ["File written", c.fileWrittenAt ? new Date(c.fileWrittenAt).toLocaleString() : null],
                ["Loaded by the daemon", new Date(c.loadedAt).toLocaleString()]
            ])),
            section("Environment variables of every service", Object.keys(d.envVars || {}).length ? kv(d.envVars, { mono: true }) : empty("No global environment variables.")),
            section("Env providers",
                note("Scripts that compute environment values at start. Their results are never shown here."),
                (d.envProviders || []).length
                    ? d.envProviders.map((p) => fold(`provider:${p.name}`, foldTitle(p.name, p.enabled === false ? tag("disabled") : null,
                        tag((p.whenServices || []).length ? `for ${p.whenServices.join(", ")}` : "every start")),
                    el("pre", { class: "output script", tabindex: "0", text: p.script || "" })))
                    : empty("No env providers."))
        ];
    },
    services(c) {
        return [section("Service definitions", c.services.map((s) => {
            const d = s.definition;
            return fold(`service:${d.name}`,
                foldTitle(d.name, d.enabled ? null : tag("disabled"), d.optional ? tag("optional") : null, s.exclusive ? tag("shared stack only", "ink") : null,
                    s.problem ? tag("problem", "stop") : null, el("span", { class: "fold-meta", text: (d.ports || []).join(" ") })),
                [
                    s.problem ? note(s.problem, "stop") : null,
                    kv([["Description", d.description], ["Resolved repository", s.repoPath], ["Resolved working directory", s.workingDirectory]]),
                    kv(d, { skip: ["name", "description"], mono: true })
                ]);
        }))];
    },
    profiles(c) {
        if (c.profiles.length === 0) return [empty("No profiles in the configuration.")];
        return [section("Profile definitions", c.profiles.map((p) => fold(`profile:${p.name}`,
            foldTitle(p.name, p.chain.length > 1 ? tag(`extends ${p.chain.slice(1).join(", then ")}`) : null, p.error ? tag("invalid", "stop") : null,
                p.resolved?.hash ? el("span", { class: "fold-meta", text: p.resolved.hash }) : null),
            [
                p.error ? note(p.error, "stop") : null,
                el("div", { class: "split" },
                    el("div", {}, el("h3", { text: "Set by this profile" }), kv(p.asWritten, { mono: true })),
                    p.resolved ? el("div", {}, el("h3", { text: "Resolved (extends, settings and instances merged)" }), kv(p.resolved, { mono: true })) : null)
            ])))];
    },
    slots(c) {
        const live = c.slots.map((s) => fold(`slot:${s.name}`,
            foldTitle(s.name === "default" ? "default (the shared stack)" : s.name, tag(s.state, s.state === "running" ? "clear" : null),
                el("span", { class: "fold-meta", text: `index ${s.index}, ports +${s.portOffset}${s.prefix ? `, prefix ${s.prefix}` : ""}` })),
            el("div", { class: "split" },
                el("div", {}, el("h3", { text: "Derived values (slotDerivations for this slot)" }),
                    Object.keys(s.derived || {}).length ? kv(s.derived, { mono: true }) : empty("The shared stack derives nothing: its values are the configuration's.")),
                el("div", {}, el("h3", { text: "Ports" }), kv(Object.entries(s.ports || {}).map(([k, v]) => [k, v.join(" ")]), { mono: true })))));
        const retired = (c.retiredSlots || []).length
            ? table([{ text: "Index", cls: "num" }, { text: "Was" }, { text: "Prefix" }, { text: "Ports", cls: "num" }, { text: "Retired" }, { text: "Tenant databases" }],
                c.retiredSlots.map((x) => el("tr", {},
                    el("td", { class: "num", text: String(x.index) }), el("td", { text: x.name }), el("td", { class: "mono", text: x.prefix }),
                    el("td", { class: "num", text: `+${x.portOffset}` }), el("td", { text: new Date(x.retiredAt).toLocaleString() }),
                    el("td", { class: "mono", text: (x.tenantDatabases || []).join(", ") }))), "compact")
            : empty("No retired slot.");
        return [
            section("Slots", live),
            section("Retired slots", note("The index of a removed slot is kept back while its data may still exist (admin_slot_retired lists the leftovers). admin_slot_forget(owner, index, confirmDataDropped=true) frees it."),
                (c.retiredSlots || []).length ? el("div", { class: "plate" }, retired) : retired)
        ];
    },
    running(c) {
        if (c.running.length === 0) return [empty("No service of octo-devstack runs, so there are no environment variables to show.")];
        const filter = el("input", { type: "search", id: "env-filter", "data-fk": "env-filter", placeholder: "e.g. OCTO_SYSTEM", spellcheck: "false", value: ui.envFilter });
        const only = el("input", { type: "checkbox", "data-fk": "env-only" });
        only.checked = ui.onlyDifferences;
        const list = el("div", {});
        const draw = () => list.replaceChildren(...runningFolds(c));
        filter.addEventListener("input", () => { ui.envFilter = filter.value; draw(); });
        only.addEventListener("change", () => { ui.onlyDifferences = only.checked; draw(); });
        draw();
        return [section("Environment variables of the running services",
            note("Exactly what service_env returns. A marked value differs from what the configuration, the slot derivation or the running profile would set."),
            el("div", { class: "toolbar" }, el("label", {}, "Filter variables ", filter), el("label", { class: "check" }, only, " Differences only")),
            list)];
    },
    lanes(c) {
        if (c.lanes.length === 0) return [empty("No lane. Create one with lane_create.")];
        return [section("Lane manifests (octo-tools: feature environments)", c.lanes.map((e) => fold(`lane:${e.name}`,
            foldTitle(e.name, e.manifest?.workItem ? tag(e.manifest.workItem, "ink") : null, e.problem ? tag("problem", "stop") : null,
                el("span", { class: "fold-meta", text: `slot ${e.slot || e.manifest?.slot || e.name}` })),
            [
                e.problem ? note(e.problem, "stop") : null,
                kv([["Folder", e.path], ["Base lane", e.basePath], ["Lease holder", e.leaseOwner], ["Owner", e.manifest?.owner],
                    ["Created", e.manifest?.created ? new Date(e.manifest.created).toLocaleString() : null], ["Schema version", e.manifest?.schemaVersion]]),
                (e.manifest?.repos || []).length ? table([{ text: "Repository" }, { text: "Role" }, { text: "Branch" }, { text: "Base commit" }, { text: "Path" }],
                    e.manifest.repos.map((x) => el("tr", {},
                        el("td", { class: "mono", text: x.name }), el("td", {}, tag(x.role, x.role === "feature" ? "ink" : null)),
                        el("td", { class: "mono", text: x.branch || "(detached)" }), el("td", { class: "mono", text: (x.baseCommit || "").slice(0, 12) }),
                        el("td", { class: "mono", text: x.path }))), "compact") : null
            ])))];
    }
};

function runningFolds(c) {
    const needle = ui.envFilter.trim().toLowerCase();
    return c.running.map((r) => {
        const e = r.service;
        const diffs = new Map(r.differences.map((d) => [d.key, d]));
        const keys = [...new Set([...Object.keys(e.envVars), ...r.differences.map((d) => d.key)])]
            .filter((k) => (!needle || k.toLowerCase().includes(needle)) && (!ui.onlyDifferences || diffs.has(k)));
        const rows = keys.map((k) => {
            const d = diffs.get(k);
            const v = k in e.envVars ? e.envVars[k] : null;
            return el("tr", { class: d ? "diff" : null },
                el("td", { class: "mono env-key" }, d ? el("span", { class: "diff-mark", title: "Differs from the expected value" }, el("span", { class: "sr", text: "differs: " })) : null, k),
                el("td", { class: "mono env-value" }, v === null || v === undefined ? el("span", { class: "muted", text: "not set" }) : scalar(v),
                    d ? el("span", { class: "expected" }, "expected ", el("span", { class: "expected-value" }, scalar(d.expected ?? "")), ` from ${d.expectedFrom}`) : null));
        });
        const name = `${r.slot === "default" ? "" : r.slot + "/"}${e.service}`;
        return fold(`running:${name}`,
            foldTitle(name, r.differences.length ? tag(count(r.differences.length, "difference"), "caution") : tag("as expected", "clear"),
                el("span", { class: "fold-meta", text: `pid ${e.pid}, read from ${e.source}` })),
            [
                e.note ? note(e.note) : null,
                rows.length ? table([{ text: "Variable" }, { text: "Value" }], rows, "compact env") : empty(needle || ui.onlyDifferences ? "No variable matches." : "No environment variables.")
            ], { open: r.differences.length > 0 });
    });
}

// The running daemon (GET /api/daemon): its binaries, whether it may be restarted now, its last starts and stops.
function daemonProcess() {
    const s = ui.daemon;
    if (!s) return section("Running daemon", empty("Loading…"));
    if (s.error) return section("Running daemon", note(`Could not load: ${s.error}`, "caution"));
    const p = s.daemon;
    const r = s.restart;
    const EVENT = { start: ["started", "clear"], stop: ["stopped", null], lost: ["killed or crashed", "stop"] };
    return [
        section("Running daemon", kv([
            ["Process", `pid ${p.pid}, since ${dateTime(p.startedAt)}`],
            ["Version", `${p.version}${p.commit ? `, commit ${p.commit}` : ""}`],
            ["Binaries", `${p.configuration} build of ${new Date(p.binaryWrittenAt).toLocaleString()}`],
            ["Kind", p.development ? "development daemon (--dev): its own port, config and state" : "shared daemon"],
            ["Listens on", p.url], ["State folder", p.stateDirectory]
        ])),
        section("Restart",
            note(r.safe ? "Safe to restart now: no build runs or waits." : "Not now: builds run or wait. Restart only with the developer's go.", r.safe ? null : "caution"),
            r.blockers.length ? el("ul", { class: "plain notes" }, r.blockers.map((b) => el("li", { text: b }))) : null,
            r.warnings.length ? el("ul", { class: "plain notes" }, r.warnings.map((w) => el("li", { class: "muted", text: w }))) : null),
        s.docker ? section("Docker",
            s.docker.available
                ? kv([
                    ["Docker VM", `${s.docker.memoryGb ?? "?"} GiB memory, ${s.docker.cpus ?? "?"} CPUs${s.docker.operatingSystem ? ` (${s.docker.operatingSystem})` : ""}`],
                    ["kind cluster", s.docker.kind ? "runs in it" : "not running"],
                    ["Limits for test runs with containers", `${s.docker.minMemoryGb} GiB, ${s.docker.minCpus} CPUs (dockerVm in the configuration)`]
                ])
                : empty("Docker does not answer (docker info)."),
            s.docker.warning ? note(s.docker.warning, "caution") : null) : null,
        section("Last starts and stops",
            s.history.length
                ? el("div", { class: "plate" }, table([{ text: "When", cls: "num" }, { text: "Event" }, { text: "Trigger" }, { text: "Version" }, { text: "Detail" }],
                    s.history.map((e) => el("tr", {},
                        el("td", { class: "num", text: new Date(e.at).toLocaleString() }),
                        el("td", {}, tag((EVENT[e.event] || [e.event])[0], (EVENT[e.event] || [])[1])),
                        el("td", { text: e.trigger || "" }),
                        el("td", { class: "mono", text: `${e.version}${e.commit ? ` ${e.commit}` : ""} (pid ${e.pid})` }),
                        el("td", { text: e.detail || "" }))), "compact"))
                : empty("No start recorded yet."))
    ];
}

async function loadDaemon() {
    try {
        const res = await fetch("/api/daemon", { cache: "no-store" });
        ui.daemon = res.ok ? await res.json() : { error: `HTTP ${res.status}` };
    } catch {
        ui.daemon = { error: "the daemon did not answer" };
    }
    if (route().view === "config") render(true);
}

function renderConfig(arg) {
    const tab = CONFIG_TABS.some(([k]) => k === arg) ? arg : "daemon";
    const reload = el("button", { type: "button", class: "btn", "data-fk": "config-reload", text: ui.configLoading ? "Loading…" : "Reload" });
    reload.addEventListener("click", () => loadConfig());
    const head = [
        el("h1", { text: "Configuration in effect." }),
        note("Read-only. Secret-looking values are masked with the rules of service_env; provider scripts are shown, their results never. Change the configuration with the MCP tools."),
        el("div", { class: "tabs-row" },
            el("nav", { class: "tabs", "aria-label": "Configuration views" }, CONFIG_TABS.map(([k, label]) =>
                el("a", { href: `#/config/${k}`, "aria-current": k === tab ? "page" : null, text: label }))),
            el("span", { class: "tabs-meta" }, reload,
                el("span", { class: ui.configError ? "stop-text" : "muted", text: ui.configError ? `Could not load: ${ui.configError}` : (ui.configLoadedAt ? `loaded ${timeSec(ui.configLoadedAt)}` : "") })))
    ];
    if (!ui.config) {
        if (!ui.configLoading && !ui.configError) loadConfig();
        return [...head, ui.configError ? empty("The daemon did not hand out its configuration. Reload to try again.") : empty("Loading the configuration…")];
    }
    return [...head, el("div", { class: "config-view" }, configViews[tab](ui.config))];
}

async function loadConfig() {
    ui.configLoading = true;
    ui.configError = null;
    loadDaemon();
    if (route().view === "config") render(true);
    try {
        const res = await fetch("/api/config", { cache: "no-store" });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        ui.config = await res.json();
        ui.configLoadedAt = new Date();
    } catch (e) {
        ui.configError = e.message || "the daemon did not answer";
    }
    ui.configLoading = false;
    if (route().view === "config") render(true);
}

// ---------- chrome ----------

const FAVICON_FILL = { stop: "C2352B", caution: "B26A00", clear: "17805F", off: "8A979B" };

function renderChrome(o, r) {
    for (const a of document.querySelectorAll(".nav a")) {
        if (a.dataset.view === r.view) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current");
    }
    if (!o) return;
    const rows = slotRows(o);
    const items = o.attention || [];
    const anyRunning = rows.some((x) => x.total > 0);
    const level = items.some((i) => i.level === "stop") ? "stop" : items.some((i) => i.level === "caution") ? "caution" : anyRunning ? "clear" : "off";
    const mark = $("nav-stack");
    mark.hidden = level === "off";
    mark.dataset.level = level;
    mark.title = level === "clear" ? "Everything that runs is healthy" : "Something needs attention";
    const active = o.builds.filter((b) => b.state === "running" || b.state === "queued").length;
    $("nav-builds").hidden = active === 0;
    $("nav-builds").textContent = String(active);
    $("favicon").setAttribute("href",
        `data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Ccircle cx='8' cy='8' r='6' fill='%23${FAVICON_FILL[level]}'/%3E%3C/svg%3E`);
}

function renderRefresh() {
    const node = $("refresh");
    node.className = `refresh${ui.stale ? " stale" : ""}`;
    node.textContent = ui.stale
        ? (ui.lastOk ? `The daemon has not answered since ${timeSec(ui.lastOk)}` : "The daemon does not answer")
        : (ui.lastOk ? `Updated ${timeSec(ui.lastOk)}` : "");
    document.body.classList.toggle("is-stale", ui.stale);
}

// Rebuilds the current view. Focus, the scroll position of outputs and the reader's selection survive it.
function render(force = false) {
    const view = $("view");
    const r = route();
    renderChrome(ui.overview, r);
    renderRefresh();
    const selection = document.getSelection();
    if (!force && selection && !selection.isCollapsed && view.contains(selection.anchorNode)) return;   // never rebuild under a text selection

    const active = document.activeElement;
    const focusKey = active && view.contains(active) ? (active.dataset.fk || (active.tagName === "A" ? `href:${active.getAttribute("href")}` : null)) : null;
    const caret = active && focusKey && active.tagName === "INPUT" && active.type === "search" ? [active.selectionStart, active.selectionEnd] : null;
    const scrolls = new Map([...view.querySelectorAll("pre[data-fk]")].map((p) => [p.dataset.fk, p.scrollTop]));
    const logNode = ui.log?.node.querySelector(".log-text");
    const logScroll = logNode ? logNode.scrollTop : 0;

    let content;
    if (r.view === "config") content = renderConfig(r.arg);
    else if (!ui.overview) content = [empty(ui.stale ? "The daemon does not answer. Is octo-devstack running?" : "Reading the stack…")];
    else if (r.view === "builds") content = renderBuilds(ui.overview, r.arg);
    else if (r.view === "lanes") content = renderLanes(ui.overview, r.arg);
    else if (r.view === "profiles") content = renderProfiles(ui.overview);
    else content = renderStack(ui.overview, r.arg);
    if (r.view !== "stack" && ui.overview) headline(ui.overview);   // keeps the tab title current on every view
    view.dataset.view = r.view;
    view.replaceChildren(...content.flat().filter(Boolean));
    ui.lastRender = Date.now();

    for (const p of view.querySelectorAll("pre[data-fk]")) if (scrolls.has(p.dataset.fk)) p.scrollTop = scrolls.get(p.dataset.fk);
    if (logNode && view.contains(logNode)) logNode.scrollTop = logScroll;
    if (focusKey) {
        const again = focusKey.startsWith("href:")
            ? [...view.querySelectorAll("a")].find((a) => a.getAttribute("href") === focusKey.slice(5))
            : [...view.querySelectorAll("[data-fk]")].find((n) => n.dataset.fk === focusKey);
        if (again) {
            again.focus({ preventScroll: true });
            if (caret && again.setSelectionRange) again.setSelectionRange(caret[0], caret[1]);
        }
    }
}

// ---------- loop ----------

async function refresh() {
    try {
        const res = await fetch("/api/overview", { cache: "no-store" });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const text = await res.text();
        const changed = text !== ui.overviewText;
        const wasStale = ui.stale;
        ui.overviewText = text;
        ui.overview = JSON.parse(text);
        ui.lastOk = new Date();
        ui.stale = false;
        const r = route();
        if (r.view === "config") { renderChrome(ui.overview, r); renderRefresh(); if (changed) loadDaemon(); }
        else if (changed || wasStale || Date.now() - ui.lastRender > 30000) render();   // uptimes move on without new data
        else renderRefresh();
        if (ui.log && r.view === "stack") loadLog();
        if (r.view === "builds" && r.arg) {
            const b = ui.overview.builds.find((x) => x.id === r.arg);
            if (b && (b.state === "running" || !ui.buildDetails.has(b.id))) loadBuild(b.id);
        }
    } catch {
        ui.stale = true;
        if (ui.overview) renderRefresh(); else render(true);
    }
}

let shownView = route().view;
window.addEventListener("hashchange", () => {
    const r = route();
    if (r.view !== "stack" || (ui.log && ui.log.slot !== (r.arg || "default"))) ui.log = null;
    render(true);
    if (r.view === "builds" && r.arg && ui.overview?.builds.some((b) => b.id === r.arg)) loadBuild(r.arg);
    if (r.view !== shownView) window.scrollTo({ top: 0 });
    shownView = r.view;
});

let timer = null;
function schedule() {
    clearInterval(timer);
    if (!document.hidden) timer = setInterval(refresh, REFRESH_MS);
}
document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh(); schedule(); });
render(true);
refresh();
schedule();
