/** Fixtures and stubs shared by the Worker's tests. */

export const DOWNLOAD_URL = "https://akshath.me/cataclysm/download";
export const NO_BUILD_URL = "https://akshath.me/cataclysm?error=no-build";
export const FALLBACK_DMG_URL =
  "https://github.com/heyitaki/cataclysm/releases/latest/download/Cataclysm.dmg";
export const RELEASES_URL =
  "https://api.github.com/repos/heyitaki/cataclysm/releases?per_page=10";
export const PING_URL = "https://akshath.me/cataclysm/ping";

/** The reserved probe identity: the only install id a live check may send. */
export const PROBE_INSTALL_ID = "00000000-0000-0000-0000-000000000000";

/**
 * A heartbeat exactly as the app sends it. Overrides replace a field; a field
 * set to `undefined` is dropped, which is how the missing-field cases are built.
 *
 * @param {Record<string, unknown>} [overrides]
 */
export function ping(overrides = {}) {
  const payload = {
    install: "8b4f1d2e-6c37-4a91-b0d5-1e7f2a3c4d59",
    created: "2026-08-30",
    version: "0.1.0",
    macos: "26.3.0",
    arch: "arm64",
    enabled: true,
    jailEnabled: false,
    ...overrides,
  };
  for (const [key, value] of Object.entries(payload)) {
    if (value === undefined) delete payload[key];
  }
  return payload;
}

/**
 * A POST carrying `body` (an object is serialised, a string is sent as is).
 *
 * @param {object | string} body
 * @param {string} [url]
 */
export function pingRequest(body, url = PING_URL) {
  return makeRequest(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

/**
 * A release asset as the GitHub API returns it.
 *
 * @param {string} tag
 * @param {string} name
 * @param {{ digest?: string | null }} [extra]
 */
export function asset(tag, name, extra = {}) {
  return {
    name,
    browser_download_url: `https://github.com/heyitaki/cataclysm/releases/download/${tag}/${name}`,
    ...extra,
  };
}

/**
 * A release entry. `assets` takes either names or objects from `asset()`.
 *
 * @param {string} tag
 * @param {(string | object)[]} assets
 * @param {{ draft?: boolean, prerelease?: boolean }} [flags]
 */
export function release(tag, assets = [], flags = {}) {
  return {
    tag_name: tag,
    draft: false,
    prerelease: false,
    ...flags,
    assets: assets.map((a) => (typeof a === "string" ? asset(tag, a) : a)),
  };
}

/** A recording Analytics Engine binding. */
export function dataset() {
  const rows = [];
  return {
    rows,
    /** @param {object} row */
    writeDataPoint(row) {
      rows.push(row);
    },
  };
}

/** An `env` whose bindings record every write. */
export function makeEnv(vars = {}) {
  return { DOWNLOADS: dataset(), PINGS: dataset(), PING_ENABLED: "true", ...vars };
}

/**
 * A stub `fetch` that records its calls and replies from a queue of handlers.
 * Each handler is a function of the request arguments; a non-function value is
 * returned as is, and a thrown value propagates, which is how the network-error
 * and timeout cases are expressed.
 *
 * @param {((url: string, init: object) => any) | any} responder
 */
export function stubFetch(responder) {
  const calls = [];
  const fetch = async (...args) => {
    calls.push(args);
    const value = typeof responder === "function" ? responder(...args) : responder;
    if (value instanceof Error) throw value;
    return value;
  };
  fetch.calls = calls;
  return fetch;
}

/**
 * A stub `fetch` that serves the release list and nothing else.
 *
 * @param {object[]} releases
 */
export function releasesFetch(releases) {
  return stubFetch((url) => {
    if (url === RELEASES_URL) return jsonResponse(releases);
    throw new Error(`unexpected fetch: ${url}`);
  });
}

/**
 * @param {unknown} body
 * @param {number} [status]
 */
export function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/**
 * A request the handler can read, with Cloudflare's `cf` object attached the
 * way the runtime attaches it.
 *
 * @param {string} url
 * @param {{ method?: string, headers?: Record<string, string>, body?: string, country?: string }} [init]
 */
export function makeRequest(url, init = {}) {
  const { country, ...rest } = init;
  const request = new Request(url, rest);
  if (country !== undefined) request.cf = { country };
  return request;
}

/** A `now` whose value the test advances. */
export function makeClock(start = 1_700_000_000_000) {
  let value = start;
  const now = () => value;
  now.advance = (ms) => {
    value += ms;
  };
  return now;
}
