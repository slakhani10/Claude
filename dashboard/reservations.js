/**
 * Reservations view: monthly cost and projected savings per Azure reservation.
 *
 * Fed by the GetReservationSavings function, which already does the costing
 * (Cost Management / billing plan / retail list price) and the pay-as-you-go
 * comparison server-side. This file only renders and filters.
 *
 * That endpoint caches for hours - reservation costs move at most daily - so
 * this view loads lazily on first tab activation and refreshes only when asked,
 * unlike the servers view's 60-second poll.
 */
"use strict";

const RES_API_URL = (window.INVENTORY_CONFIG || {}).reservationsApiUrl || "";

/* Health = are you actually realizing the saving this reservation projects?
   Status colors, so each ships with an icon and a label - never color alone. */
const RES_HEALTH = {
  good:    { label: "Fully used",           short: "Fully used",  icon: "●" },
  nearing: { label: "Under-used",           short: "Under-used",  icon: "▲" },
  eol:     { label: "Losing money",         short: "Losing money", icon: "✖" },
  unknown: { label: "Utilization unknown",  short: "Unknown",     icon: "?" },
};

const resState = {
  data: null,
  rows: [],
  sortKey: "monthlySaving",
  sortDir: -1,
  loaded: false,
};

/* ------------------------------------------------------------- formatting */

function resMoney(value, { compact = false } = {}) {
  if (value == null) return "—";
  const currency = resState.data?.currency || "USD";
  try {
    return new Intl.NumberFormat(undefined, {
      style: "currency",
      currency,
      notation: compact ? "compact" : "standard",
      maximumFractionDigits: compact ? 1 : 0,
    }).format(value);
  } catch {
    // Unknown currency code - show the number and the code rather than nothing.
    return `${Math.round(value).toLocaleString()} ${currency}`;
  }
}

const resPercent = (value, digits = 0) =>
  value == null ? "—" : `${value.toFixed(digits)}%`;

/* ------------------------------------------------------------------- data */

async function loadReservations() {
  if (!RES_API_URL) {
    $("demoBadge").hidden = false;
    return window.SAMPLE_RESERVATIONS;
  }
  const response = await fetch(RES_API_URL, { cache: "no-store" });
  if (!response.ok) throw new Error(`API returned ${response.status}`);
  return response.json();
}

/**
 * Health compares realized saving against projected saving. Utilization is the
 * only thing that separates the two, so this is really "is the capacity being
 * used" - expressed in money, which is what a renewal decision turns on.
 */
function resHealth(row) {
  if (row.utilizationPercent == null) return "unknown";
  // "Losing money" needs the saving to be priced; without it we can still say
  // whether the capacity is being used, which is the rest of the signal.
  if (row.realizedMonthlySaving != null && row.realizedMonthlySaving < 0) return "eol";
  if (row.utilizationPercent < 90) return "nearing";
  return "good";
}

function enrichReservations(data) {
  return (data.reservations || []).map((row) => ({
    ...row,
    health: resHealth(row),
    // Sorting a table by "expires soonest" should not put never-expiring rows first.
    monthsRemainingSort: row.monthsRemaining ?? Number.POSITIVE_INFINITY,
  }));
}

async function refreshReservations({ force = false } = {}) {
  $("resGeneratedAt").textContent = "Loading reservations…";
  try {
    const url = force && RES_API_URL
      ? RES_API_URL + (RES_API_URL.includes("?") ? "&" : "?") + "refresh=true"
      : null;
    resState.data = url
      ? await (async () => {
          const response = await fetch(url, { cache: "no-store" });
          if (!response.ok) throw new Error(`API returned ${response.status}`);
          return response.json();
        })()
      : await loadReservations();
    resState.rows = enrichReservations(resState.data);
    resState.loaded = true;
    $("resGeneratedAt").textContent =
      "Updated " + new Date(resState.data.generatedAt).toLocaleString();
    renderReservations();
  } catch (err) {
    $("resGeneratedAt").textContent = "Load failed: " + err.message;
  }
}

/* ---------------------------------------------------------------- filters */

