/**
 * stats.sh against a local stand-in for the Analytics Engine SQL API. The
 * script's STATS_API_URL seam points it here; each test picks the responder,
 * and the server records every statement and the Authorization header so the
 * probe exclusion and the token path are checked on the wire, not by reading
 * the script.
 */

import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { fileURLToPath } from "node:url";

const SCRIPT = fileURLToPath(new URL("../stats.sh", import.meta.url));
const TOKEN = "test-token";
const PROBE_EXCLUSION = "index1 != '00000000-0000-0000-0000-000000000000'";

const DAY = 86400;
const WEEK = 604800;
const epoch = (iso) => Date.parse(`${iso}T00:00:00Z`) / 1000;
const dayOf = (iso) => epoch(iso) / DAY;
const weekOf = (iso) => epoch(iso) / WEEK;

// 2026-08-20 is a Thursday, so it opens a week on the script's epoch grid and
// its label is the date itself; the next Thursday is 2026-08-27.
const W0 = weekOf("2026-08-20");
const W1 = weekOf("2026-08-27");

// The script's clock is pinned so the fixture dates stay inside its 90-day
// window; 2026-09-02 puts the window's first full week at 2026-06-04.
const NOW = String(epoch("2026-09-02"));

const A = "aaaaaaaa-0000-4000-8000-000000000001";
const B = "bbbbbbbb-0000-4000-8000-000000000002";
const C = "cccccccc-0000-4000-8000-000000000003";
const D = "dddddddd-0000-4000-8000-000000000004";
const E = "eeeeeeee-0000-4000-8000-000000000005";
const F = "ffffffff-0000-4000-8000-000000000006";
const G = "gggggggg-0000-4000-8000-000000000007";

const rows = (data) => ({ status: 200, body: { data } });
const error = (status, message) => ({ status, body: { errors: [{ message }] } });

/**
 * Fixture rows for a full report. Counts arrive as numbers or strings, since
 * the SQL API is not consistent about it and the script must not care.
 *
 * @param {string} sql
 */
function fullReport(sql) {
  if (sql.includes("max(_sample_interval)")) return rows([{ max_interval: 1 }]);
  if (sql.includes("AS downloads")) {
    return rows([
      { day: dayOf("2026-08-20"), downloads: 3 },
      { day: String(dayOf("2026-08-21")), downloads: "1" },
    ]);
  }
  if (sql.includes("AS installs") && sql.includes("AS day")) {
    return rows([{ day: dayOf("2026-08-20"), installs: 2 }]);
  }
  if (sql.includes("AS installs") && sql.includes("AS week")) {
    return rows([
      { week: W0, installs: 2 },
      { week: W1, installs: 2 },
    ]);
  }
  if (sql.includes("AS jail")) {
    return rows([
      { jail: 0, pings: 2 },
      { jail: 1, pings: 1 },
    ]);
  }
  if (sql.includes("min(blob2) AS created")) {
    return rows([
      { install: A, created: "2026-08-20" },
      { install: B, created: "2026-08-20" },
      { install: C, created: "2026-08-27" },
      // No usable created date: not in any cohort.
      { install: E, created: null },
      // Only ever active before its own install date: a skewed clock.
      { install: F, created: "2026-08-27" },
    ]);
  }
  if (sql.includes("GROUP BY install, week")) {
    return rows([
      { install: A, week: W0 },
      { install: A, week: W1 },
      { install: B, week: W0 },
      { install: C, week: String(W1) },
      // Active but never in the cohort query: dropped, not a crash.
      { install: D, week: W0 },
      { install: F, week: W0 },
    ]);
  }
  throw new Error(`unexpected query: ${sql}`);
}

const FULL_REPORT = `
Downloads per day (last 90 days)
  2026-08-20  3
  2026-08-21  1

Daily active installs (last 90 days)
  2026-08-20  2

Weekly active installs (last 90 days, weeks start Thursday)
  2026-08-20  2
  2026-08-27  2

Cursor lock share (last 7 days, weighted by heartbeat)
  1 of 3 heartbeats with the cursor lock on (33%)

Weekly cohort retention (cohorts of the last 90 days, share still active)
  cohort      size    w0    w1
  2026-08-20     2  100%   50%
  2026-08-27     2   50%     -

`;

const server = createServer((request, response) => {
  let sql = "";
  request.on("data", (chunk) => {
    sql += chunk;
  });
  request.on("end", () => {
    server.requests.push({ sql, authorization: request.headers.authorization });
    const { status, body } = server.respond(sql);
    response.writeHead(status, { "Content-Type": "application/json" });
    response.end(JSON.stringify(body));
  });
});
server.requests = [];
server.respond = fullReport;
let apiUrl = "";

beforeAll(async () => {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  apiUrl = `http://127.0.0.1:${server.address().port}/sql`;
});

afterAll(() => server.close());

afterEach(() => {
  server.requests = [];
  server.respond = fullReport;
});

/**
 * Runs the script and resolves with its exit code and both output streams.
 *
 * @param {string[]} args
 * @param {Record<string, string | undefined>} env
 */
