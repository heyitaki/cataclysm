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

/** GitHub rejects any API request without a User-Agent with a 403. */
const GITHUB_HEADERS = {
  "User-Agent": "cataclysm-worker",
  Accept: "application/vnd.github+json",
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
   * Fetches the recent releases, newest first. Failures are not cached: an
   * outage should not pin the fallback for ten minutes.
   *
   * @returns {Promise<{ ok: true, releases: Release[] } | { ok: false }>}
   */
  async function loadReleases() {
    if (releaseCache && releaseCache.expires > now()) {
      return { ok: true, releases: releaseCache.releases };
    }
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
   * The newest release that is neither a draft nor a prerelease.
   *
   * @returns {Promise<{ ok: true, release: Release | null } | { ok: false }>}
   */
  async function newestStableRelease() {
    const result = await loadReleases();
    if (!result.ok) return { ok: false };
    const release = result.releases.find(
      (entry) => entry && !entry.draft && !entry.prerelease,
    );
    return { ok: true, release: release ?? null };
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

    const result = await newestStableRelease();
    // API failure: the version is unknown, so the row would be a lie. Serve the
    // version-stable fallback and accept that this download is invisible.
    if (!result.ok) return redirect(FALLBACK_DMG_URL);
    if (!result.release) return redirect(NO_BUILD_URL);

    const version = versionFromTag(result.release.tag_name);
    const asset = findAsset(result.release, `Cataclysm-${version}.dmg`);
    if (!asset || !asset.browser_download_url) return redirect(NO_BUILD_URL);

    env.DOWNLOADS.writeDataPoint({
      indexes: [version],
      blobs: [
        version,
        request.headers.get("user-agent") ?? "",
        request.cf?.country ?? "",
      ],
    });
    return redirect(asset.browser_download_url);
  }

  return async function handle(request, env) {
    const pathname = new URL(request.url).pathname;
    switch (pathname) {
      case "/cataclysm/download":
        return handleDownload(request, env);
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