function resVisibleRows() {
  const query = $("resSearch").value.trim().toLowerCase();
  const region = $("resRegionFilter").value;
  const type = $("resTypeFilter").value;
  const health = $("resHealthFilter").value;

  const rows = resState.rows.filter((row) => {
    if (region && row.region !== region) return false;
    if (type && row.resourceType !== type) return false;
    if (health === "expiring") {
      if (row.monthsRemaining == null || row.monthsRemaining > 3) return false;
    } else if (health && row.health !== health) return false;
    if (query) {
      const haystack = [row.name, row.sku, row.region, row.resourceType, row.term,
        row.reservationOrderId, row.reservationId, row.costSource, row.notes]
        .join(" ").toLowerCase();
      if (!haystack.includes(query)) return false;
    }
    return true;
  });

  const key = resState.sortKey;
  rows.sort((a, b) => {
    let va = key === "monthsRemaining" ? a.monthsRemainingSort : a[key];
    let vb = key === "monthsRemaining" ? b.monthsRemainingSort : b[key];
    if (va == null) return 1;          // unknowns sink, whichever direction
    if (vb == null) return -1;
    if (typeof va === "string") { va = va.toLowerCase(); vb = String(vb).toLowerCase(); }
    return (va < vb ? -1 : va > vb ? 1 : 0) * resState.sortDir;
  });
  return rows;
}

/* -------------------------------------------------------------- rendering */

function renderResTiles() {
  const totals = resState.data?.totals || {};
  // Decide the notation once for the whole row: mixing "$9,228" and "$13.2K"
  // across tiles of the same measure reads as two different scales.
  const compact = Math.max(...[totals.monthlyCost, totals.payGoMonthlyCost, totals.monthlySaving,
    totals.annualSaving, totals.realizedMonthlySaving].map((v) => Math.abs(v ?? 0))) >= 100000;
  const tiles = [
    { label: "Reservation cost / month", value: resMoney(totals.monthlyCost, { compact }) },
    { label: "Pay-as-you-go equivalent", value: resMoney(totals.payGoMonthlyCost, { compact }) },
    { label: "Saving / month", value: resMoney(totals.monthlySaving, { compact }),
      sub: totals.savingPercent != null ? `${resPercent(totals.savingPercent, 1)} off` : "" },
    { label: "Saving / year", value: resMoney(totals.annualSaving, { compact }) },
    { label: "Realized / month", value: resMoney(totals.realizedMonthlySaving, { compact }),
      sub: "at current utilization" },
    { label: "Under-used", value: totals.underutilizedCount ?? "—",
      dot: totals.underutilizedCount ? "nearing" : null, sub: "below 90%" },
  ];

  // Not buttons: unlike the server tiles these do not drive a filter, and a
  // clickable-looking tile that does nothing is worse than a plain one.
  $("resTiles").innerHTML = tiles.map((tile) => `
    <div class="tile static">
      <span class="label">${tile.dot ? `<span class="dot ${tile.dot}"></span>` : ""}${esc(tile.label)}</span>
      <span class="value money">${esc(tile.value)}</span>
      ${tile.sub ? `<span class="tile-sub">${esc(tile.sub)}</span>` : ""}
    </div>`).join("");
}

/**
 * One meter per reservation. Track length is pay-as-you-go spend (scaled to the
 * largest, so rows compare), the fill is the saving as a share of it, and the
 * fill color is realization health.
 */
