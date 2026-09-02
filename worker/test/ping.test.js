import { describe, expect, it } from "vitest";
import { makeHandler } from "../src/index.js";
import {
  PING_URL,
  PROBE_INSTALL_ID,
  makeClock,
  makeEnv,
  makeRequest,
  ping,
  pingRequest,
  stubFetch,
} from "./helpers.js";

/**
 * /ping never talks to GitHub, so any outbound call from this route is a bug
 * the stub turns into a failure.
 */
function handler() {
  return makeHandler({
    fetch: stubFetch(() => {
      throw new Error("/ping must not call out");
    }),
    now: makeClock(),
  });
}

/** The row a valid heartbeat writes, spelled out rather than derived. */
const EXPECTED_ROW = {
  indexes: ["8b4f1d2e-6c37-4a91-b0d5-1e7f2a3c4d59"],
  blobs: [
    "8b4f1d2e-6c37-4a91-b0d5-1e7f2a3c4d59",
    "2026-08-30",
    "0.1.0",
    "26.3.0",
    "arm64",
  ],
  doubles: [1, 0],
};

describe("/cataclysm/ping", () => {
  it("accepts a heartbeat with 204 and writes exactly one row", async () => {
    const env = makeEnv();
    const response = await handler()(pingRequest(ping()), env);

    expect(response.status).toBe(204);
    expect(env.PINGS.rows).toEqual([EXPECTED_ROW]);
  });

  it("writes both flags as doubles", async () => {
    const env = makeEnv();
    await handler()(
      pingRequest(ping({ enabled: false, jailEnabled: true })),
      env,
    );

    expect(env.PINGS.rows[0].doubles).toEqual([0, 1]);
  });

  it("accepts the nil UUID, which is the reserved probe identity", async () => {
    const env = makeEnv();
    const response = await handler()(
      pingRequest(ping({ install: PROBE_INSTALL_ID })),
      env,
    );

    expect(response.status).toBe(204);
    expect(env.PINGS.rows[0].indexes).toEqual([PROBE_INSTALL_ID]);
  });

  it("still serves the route when a query string is attached", async () => {
    const env = makeEnv();
    const response = await handler()(
      pingRequest(ping(), `${PING_URL}?v=1`),
      env,
    );

    expect(response.status).toBe(204);
    expect(env.PINGS.rows).toHaveLength(1);
  });

  it("never writes to the downloads dataset", async () => {
    const env = makeEnv();
    await handler()(pingRequest(ping()), env);

    expect(env.DOWNLOADS.rows).toEqual([]);
  });

  for (const method of ["GET", "PUT", "DELETE"]) {
    it(`rejects ${method} with 405`, async () => {
      const env = makeEnv();
      const response = await handler()(
        makeRequest(PING_URL, { method }),
        env,
      );

      expect(response.status).toBe(405);
      expect(response.headers.get("Allow")).toBe("POST");
      expect(env.PINGS.rows).toEqual([]);
    });
  }

  it("rejects a body over 1024 bytes", async () => {
    const env = makeEnv();
    // Valid in every way except its size: the padding is leading whitespace,
    // which JSON allows, so only the byte cap can reject this.
    const padded = " ".repeat(1100) + JSON.stringify(ping());
    const response = await handler()(pingRequest(padded), env);

    expect(response.status).toBe(400);
    expect(env.PINGS.rows).toEqual([]);
  });

  it("accepts a body just under the cap", async () => {
    const body = JSON.stringify(ping());
    const padded = " ".repeat(1024 - body.length) + body;
    const response = await handler()(pingRequest(padded), makeEnv());

    expect(padded.length).toBe(1024);
    expect(response.status).toBe(204);
  });

  const malformed = [
    ["invalid JSON", "{not json"],
    ["an empty body", ""],
    ["a JSON array", "[]"],
    ["a JSON string", '"hello"'],
    ["JSON null", "null"],
  ];

  for (const [label, body] of malformed) {
    it(`rejects ${label} with 400`, async () => {
      const env = makeEnv();
      const response = await handler()(pingRequest(body), env);

      expect(response.status).toBe(400);
      expect(env.PINGS.rows).toEqual([]);
    });
  }

  for (const field of [
    "install",
    "created",
    "version",
    "macos",
    "arch",
    "enabled",
    "jailEnabled",
  ]) {
    it(`rejects a payload missing ${field}`, async () => {
      const env = makeEnv();
      const response = await handler()(
        pingRequest(ping({ [field]: undefined })),
        env,
      );

      expect(response.status).toBe(400);
      expect(env.PINGS.rows).toEqual([]);
    });
  }

  const invalid = [
    ["an extra field", { extra: "surprise" }],
    ["an uppercase install id", { install: "8B4F1D2E-6C37-4A91-B0D5-1E7F2A3C4D59" }],
    ["an install id that is not a UUID", { install: "install-1" }],
    ["a non-string install id", { install: 12345 }],
    ["a created date that is not YYYY-MM-DD", { created: "30/08/2026" }],
    ["a created date with a month of 13", { created: "2026-13-01" }],
    ["a created timestamp", { created: "2026-08-30T12:00:00Z" }],
    ["a version with a letter", { version: "0.1.0b" }],
    ["a version with five components", { version: "1.2.3.4.5" }],
    ["an empty version", { version: "" }],
    ["a non-dotted macOS version", { macos: "Tahoe" }],
    ["an arch of x64", { arch: "x64" }],
    ["enabled as the string true", { enabled: "true" }],
    ["jailEnabled as a number", { jailEnabled: 1 }],
  ];

  for (const [label, overrides] of invalid) {
    it(`rejects ${label} with 400`, async () => {
      const env = makeEnv();
      const response = await handler()(pingRequest(ping(overrides)), env);

      expect(response.status).toBe(400);
      expect(env.PINGS.rows).toEqual([]);
    });
  }

  const accepted = [
    ["a single-component version", { version: "1" }],
    ["a four-component version", { version: "1.2.3.4" }],
    ["an Intel arch", { arch: "x86_64" }],
  ];

  for (const [label, overrides] of accepted) {
    it(`accepts ${label}`, async () => {
      const env = makeEnv();
      const response = await handler()(pingRequest(ping(overrides)), env);

      expect(response.status).toBe(204);
      expect(env.PINGS.rows).toHaveLength(1);
    });
  }
});

