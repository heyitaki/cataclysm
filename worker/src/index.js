/**
 * Cataclysm's Worker on the akshath.me zone.
 *
 * The route pattern is a wildcard (`akshath.me/cataclysm/*`), so requests this
 * Worker does not own land here too. It dispatches on the exact pathname and
 * forwards everything else to the origin with the injected `fetch`, which is
 * what keeps the GitHub Pages passthrough promise true.
 */

const REPO = "heyitaki/cataclysm";
const RELEASES_URL = `https://api.github.com/repos/${REPO}/releases?per_page=10`;
const PAGE_URL = "https://akshath.me/cataclysm";
const NO_BUILD_URL = `${PAGE_URL}?error=no-build`;

/**
 * Version-stable asset name, so this fallback needs no API call. `make dmg`
 * produces it as a byte-identical copy of `Cataclysm-<version>.dmg`.
 */
const FALLBACK_DMG_URL = `https://github.com/${REPO}/releases/latest/download/Cataclysm.dmg`;

const RELEASE_CACHE_MS = 10 * 60 * 1000;
const GITHUB_TIMEOUT_MS = 8000;
/** Real browser user agents run to about 150 characters. */
const USER_AGENT_MAX_CHARS = 512;

/** GitHub rejects any API request without a User-Agent with a 403. */
const GITHUB_HEADERS = {
  "User-Agent": "cataclysm-worker",
  Accept: "application/vnd.github+json",
};

/**
 * A heartbeat is seven small fields, so anything larger is not one. The cap is
 * checked before the body is parsed.
 */
const PING_MAX_BYTES = 1024;

/**
 * Lowercase canonical UUID. The nil UUID passes, which is deliberate: it is the
 * reserved probe identity the live checks send, accepted here and excluded by
 * every `stats.sh` query.
 */
const INSTALL_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const CREATED_RE = /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/;
/** One to four dotted integers, which covers both app and macOS versions. */
const DOTTED_RE = /^\d+(\.\d+){0,3}$/;
const ARCHITECTURES = new Set(["arm64", "x86_64"]);

/**
 * The heartbeat's fields and their validators. The key set is exact in both
 * directions: a payload missing one of these or carrying anything else is
 * rejected, so a field added to the app without a Worker change is visible as a
 * 400 instead of landing silently in the wrong blob.
 *
 * @type {Record<string, (value: unknown) => boolean>}
 */
const PING_FIELDS = {
  install: (v) => typeof v === "string" && INSTALL_RE.test(v),
  created: (v) => typeof v === "string" && CREATED_RE.test(v),
  version: (v) => typeof v === "string" && DOTTED_RE.test(v),
  macos: (v) => typeof v === "string" && DOTTED_RE.test(v),
  arch: (v) => typeof v === "string" && ARCHITECTURES.has(v),
  enabled: (v) => typeof v === "boolean",
  jailEnabled: (v) => typeof v === "boolean",
};

/**
 * @typedef {{ name: string, browser_download_url: string, digest?: string | null }} ReleaseAsset
 * @typedef {{ tag_name: string, draft?: boolean, prerelease?: boolean, assets?: ReleaseAsset[] }} Release
 */

/**
 * The release tag convention is `v0.2.0` while the asset is
 * `Cataclysm-0.2.0.dmg`, so exactly one leading `v` comes off.
 *
 * @param {string} tag
 * @returns {string}
 */
function versionFromTag(tag) {
  return typeof tag === "string" && tag.startsWith("v") ? tag.slice(1) : tag;
}

/**
 * @param {Release} release
 * @param {string} name
 * @returns {ReleaseAsset | undefined}
 */
function findAsset(release, name) {
  const assets = Array.isArray(release.assets) ? release.assets : [];
  // Only the exact name counts: several assets can match `Cataclysm-*.dmg`, and
  // the one whose version equals the tag is the release's own build.
  return assets.find((asset) => asset && asset.name === name);
}

/**
 * @param {string} url
 * @returns {Response}
 */
function redirect(url) {
  return new Response(null, {
    status: 302,
    // Never cached: the target moves with every release, and the no-build and
    // fallback redirects are transient states a cache must not pin.
    headers: { Location: url, "Cache-Control": "no-store" },
  });
}

