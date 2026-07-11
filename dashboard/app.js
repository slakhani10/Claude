/**
 * Azure Server Inventory dashboard.
 *
 * Fetches the aggregated feed from the GetInventory function (or the bundled
 * demo snapshot when no apiUrl is configured), classifies every server's OS
 * and SQL Server against the lifecycle tables, and renders stat tiles, a
 * per-region breakdown, and a filterable/sortable table. Polls the API on an
 * interval so the view tracks the collectors in near-real time.
 */
"use strict";

const CONFIG = window.INVENTORY_CONFIG || {};
const REFRESH_SECONDS = CONFIG.refreshSeconds || 60;

const STATUS_META = {
  eol:       { label: "End of life",  icon: "✖" },
  nearing:   { label: "Nearing EOL",  icon: "▲" },
  supported: { label: "Supported",    icon: "●" },
  unknown:   { label: "Unknown",      icon: "?" },
};

const state = {
  data: null,          // raw feed
  rows: [],            // enriched server rows
  sortKey: "osStatus",
  sortDir: 1,
  statusTile: "",      // tile-driven OS status filter
  countdown: REFRESH_SECONDS,
};

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g,
  (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

/* ------------------------------------------------------------------ data */

async function loadData() {
  if (!CONFIG.apiUrl) {
    $("demoBadge").hidden = false;
    return window.SAMPLE_INVENTORY;
  }
  const response = await fetch(CONFIG.apiUrl, { cache: "no-store" });
  if (!response.ok) throw new Error(`API returned ${response.status}`);
  return response.json();
}

function enrich(data) {
  const statusRank = { eol: 0, nearing: 1, unknown: 2, supported: 3 };
  return (data.servers || []).map((server) => {
    const os = server.collectionError && !server.osCaption
      ? { status: "unknown", product: null, extendedEnd: null }
      : classifyWindows(server.osCaption);
    const sql = classifySqlServer(server);
    return {
      ...server,
      osLifecycle: os,
      osStatus: os.status,
      osRank: statusRank[os.status],
      sqlLifecycle: sql,
      sqlStatus: sql ? sql.status : "",
      sqlRank: sql ? statusRank[sql.status] : 99,
      sqlSummary: sql
        ? server.sql.instances.map((i) => `${i._lifecycle.product || "SQL"} ${i.edition || ""}`).join("; ")
        : "",
    };
  });
}

async function refresh() {
  try {
    state.data = await loadData();
    state.rows = enrich(state.data);
    $("generatedAt").textContent =
      "Updated " + new Date(state.data.generatedAt).toLocaleString();
    render();
  } catch (err) {
    $("generatedAt").textContent = "Load failed: " + err.message;
  }
  state.countdown = REFRESH_SECONDS;
}

/* --------------------------------------------------------------- filters */

function visibleRows() {
  const query = $("search").value.trim().toLowerCase();
  const region = $("regionFilter").value;
  const osStatus = state.statusTile || $("osFilter").value;
  const sqlChoice = $("sqlFilter").value;

  let rows = state.rows.filter((row) => {
    if (region && row.region !== region) return false;
    if (osStatus && row.osStatus !== osStatus) return false;
    if (sqlChoice === "any" && !row.sqlLifecycle) return false;
    if (sqlChoice === "none" && row.sqlLifecycle) return false;
    if (["eol", "nearing", "supported"].includes(sqlChoice) && row.sqlStatus !== sqlChoice) return false;
    if (query) {
      const haystack = [row.name, row.region, row.resourceGroup, row.osCaption,
        row.ipAddress, row.domain, row.sqlSummary].join(" ").toLowerCase();
      if (!haystack.includes(query)) return false;
    }
    return true;
  });

  const key = state.sortKey;
  rows.sort((a, b) => {
    let va = key === "osStatus" ? a.osRank : key === "sqlStatus" ? a.sqlRank : a[key];
    let vb = key === "osStatus" ? b.osRank : key === "sqlStatus" ? b.sqlRank : b[key];
    if (va == null) return 1;
    if (vb == null) return -1;
    if (typeof va === "string") { va = va.toLowerCase(); vb = String(vb).toLowerCase(); }
    return (va < vb ? -1 : va > vb ? 1 : 0) * state.sortDir;
  });
  return rows;
}

/* -------------------------------------------------------------- rendering */

function pill(status, extendedEnd) {
  const meta = STATUS_META[status] || STATUS_META.unknown;
  const until = extendedEnd
    ? ` <span class="until">· ${status === "eol" ? "ended" : "until"} ${extendedEnd}</span>` : "";
  return `<span class="pill ${status}"><span class="icon" aria-hidden="true">${meta.icon}</span>${meta.label}${until}</span>`;
}

function renderTiles() {
  const counts = { total: state.rows.length, eol: 0, nearing: 0, supported: 0, unknown: 0,
    sql: 0, sqlEol: 0 };
  for (const row of state.rows) {
    counts[row.osStatus] = (counts[row.osStatus] || 0) + 1;
    if (row.sqlLifecycle) {
      counts.sql += 1;
      if (row.sqlStatus === "eol") counts.sqlEol += 1;
    }
  }
  const tiles = [
    { key: "",          label: "Total servers",  value: counts.total },
    { key: "eol",       label: "End of life",    value: counts.eol,       dot: "eol" },
    { key: "nearing",   label: "Nearing EOL",    value: counts.nearing,   dot: "nearing" },
    { key: "supported", label: "Supported",      value: counts.supported, dot: "supported" },
    { key: "unknown",   label: "Unknown",        value: counts.unknown,   dot: "unknown" },
    { key: "__sql",     label: "SQL Server hosts", value: counts.sql, sub: `${counts.sqlEol} EOL` },
  ];
  $("tiles").innerHTML = tiles.map((tile) => `
    <button class="tile ${state.statusTile === tile.key && tile.key ? "active" : ""}" data-key="${tile.key}">
      <span class="label">${tile.dot ? `<span class="dot ${tile.dot}"></span>` : ""}${tile.label}</span>
      <span class="value">${tile.value}${tile.sub ? ` <span class="sub">${tile.sub}</span>` : ""}</span>
    </button>`).join("");

  for (const button of $("tiles").querySelectorAll(".tile")) {
    button.addEventListener("click", () => {
      const key = button.dataset.key;
      if (key === "__sql") { $("sqlFilter").value = "any"; state.statusTile = ""; }
      else state.statusTile = state.statusTile === key ? "" : key;
      render();
    });
  }
}

function renderRegionBars() {
  const byRegion = new Map();
  for (const row of state.rows) {
    if (!byRegion.has(row.region)) byRegion.set(row.region, { eol: 0, nearing: 0, supported: 0, unknown: 0 });
    byRegion.get(row.region)[row.osStatus] += 1;
  }
  const freshness = new Map((state.data.regions || []).map((r) => [r.region, r.collectedAt]));

  $("regionBars").innerHTML = [...byRegion.entries()].map(([region, counts]) => {
    const total = counts.eol + counts.nearing + counts.supported + counts.unknown;
    const segments = ["eol", "nearing", "supported", "unknown"]
      .filter((status) => counts[status] > 0)
      .map((status) => `<div class="seg ${status}" style="flex:${counts[status]}"
             title="${region}: ${counts[status]} ${STATUS_META[status].label}"></div>`)
      .join("");
    const collected = freshness.get(region);
    const age = collected ? Math.max(0, Math.round((Date.now() - new Date(collected)) / 60000)) + "m ago" : "";
    return `<div class="region-row">
      <span class="region-name" title="${esc(region)}">${esc(region)}</span>
      <div class="bar" role="img" aria-label="${esc(region)}: ${total} servers">${segments}</div>
      <span class="region-age">${age}</span>
    </div>`;
  }).join("");
}

function renderTable() {
  const rows = visibleRows();
  $("empty").hidden = rows.length > 0;

  $("rows").innerHTML = rows.map((row) => {
    const sqlCell = row.sqlLifecycle
      ? row.sql.instances.map((instance) => `
          <div class="sql-instance">
            <div>${esc(instance._lifecycle.product || "SQL Server")} <span class="sub">${esc(instance.edition || "")}</span></div>
            <div class="sub">${esc(instance.instance)} · ${esc(instance.version || "")}${instance.serviceState === "Stopped" ? " · stopped" : ""}</div>
          </div>`).join("")
      : `<span class="sub">—</span>`;

    return `<tr>
      <td>
        <div class="server-name">${esc(row.name)}</div>
        <div class="sub">${esc(row.resourceGroup || "")}${row.ipAddress ? " · " + esc(row.ipAddress) : ""}</div>
        ${row.collectionError ? `<div class="error-note" title="${esc(row.collectionError)}">⚠ collection failed</div>` : ""}
      </td>
      <td>${esc(row.region)}</td>
      <td>
        <div>${esc(row.osCaption || "—")}</div>
        ${row.osBuild ? `<div class="sub">build ${esc(row.osBuild)}</div>` : ""}
      </td>
      <td>${pill(row.osStatus, row.osLifecycle.extendedEnd)}</td>
      <td class="num">${row.cores ?? "—"}</td>
      <td>${sqlCell}</td>
      <td>${row.sqlLifecycle ? pill(row.sqlStatus, row.sqlLifecycle.extendedEnd) : `<span class="sub">—</span>`}</td>
    </tr>`;
  }).join("");
}

function render() {
  renderTiles();
  renderRegionBars();
  renderTable();

  const regionSelect = $("regionFilter");
  const current = regionSelect.value;
  const regions = [...new Set(state.rows.map((r) => r.region))].sort();
  regionSelect.innerHTML = `<option value="">All regions</option>` +
    regions.map((r) => `<option value="${esc(r)}" ${r === current ? "selected" : ""}>${esc(r)}</option>`).join("");

  for (const th of $("headerRow").querySelectorAll("th")) {
    const arrow = th.dataset.sort === state.sortKey ? (state.sortDir === 1 ? " ▲" : " ▼") : "";
    th.innerHTML = th.textContent.replace(/ [▲▼]$/, "") + `<span class="arrow">${arrow}</span>`;
  }

  const stale = (state.data.regions || []).filter((r) =>
    Date.now() - new Date(r.collectedAt) > 60 * 60000);
  $("regionFreshness").textContent = stale.length
    ? `⚠ Stale regions (no snapshot in 60 min): ${stale.map((r) => r.region).join(", ")}` : "";
}

/* ---------------------------------------------------------------- export */

function exportCsv() {
  const header = ["Server", "Region", "ResourceGroup", "IPAddress", "OSCaption", "OSStatus",
    "OSSupportEnds", "Cores", "LogicalProcessors", "MemoryGB", "SQLInstalled", "SQLDetails",
    "SQLStatus", "SQLSupportEnds", "CollectionError"];
  const lines = [header.join(",")];
  for (const row of visibleRows()) {
    const sqlDetails = row.sqlLifecycle
      ? row.sql.instances.map((i) => `${i.instance}: ${i._lifecycle.product || ""} ${i.edition || ""} ${i.version || ""}`).join(" | ")
      : "";
    const cells = [row.name, row.region, row.resourceGroup, row.ipAddress, row.osCaption,
      STATUS_META[row.osStatus].label, row.osLifecycle.extendedEnd, row.cores,
      row.logicalProcessors, row.memoryGB, row.sqlLifecycle ? "Yes" : "No", sqlDetails,
      row.sqlLifecycle ? STATUS_META[row.sqlStatus].label : "", row.sqlLifecycle?.extendedEnd,
      row.collectionError];
    lines.push(cells.map((cell) => `"${String(cell ?? "").replace(/"/g, '""')}"`).join(","));
  }
  const blob = new Blob([lines.join("\r\n")], { type: "text/csv" });
  const link = document.createElement("a");
  link.href = URL.createObjectURL(blob);
  link.download = `server-inventory-${new Date().toISOString().slice(0, 10)}.csv`;
  link.click();
  URL.revokeObjectURL(link.href);
}

/* ------------------------------------------------------------------ init */

function init() {
  $("nearingMonths").textContent = NEARING_MONTHS;
  for (const id of ["search", "regionFilter", "osFilter", "sqlFilter"]) {
    $(id).addEventListener("input", () => { if (id === "osFilter") state.statusTile = ""; render(); });
  }
  for (const th of $("headerRow").querySelectorAll("th")) {
    th.addEventListener("click", () => {
      const key = th.dataset.sort;
      if (state.sortKey === key) state.sortDir *= -1;
      else { state.sortKey = key; state.sortDir = 1; }
      render();
    });
  }
  $("refreshBtn").addEventListener("click", refresh);
  $("exportBtn").addEventListener("click", exportCsv);

  setInterval(() => {
    if (!CONFIG.apiUrl) return;             // demo data never changes
    state.countdown -= 1;
    if (state.countdown <= 0) refresh();
    else $("countdown").textContent = `auto-refresh in ${state.countdown}s`;
  }, 1000);

  refresh();
}

init();