function renderResBars() {
  const rows = resVisibleRows()
    .filter((row) => row.payGoMonthlyCost > 0)
    .sort((a, b) => (b.monthlySaving ?? -Infinity) - (a.monthlySaving ?? -Infinity));

  if (rows.length === 0) {
    $("resBars").innerHTML = `<div class="sub">No reservations with a comparable pay-as-you-go rate.</div>`;
    return;
  }

  const maxPayGo = Math.max(...rows.map((row) => row.payGoMonthlyCost));
  const omitted = resVisibleRows().length - rows.length;

  const omissionNote = omitted > 0
    ? `<div class="sub omission">${omitted} reservation${omitted === 1 ? " is" : "s are"} not
       shown here: no public pay-as-you-go meter matched, so there is nothing to compare
       against. ${omitted === 1 ? "It appears" : "They appear"} in the table below.</div>`
    : "";

  $("resBars").innerHTML = rows.map((row) => {
    const trackPercent = (row.payGoMonthlyCost / maxPayGo) * 100;
    const savingShare = row.monthlySaving > 0
      ? Math.min(100, (row.monthlySaving / row.payGoMonthlyCost) * 100) : 0;
    const meta = RES_HEALTH[row.health];
    const label = `${row.name}: pay-as-you-go ${resMoney(row.payGoMonthlyCost)} per month, ` +
      `reservation ${resMoney(row.monthlyCost)}, saving ${resMoney(row.monthlySaving)} ` +
      `(${resPercent(row.savingPercent, 1)}). ${meta.label}` +
      (row.utilizationPercent != null ? ` at ${resPercent(row.utilizationPercent)} utilization` : "") + ".";

    return `<div class="res-row">
      <span class="res-name" title="${esc(row.name)}">${esc(row.name)}</span>
      <div class="meter" role="img" aria-label="${esc(label)}" title="${esc(label)}">
        <div class="meter-track" style="width:${trackPercent.toFixed(2)}%">
          <div class="meter-fill ${row.health}" style="width:${savingShare.toFixed(2)}%"></div>
        </div>
      </div>
      <span class="res-figure">${esc(resMoney(row.monthlySaving))}</span>
    </div>`;
  }).join("") + omissionNote;
}

function renderResTable() {
  const rows = resVisibleRows();
  $("resEmpty").hidden = rows.length > 0;

  $("resRows").innerHTML = rows.map((row) => {
    const meta = RES_HEALTH[row.health];
    const utilization = row.utilizationPercent == null
      ? `<span class="sub">—</span>`
      : `<div class="util">
           <div class="meter small">
             <div class="meter-track" style="width:100%">
               <div class="meter-fill ${row.health}" style="width:${Math.min(100, row.utilizationPercent).toFixed(1)}%"></div>
             </div>
           </div>
           <span class="util-value">${esc(resPercent(row.utilizationPercent))}</span>
         </div>
         <div class="sub"><span class="health-icon ${row.health}">${meta.icon}</span> ${esc(meta.short)}</div>`;

    const savingClass = row.monthlySaving == null ? "" : row.monthlySaving < 0 ? "negative" : "positive";

    return `<tr>
      <td>
        <div class="server-name">${esc(row.name || row.reservationId)}</div>
        <div class="sub">${esc(row.sku || "")}${row.resourceType ? " · " + esc(row.resourceType) : ""}</div>
        ${row.notes ? `<div class="note-flag" title="${esc(row.notes)}">${esc(row.notes)}</div>` : ""}
      </td>
      <td>${esc(row.region || "—")}<div class="sub">${esc(row.scope || "")}</div></td>
      <td class="num">${row.quantity ?? "—"}</td>
      <td>
        ${esc(row.term || "—")}
        <div class="sub">${esc(row.billingPlan || "")}${row.autoRenew ? " · renews" : ""}</div>
      </td>
      <td class="num">${esc(resMoney(row.monthlyCost))}</td>
      <td class="num">${esc(resMoney(row.payGoMonthlyCost))}</td>
      <td class="num ${savingClass}">
        ${esc(resMoney(row.monthlySaving))}
        <div class="sub">${row.savingPercent == null ? "" : esc(resPercent(row.savingPercent, 1)) + " off"}</div>
      </td>
      <td>${utilization}</td>
      <td class="num">${row.monthsRemaining ?? "—"}</td>
      <td><span class="source-tag">${esc(row.costSource || "none")}</span></td>
    </tr>`;
  }).join("");
}

function renderResWarnings() {
  const warnings = resState.data?.warnings || [];
  $("resWarnings").innerHTML = warnings.length
    ? warnings.map((warning) => `<div class="banner">⚠ ${esc(warning)}</div>`).join("")
    : "";
}