/**
 * @param {string} allow
 * @returns {Response}
 */
function methodNotAllowed(allow) {
  return new Response("Method Not Allowed", {
    status: 405,
    headers: { Allow: allow },
  });
}

/**
 * @returns {Response}
 */
function badRequest() {
  return new Response("Bad Request", { status: 400 });
}

/**
 * @returns {Response}
 */
function noContent() {
  return new Response(null, { status: 204 });
}

/**
 * Reads a JSON body no larger than `maxBytes`. Oversize, unparseable and absent
 * bodies are one case, `undefined`, because the caller answers all three the
 * same way and `JSON.parse` never yields `undefined` for a valid document.
 *
 * The body is consumed chunk by chunk and abandoned the moment the cap is
 * passed, so an oversize POST costs the Worker at most one chunk of memory
 * rather than the whole upload.
 *
 * @param {Request} request
 * @param {number} maxBytes
 * @returns {Promise<unknown>}
 */
async function readJson(request, maxBytes) {
  const declared = Number(request.headers.get("content-length"));
  // Cheap rejection before the body is read at all; the header is advisory, so
  // the bytes are counted again below.
  if (Number.isFinite(declared) && declared > maxBytes) return undefined;
  if (!request.body) return undefined;

  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxBytes) {
        await reader.cancel();
        return undefined;
      }
      chunks.push(value);
    }
  } catch {
    // A connection that drops mid-body is a bad request, not a Worker error.
    return undefined;
  }

  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return undefined;
  }
}

/**
 * The Analytics Engine row for a heartbeat, or null when the payload is not a
 * valid one.
 *
 * @param {unknown} body
 * @returns {{ indexes: string[], blobs: string[], doubles: number[] } | null}
 */
function pingRow(body) {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return null;
  }
  const names = Object.keys(PING_FIELDS);
  if (Object.keys(body).length !== names.length) return null;
  for (const name of names) {
    if (!Object.hasOwn(body, name)) return null;
    if (!PING_FIELDS[name](body[name])) return null;
  }
  return {
    // Install id as the index keeps count(DISTINCT install) honest if sampling
    // ever starts; it is repeated as a blob so queries can read it as a value.
    indexes: [body.install],
    blobs: [body.install, body.created, body.version, body.macos, body.arch],
    doubles: [body.enabled ? 1 : 0, body.jailEnabled ? 1 : 0],
  };
}

/**
 * @param {{ fetch: typeof globalThis.fetch, now: () => number }} deps
 * @returns {(request: Request, env: Record<string, any>) => Promise<Response>}
 */