describe("PING_ENABLED kill switch", () => {
  it("answers 204 and writes nothing when collection is off", async () => {
    const env = makeEnv({ PING_ENABLED: "false" });
    const response = await handler()(pingRequest(ping()), env);

    // The app must not be able to tell this apart from an accepted heartbeat,
    // or it would retry a ping the operator switched off.
    expect(response.status).toBe(204);
    expect(env.PINGS.rows).toEqual([]);
  });

  it("answers 204 and writes nothing when the var is missing", async () => {
    const env = makeEnv({ PING_ENABLED: undefined });
    const response = await handler()(pingRequest(ping()), env);

    expect(response.status).toBe(204);
    expect(env.PINGS.rows).toEqual([]);
  });

  it("still rejects a bad method while collection is off", async () => {
    const env = makeEnv({ PING_ENABLED: "false" });
    const response = await handler()(
      makeRequest(PING_URL, { method: "GET" }),
      env,
    );

    expect(response.status).toBe(405);
  });

  it("leaves /download untouched", async () => {
    const env = makeEnv({ PING_ENABLED: "false" });
    const fetch = stubFetch(() =>
      Response.json([
        {
          tag_name: "v0.2.0",
          draft: false,
          prerelease: false,
          assets: [
            {
              name: "Cataclysm-0.2.0.dmg",
              browser_download_url: "https://example.invalid/Cataclysm-0.2.0.dmg",
            },
          ],
        },
      ]),
    );
    const response = await makeHandler({ fetch, now: makeClock() })(
      makeRequest("https://akshath.me/cataclysm/download"),
      env,
    );

    expect(response.status).toBe(302);
    expect(env.DOWNLOADS.rows).toHaveLength(1);
  });
});