function renderReservations() {
  renderResWarnings();
  renderResTiles();
  renderResBars();
  renderResTable();

  for (const [id, key] of [["resRegionFilter", "region"], ["resTypeFilter", "resourceType"]]) {
    const select = $(id);
    const current = select.value;
    const placeholder = select.querySelector('option[value=""]').textContent;
    const values = [...new Set(resState.rows.map((row) => row[key]).filter(Boolean))].sort();
    select.innerHTML = `<option value="">${esc(placeholder)}</option>` +
      values.map((value) =>
        `<option value="${esc(value)}" ${value === current ? "selected" : ""}>${esc(value)}</option>`).join("");
  }

  for (const th of $("resHeaderRow").querySelectorAll("th")) {
    const arrow = th.dataset.sort === resState.sortKey ? (resState.sortDir === 1 ? " ▲" : " ▼") : "";
    th.innerHTML = th.textContent.replace(/ [▲▼]$/, "") + `<span class="arrow">${arrow}</span>`;
  }

  const month = resState.data?.costMonth;
  $("resCostMonth").textContent = month ? `Costs billed for ${month}.` : "";
}

/* ---------------------------------------------------------------- export */

function exportReservationsCsv() {
  const header = ["Name", "ResourceType", "Sku", "Region", "Quantity", "Term", "BillingPlan",
    "Scope", "InstanceFlexibility", "AutoRenew", "EffectiveDate", "ExpiryDate", "MonthsRemaining",
    "Currency", "MonthlyCost", "PayGoHourlyRate", "PayGoMonthlyCost", "MonthlySaving",
    "SavingPercent", "AnnualSaving", "RemainingTermSaving", "UtilizationPercent",
    "RealizedMonthlySaving", "Health", "CostSource", "ReservationOrderId", "ReservationId", "Notes"];
  const currency = resState.data?.currency || "USD";
  const lines = [header.join(",")];

  for (const row of resVisibleRows()) {
    const cells = [row.name, row.resourceType, row.sku, row.region, row.quantity, row.term,
      row.billingPlan, row.scope, row.instanceFlexibility, row.autoRenew, row.effectiveDate,
      row.expiryDate, row.monthsRemaining, currency, row.monthlyCost, row.payGoHourlyRate,
      row.payGoMonthlyCost, row.monthlySaving, row.savingPercent, row.annualSaving,
      row.remainingTermSaving, row.utilizationPercent, row.realizedMonthlySaving,
      RES_HEALTH[row.health].label, row.costSource, row.reservationOrderId, row.reservationId,
      row.notes];
    lines.push(cells.map((cell) => `"${String(cell ?? "").replace(/"/g, '""')}"`).join(","));
  }

  const blob = new Blob([lines.join("\r\n")], { type: "text/csv" });
  const link = document.createElement("a");
  link.href = URL.createObjectURL(blob);
  link.download = `reservation-savings-${new Date().toISOString().slice(0, 10)}.csv`;
  link.click();
  URL.revokeObjectURL(link.href);
}

/* ------------------------------------------------------------------ tabs */

function activateTab(name) {
  for (const button of document.querySelectorAll(".tab-btn")) {
    const active = button.dataset.tab === name;
    button.classList.toggle("active", active);
    button.setAttribute("aria-selected", String(active));
    $(`tab-${button.dataset.tab}`).hidden = !active;
  }
  // The header toolbar and timestamp belong to the servers feed; the
  // reservations tab carries its own, because the two refresh on different
  // cadences and showing both at once reads as duplicated chrome.
  $("serversToolbar").hidden = name !== "servers";
  $("generatedAt").hidden = name !== "servers";

  if (name === "reservations" && !resState.loaded) refreshReservations();
}

function initReservations() {
  for (const button of document.querySelectorAll(".tab-btn")) {
    button.addEventListener("click", () => activateTab(button.dataset.tab));
  }
  for (const id of ["resSearch", "resRegionFilter", "resTypeFilter", "resHealthFilter"]) {
    $(id).addEventListener("input", renderReservations);
  }
  for (const th of $("resHeaderRow").querySelectorAll("th")) {
    th.addEventListener("click", () => {
      const key = th.dataset.sort;
      if (resState.sortKey === key) resState.sortDir *= -1;
      // Money and percentages are most useful biggest-first on the first click.
      else { resState.sortKey = key; resState.sortDir = th.classList.contains("num") ? -1 : 1; }
      renderReservations();
    });
  }
  $("resRefreshBtn").addEventListener("click", () => refreshReservations({ force: true }));
  $("resExportBtn").addEventListener("click", exportReservationsCsv);
}

initReservations();