export function makeHandler({ fetch, now }) {
  /**
   * Release list cache, shared by every route that resolves a release. It lives
   * in this closure, which the production module instantiates exactly once, so
   * it is module-scoped in the Worker while staying per-handler in tests.
   *
   * @type {{ expires: number, releases: Release[] } | null}
   */
  let releaseCache = null;

  /**
   * The lookup in flight while the cache is cold. Requests that arrive during
   * it share its result instead of each spending one of GitHub's 60 per-hour
   * unauthenticated calls, which a burst on a cold cache could otherwise
   * exhaust in one go.
   *
   * @type {Promise<{ ok: true, releases: Release[] } | { ok: false }> | null}
   */
  let releaseLookup = null;

  /**
   * The recent releases, newest first, from the cache or one shared lookup.
   *
   * @returns {Promise<{ ok: true, releases: Release[] } | { ok: false }>}
   */
  function loadReleases() {
    if (releaseCache && releaseCache.expires > now()) {
      return Promise.resolve({ ok: true, releases: releaseCache.releases });
    }
    if (!releaseLookup) {
      releaseLookup = fetchReleases().finally(() => {
        releaseLookup = null;
      });
    }
    return releaseLookup;
  }

  /**
   * Fetches the recent releases. Failures are not cached: an outage should not
   * pin the fallback for ten minutes.
   *
   * @returns {Promise<{ ok: true, releases: Release[] } | { ok: false }>}
   */
  async function fetchReleases() {
    try {
      const response = await fetch(RELEASES_URL, {
        headers: GITHUB_HEADERS,
        signal: AbortSignal.timeout(GITHUB_TIMEOUT_MS),
      });
      if (!response.ok) return { ok: false };
      const body = await response.json();
      if (!Array.isArray(body)) return { ok: false };
      releaseCache = { expires: now() + RELEASE_CACHE_MS, releases: body };
      return { ok: true, releases: body };
    } catch {
      // Network error, abort from the timeout, or unparseable body: all one
      // case, "the API failed", because none of them yields a version.
      return { ok: false };
    }
  }

  /**
   * @param {Request} request
   * @param {Record<string, any>} env
   * @returns {Promise<Response>}
   */
  async function handleDownload(request, env) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return methodNotAllowed("GET, HEAD");
    }

    const result = await loadReleases();
    // API failure: the version is unknown, so the row would be a lie. Serve the
    // version-stable fallback and accept that this download is invisible.
    if (!result.ok) return redirect(FALLBACK_DMG_URL);
    const release = result.releases.find(
      (entry) => entry && !entry.draft && !entry.prerelease,
    );
    if (!release) return redirect(NO_BUILD_URL);

    const version = versionFromTag(release.tag_name);
    const asset = findAsset(release, `Cataclysm-${version}.dmg`);
    if (!asset || !asset.browser_download_url) return redirect(NO_BUILD_URL);

    // Only a GET is a download. HEAD is what link previews, uptime probes and
    // link checkers send, and none of them fetch the image.
    if (request.method === "GET") countDownload(request, env, version);
    return redirect(asset.browser_download_url);
  }

  /**
   * One downloads row. The redirect must go out whatever happens here, so a
   * rejected row (Analytics Engine caps a row's blobs at 5 KB and throws past
   * it) is dropped rather than turned into an error page; the user agent is
   * trimmed so an outsized header alone cannot reach that cap.
   *
   * @param {Request} request
   * @param {Record<string, any>} env
   * @param {string} version
   */
  function countDownload(request, env, version) {
    try {
      env.DOWNLOADS.writeDataPoint({
        indexes: [version],
        blobs: [
          version,
          (request.headers.get("user-agent") ?? "").slice(0, USER_AGENT_MAX_CHARS),
          request.cf?.country ?? "",
        ],
      });
    } catch {
      // An invisible download beats a failed one.
    }
  }

  /**
   * @param {Request} request
   * @param {Record<string, any>} env
   * @returns {Promise<Response>}
   */
  async function handlePing(request, env) {
    if (request.method !== "POST") return methodNotAllowed("POST");

    // Browsers attach Origin to every cross-origin POST, and a text/plain body
    // skips the preflight, so without this any web page could turn its
    // visitors into heartbeat writers. URLSession sends no Origin, so a real
    // heartbeat is unaffected.
    if (request.headers.has("origin")) return badRequest();

    // The kill switch stops collection without touching /download, and answers
    // before the body is read so a flood costs nothing. The app cannot tell
    // this apart from an accepted heartbeat, which is the point: it must not
    // retry, and it must not learn that collection is off.
    if (env.PING_ENABLED !== "true") return noContent();

    const row = pingRow(await readJson(request, PING_MAX_BYTES));
    if (!row) return badRequest();

    try {
      env.PINGS.writeDataPoint(row);
    } catch {
      // Same rule as countDownload: a dropped row beats a 500 the app would
      // ignore anyway.
    }
    return noContent();
  }

  return async function handle(request, env) {
    const pathname = new URL(request.url).pathname;
    switch (pathname) {
      case "/cataclysm/download":
        return handleDownload(request, env);
      case "/cataclysm/ping":
        return handlePing(request, env);
      default:
        // Not ours. GitHub Pages answers it, including /cataclysm itself.
        return fetch(request);
    }
  };
}

const handler = makeHandler({
  fetch: (...args) => globalThis.fetch(...args),
  now: () => Date.now(),
});

export default {
  /**
   * @param {Request} request
   * @param {Record<string, any>} env
   * @returns {Promise<Response>}
   */
  fetch(request, env) {
    return handler(request, env);
  },
};
