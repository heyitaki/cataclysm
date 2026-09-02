/** Fixtures and stubs shared by the Worker's tests. */

export const DOWNLOAD_URL = "https://akshath.me/cataclysm/download";
export const NO_BUILD_URL = "https://akshath.me/cataclysm?error=no-build";
export const FALLBACK_DMG_URL =
  "https://github.com/heyitaki/cataclysm/releases/latest/download/Cataclysm.dmg";
export const RELEASES_URL =
  "https://api.github.com/repos/heyitaki/cataclysm/releases?per_page=10";

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