function run(args = [], env = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn("bash", [SCRIPT, ...args], {
      env: {
        ...process.env,
        CLOUDFLARE_API_TOKEN: TOKEN,
        STATS_API_URL: apiUrl,
        STATS_NOW: NOW,
        ...env,
      },
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

describe("stats.sh", () => {
  it("prints the full report from fixture rows", async () => {
    const result = await run();

    expect(result.stderr).toBe("");
    expect(result.code).toBe(0);
    expect(result.stdout).toBe(FULL_REPORT);
  });

  it("drops cohorts older than the window instead of widening the table", async () => {
    // G was installed two years ago and is still pinging. Its heartbeats are
    // inside the window, so the SQL returns it, but its cohort is not.
    server.respond = (sql) => {
      const { status, body } = fullReport(sql);
      if (sql.includes("min(blob2) AS created")) {
        body.data.push({ install: G, created: "2024-09-05" });
      }
      if (sql.includes("GROUP BY install, week")) {
        body.data.push({ install: G, week: W1 });
      }
      return { status, body };
    };

    const result = await run();

    expect(result.code).toBe(0);
    expect(result.stdout).toBe(FULL_REPORT);
  });

  it("keeps a cohort that starts on the window's first full week", async () => {
    // 2026-06-04 is the first Thursday inside the 90-day window that ends on
    // NOW; the week before it is partly outside and must not appear.
    const W_EDGE = weekOf("2026-06-04");
    server.respond = (sql) => {
      const { status, body } = fullReport(sql);
      if (sql.includes("min(blob2) AS created")) {
        body.data.push({ install: G, created: "2026-06-04" });
        body.data.push({ install: D, created: "2026-06-03" });
      }
      if (sql.includes("GROUP BY install, week")) {
        body.data.push({ install: G, week: W_EDGE });
      }
      return { status, body };
    };

    const result = await run();

    expect(result.code).toBe(0);
    expect(result.stdout).toContain("  2026-06-04     1  100%     -\n");
    expect(result.stdout).not.toContain("2026-05-28");
  });

  it("sends the token as a bearer header on every request", async () => {
    await run();

    expect(server.requests).toHaveLength(8);
    for (const { authorization } of server.requests) {
      expect(authorization).toBe(`Bearer ${TOKEN}`);
    }
  });

  it("excludes the probe install from every pings query", async () => {
    await run();

    const pings = server.requests.filter(({ sql }) => sql.includes("cataclysm_pings"));
    expect(pings).toHaveLength(6);
    for (const { sql } of pings) {
      expect(sql).toContain(PROBE_EXCLUSION);
    }
  });

  it("refuses to print when a dataset is sampled", async () => {
    server.respond = (sql) =>
      sql.includes("max(_sample_interval)") && sql.includes("cataclysm_pings")
        ? rows([{ max_interval: 4 }])
        : fullReport(sql);

    const result = await run();

    expect(result.code).toBe(2);
    expect(result.stderr).toContain("cataclysm_pings is sampled (max _sample_interval = 4)");
    expect(result.stdout).toBe("");
  });

  it("treats a dataset the API has never seen as empty", async () => {
    server.respond = (sql) =>
      sql.includes("cataclysm_pings")
        ? error(400, "unknown table 'cataclysm_pings'")
        : fullReport(sql);

    const result = await run();

    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Daily active installs (last 90 days)\n  (none)\n");
    expect(result.stdout).toContain("  (no heartbeats)\n");
    expect(result.stdout).toContain("  (no installs yet)\n");
    expect(result.stdout).toContain("  2026-08-20  3\n");
  });

  it("fails loudly on an API error that does not name a dataset", async () => {
    server.respond = (sql) =>
      sql.includes("AS jail") ? error(400, "column 'double9' does not exist") : fullReport(sql);

    const result = await run();

    expect(result.code).toBe(1);
    expect(result.stderr).toContain("SQL API returned 400");
    expect(result.stderr).toContain("double9");
    expect(result.stderr).toContain("query: SELECT double2 AS jail");
  });

  it("fails when the API cannot be reached", async () => {
    const result = await run([], { STATS_API_URL: "http://127.0.0.1:1/sql" });

    expect(result.code).toBe(1);
    expect(result.stderr).toContain("request to the SQL API failed");
  });

  it("refuses to run without a token", async () => {
    // HOME is redirected so the keychain fallback cannot find a real item.
    const result = await run([], { CLOUDFLARE_API_TOKEN: "", HOME: "/nonexistent" });

    expect(result.code).toBe(1);
    expect(result.stderr).toContain("no analytics token");
    expect(server.requests).toHaveLength(0);
  });

  it("prints every statement and no report in --dry-run without a token", async () => {
    const result = await run(["--dry-run"], { CLOUDFLARE_API_TOKEN: "", STATS_API_URL: "" });

    expect(result.code).toBe(0);
    expect(server.requests).toHaveLength(0);
    const statements = result.stdout.split("\n").filter((line) => line.startsWith("SELECT"));
    expect(statements).toHaveLength(8);
    expect(statements.every((line) => line.endsWith(";"))).toBe(true);
    expect(result.stdout).toContain("  (none)\n");
    expect(result.stdout).toContain("  (no installs yet)\n");
  });

  it("rejects an unknown argument", async () => {
    const result = await run(["--verbose"]);

    expect(result.code).toBe(64);
    expect(result.stderr).toContain("usage: stats.sh [--dry-run]");
  });
});
