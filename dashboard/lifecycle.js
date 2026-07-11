/**
 * Product lifecycle rules.
 *
 * Dates are the END OF EXTENDED SUPPORT published by Microsoft. A server is:
 *   - "eol"      when today is past the extended-support end date (red)
 *   - "nearing"  when the end date is within NEARING_MONTHS months (amber)
 *   - "supported" otherwise (green)
 *   - "unknown"  when the caption/version doesn't match a rule (grey)
 *
 * ESU (Extended Security Updates) purchases are deliberately ignored - an OS
 * on ESU is still one you should be migrating off. Update the tables here as
 * Microsoft publishes new dates; the collectors never need redeploying.
 */
"use strict";

const NEARING_MONTHS = 12;

/* Matched top-to-bottom against the WMI Win32_OperatingSystem.Caption -
   keep the more specific pattern (e.g. "2008 R2") above the general one. */
const WINDOWS_LIFECYCLE = [
  { match: /windows server.*2003/i,    product: "Windows Server 2003",    extendedEnd: "2015-07-14" },
  { match: /windows server.*2008 r2/i, product: "Windows Server 2008 R2", extendedEnd: "2020-01-14" },
  { match: /windows server.*2008/i,    product: "Windows Server 2008",    extendedEnd: "2020-01-14" },
  { match: /windows server.*2012 r2/i, product: "Windows Server 2012 R2", extendedEnd: "2023-10-10" },
  { match: /windows server.*2012/i,    product: "Windows Server 2012",    extendedEnd: "2023-10-10" },
  { match: /windows server.*2016/i,    product: "Windows Server 2016",    extendedEnd: "2027-01-12" },
  { match: /windows server.*2019/i,    product: "Windows Server 2019",    extendedEnd: "2029-01-09" },
  { match: /windows server.*2022/i,    product: "Windows Server 2022",    extendedEnd: "2031-10-14" },
  { match: /windows server.*2025/i,    product: "Windows Server 2025",    extendedEnd: "2034-10-10" },
];

/* SQL Server build number prefix -> product. Order matters: 10.5 before 10. */
const SQL_LIFECYCLE = [
  { prefix: "8.",    product: "SQL Server 2000",    extendedEnd: "2013-04-09" },
  { prefix: "9.",    product: "SQL Server 2005",    extendedEnd: "2016-04-12" },
  { prefix: "10.5",  product: "SQL Server 2008 R2", extendedEnd: "2019-07-09" },
  { prefix: "10.",   product: "SQL Server 2008",    extendedEnd: "2019-07-09" },
  { prefix: "11.",   product: "SQL Server 2012",    extendedEnd: "2022-07-12" },
  { prefix: "12.",   product: "SQL Server 2014",    extendedEnd: "2024-07-09" },
  { prefix: "13.",   product: "SQL Server 2016",    extendedEnd: "2026-07-14" },
  { prefix: "14.",   product: "SQL Server 2017",    extendedEnd: "2027-10-12" },
  { prefix: "15.",   product: "SQL Server 2019",    extendedEnd: "2030-01-08" },
  { prefix: "16.",   product: "SQL Server 2022",    extendedEnd: "2033-01-11" },
];

function classifyDate(extendedEnd) {
  const end = new Date(extendedEnd + "T00:00:00Z");
  const now = new Date();
  const nearingCutoff = new Date(end);
  nearingCutoff.setUTCMonth(nearingCutoff.getUTCMonth() - NEARING_MONTHS);
  if (now >= end) return "eol";
  if (now >= nearingCutoff) return "nearing";
  return "supported";
}

/** @returns {{status:string, product:string|null, extendedEnd:string|null}} */
function classifyWindows(osCaption) {
  if (!osCaption) return { status: "unknown", product: null, extendedEnd: null };
  for (const rule of WINDOWS_LIFECYCLE) {
    if (rule.match.test(osCaption)) {
      return { status: classifyDate(rule.extendedEnd), product: rule.product, extendedEnd: rule.extendedEnd };
    }
  }
  return { status: "unknown", product: null, extendedEnd: null };
}

/** @returns {{status:string, product:string|null, extendedEnd:string|null}} */
function classifySql(version) {
  if (!version) return { status: "unknown", product: null, extendedEnd: null };
  for (const rule of SQL_LIFECYCLE) {
    if (version.startsWith(rule.prefix)) {
      return { status: classifyDate(rule.extendedEnd), product: rule.product, extendedEnd: rule.extendedEnd };
    }
  }
  return { status: "unknown", product: null, extendedEnd: null };
}

/** Worst status wins across a server's SQL instances. */
function classifySqlServer(server) {
  if (!server.sql || !server.sql.installed || !server.sql.instances?.length) return null;
  const rank = { eol: 0, nearing: 1, unknown: 2, supported: 3 };
  let worst = null;
  for (const instance of server.sql.instances) {
    const result = classifySql(instance.baseVersion || instance.version);
    instance._lifecycle = result;
    if (!worst || rank[result.status] < rank[worst.status]) worst = result;
  }
  return worst;
}
