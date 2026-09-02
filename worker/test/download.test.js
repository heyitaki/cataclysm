import { afterEach, describe, expect, it, vi } from "vitest";
import { makeHandler } from "../src/index.js";
import {
  DOWNLOAD_URL,
  FALLBACK_DMG_URL,
  NO_BUILD_URL,
  RELEASES_URL,
  asset,
  jsonResponse,
  makeClock,
  makeEnv,
  makeRequest,
  release,
  releasesFetch,
  stubFetch,
} from "./helpers.js";

/**
 * @param {ReturnType<typeof stubFetch>} fetch
 */
function handlerWith(fetch, now = makeClock()) {
  return makeHandler({ fetch, now });
}

/** The common shape: one stable release carrying its own DMG. */
function stableReleases() {
  return [release("v0.2.0", ["Cataclysm-0.2.0.dmg", "Cataclysm.dmg"])];
}

describe("/cataclysm/download", () => {
  it("redirects to the newest release's DMG and counts it", async () => {
    const fetch = releasesFetch(stableReleases());
    const env = makeEnv();
    const response = await handlerWith(fetch)(
      makeRequest(DOWNLOAD_URL, {
        headers: { "User-Agent": "Mozilla/5.0 (Macintosh)" },
        country: "US",
      }),
      env,
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("Location")).toBe(
      "https://github.com/heyitaki/cataclysm/releases/download/v0.2.0/Cataclysm-0.2.0.dmg",
    );
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(env.DOWNLOADS.rows).toEqual([
      {
        indexes: ["0.2.0"],
        blobs: ["0.2.0", "Mozilla/5.0 (Macintosh)", "US"],
      },
    ]);
  });

  it("sends the GitHub API an explicit User-Agent", async () => {
    const fetch = releasesFetch(stableReleases());
    await handlerWith(fetch)(makeRequest(DOWNLOAD_URL), makeEnv());

    expect(fetch.calls[0][0]).toBe(RELEASES_URL);
    expect(fetch.calls[0][1].headers["User-Agent"]).toBe("cataclysm-worker");
  });

  it("records an empty country and user agent when neither is present", async () => {
    const env = makeEnv();
    await handlerWith(releasesFetch(stableReleases()))(
      makeRequest(DOWNLOAD_URL),
      env,
    );

    expect(env.DOWNLOADS.rows[0].blobs).toEqual(["0.2.0", "", ""]);
  });

  it("still serves the route when a query string is attached", async () => {
    const env = makeEnv();
    const response = await handlerWith(releasesFetch(stableReleases()))(
      makeRequest(`${DOWNLOAD_URL}?src=page`),
      env,
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("Location")).toContain("Cataclysm-0.2.0.dmg");
    expect(env.DOWNLOADS.rows).toHaveLength(1);
  });

  it("redirects to the page with no-build when there are no releases", async () => {
    const env = makeEnv();
    const response = await handlerWith(releasesFetch([]))(
      makeRequest(DOWNLOAD_URL),
      env,
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("Location")).toBe(NO_BUILD_URL);
    expect(env.DOWNLOADS.rows).toEqual([]);
  });

  it("redirects with no-build when the newest release has no DMG", async () => {
    const env = makeEnv();
    const response = await handlerWith(
      releasesFetch([release("v0.2.0", ["Cataclysm-0.2.0.zip"])]),
    )(makeRequest(DOWNLOAD_URL), env);

    expect(response.status).toBe(302);
    expect(response.headers.get("Location")).toBe(NO_BUILD_URL);
    expect(env.DOWNLOADS.rows).toEqual([]);
  });

  it("picks the DMG whose version matches the tag with one v stripped", async () => {
    const response = await handlerWith(
      releasesFetch([
        release("v0.2.0", ["Cataclysm-0.1.0.dmg", "Cataclysm-0.2.0.dmg"]),
      ]),
    )(makeRequest(DOWNLOAD_URL), makeEnv());

    expect(response.headers.get("Location")).toBe(
      "https://github.com/heyitaki/cataclysm/releases/download/v0.2.0/Cataclysm-0.2.0.dmg",
    );
  });

  it("treats a DMG asset without a download URL as no DMG", async () => {
    const env = makeEnv();
    const response = await handlerWith(
      releasesFetch([
        release("v0.2.0", [
          asset("v0.2.0", "Cataclysm-0.2.0.dmg", { browser_download_url: undefined }),
        ]),
      ]),
    )(makeRequest(DOWNLOAD_URL), env);

    expect(response.headers.get("Location")).toBe(NO_BUILD_URL);
    expect(env.DOWNLOADS.rows).toEqual([]);
  });

  it("treats several DMGs that all miss the tag as no DMG", async () => {
    const env = makeEnv();
    const response = await handlerWith(
      releasesFetch([
        release("v0.2.0", ["Cataclysm-0.1.0.dmg", "Cataclysm-0.3.0.dmg"]),
      ]),
    )(makeRequest(DOWNLOAD_URL), env);

    expect(response.headers.get("Location")).toBe(NO_BUILD_URL);
    expect(env.DOWNLOADS.rows).toEqual([]);
  });

  it("skips drafts and prereleases in favour of the next stable release", async () => {
    const env = makeEnv();
    const response = await handlerWith(
      releasesFetch([
        release("v0.4.0", ["Cataclysm-0.4.0.dmg"], { draft: true }),
        release("v0.3.0", ["Cataclysm-0.3.0.dmg"], { prerelease: true }),
        release("v0.2.0", ["Cataclysm-0.2.0.dmg"]),
      ]),
    )(makeRequest(DOWNLOAD_URL), env);

    expect(response.headers.get("Location")).toContain("Cataclysm-0.2.0.dmg");
    expect(env.DOWNLOADS.rows[0].indexes).toEqual(["0.2.0"]);
  });

  const failures = [
    ["an upstream 503", () => jsonResponse({ message: "nope" }, 503)],
    ["a rate-limit 403", () => jsonResponse({ message: "rate limited" }, 403)],
    ["a 200 whose body is not a list", () => jsonResponse({ message: "moved" })],
    ["a 200 whose body is not JSON", () => new Response("{not json", { status: 200 })],
    [
      "a network error",
      () => {
        throw new Error("connection reset");
      },
    ],
    [
      "a request timeout",
      () => {
        const error = new Error("The operation was aborted due to timeout");
        error.name = "TimeoutError";
        throw error;
      },
    ],
  ];

  for (const [label, responder] of failures) {
    it(`falls back to the version-stable DMG on ${label}`, async () => {
      const env = makeEnv();
      const response = await handlerWith(stubFetch(responder))(
        makeRequest(DOWNLOAD_URL),
        env,
      );

      expect(response.status).toBe(302);
      expect(response.headers.get("Location")).toBe(FALLBACK_DMG_URL);
      expect(env.DOWNLOADS.rows).toEqual([]);
    });
  }

  describe("timeout", () => {
    afterEach(() => vi.restoreAllMocks());

    it("asks the API for the release list with an 8 second timeout", async () => {
      const timeout = vi.spyOn(AbortSignal, "timeout");
      const fetch = releasesFetch(stableReleases());
      await handlerWith(fetch)(makeRequest(DOWNLOAD_URL), makeEnv());

      expect(timeout).toHaveBeenCalledWith(8000);
      expect(fetch.calls[0][1].signal).toBe(timeout.mock.results[0].value);
    });
  });

  it("trims an outsized user agent so the row stays under the blob cap", async () => {
    const env = makeEnv();
    await handlerWith(releasesFetch(stableReleases()))(
      makeRequest(DOWNLOAD_URL, { headers: { "User-Agent": "x".repeat(6000) } }),
      env,
    );

    expect(env.DOWNLOADS.rows[0].blobs[1]).toBe("x".repeat(512));
  });

  it("still redirects when the row is rejected", async () => {
    const env = makeEnv();
    env.DOWNLOADS.writeDataPoint = () => {
      throw new Error("blob size limit exceeded");
    };
    const response = await handlerWith(releasesFetch(stableReleases()))(
      makeRequest(DOWNLOAD_URL),
      env,
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("Location")).toContain("Cataclysm-0.2.0.dmg");
  });

  it("rejects methods other than GET and HEAD", async () => {
    const fetch = releasesFetch(stableReleases());
    const env = makeEnv();
    const response = await handlerWith(fetch)(
      makeRequest(DOWNLOAD_URL, { method: "POST" }),
      env,
    );

    expect(response.status).toBe(405);
    expect(fetch.calls).toHaveLength(0);
    expect(env.DOWNLOADS.rows).toEqual([]);
  });

  it("redirects HEAD like GET but does not count it", async () => {
    const env = makeEnv();
    const response = await handlerWith(releasesFetch(stableReleases()))(
      makeRequest(DOWNLOAD_URL, { method: "HEAD" }),
      env,
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("Location")).toContain("Cataclysm-0.2.0.dmg");
    expect(env.DOWNLOADS.rows).toEqual([]);
  });
});

describe("release cache", () => {
  it("serves a second request within ten minutes from one API call", async () => {
    const fetch = releasesFetch(stableReleases());
    const now = makeClock();
    const handle = handlerWith(fetch, now);

    await handle(makeRequest(DOWNLOAD_URL), makeEnv());
    now.advance(9 * 60 * 1000);
    const second = await handle(makeRequest(DOWNLOAD_URL), makeEnv());

    expect(fetch.calls).toHaveLength(1);
    expect(second.headers.get("Location")).toContain("Cataclysm-0.2.0.dmg");
  });

  it("calls the API again once the cache has expired", async () => {
    const fetch = releasesFetch(stableReleases());
    const now = makeClock();
    const handle = handlerWith(fetch, now);

    await handle(makeRequest(DOWNLOAD_URL), makeEnv());
    now.advance(10 * 60 * 1000 + 1);
    await handle(makeRequest(DOWNLOAD_URL), makeEnv());

    expect(fetch.calls).toHaveLength(2);
  });

  it("does not cache a failure", async () => {
    let attempt = 0;
    const fetch = stubFetch((url) => {
      attempt += 1;
      if (attempt === 1) return jsonResponse({ message: "nope" }, 503);
      return jsonResponse(stableReleases());
    });
    const handle = handlerWith(fetch);

    const first = await handle(makeRequest(DOWNLOAD_URL), makeEnv());
    const second = await handle(makeRequest(DOWNLOAD_URL), makeEnv());

    expect(first.headers.get("Location")).toBe(FALLBACK_DMG_URL);
    expect(second.headers.get("Location")).toContain("Cataclysm-0.2.0.dmg");
  });
});

describe("passthrough", () => {
  for (const path of [
    "/cataclysm/download-notes",
    "/cataclysm/",
    "/cataclysm",
    "/cataclysm/assets/style.css",
  ]) {
    it(`forwards ${path} to the origin untouched`, async () => {
      const origin = new Response("<html>pages</html>", { status: 404 });
      const fetch = stubFetch(() => origin);
      const request = makeRequest(`https://akshath.me${path}`);

      const response = await handlerWith(fetch)(request, makeEnv());

      expect(response).toBe(origin);
      expect(fetch.calls).toHaveLength(1);
      expect(fetch.calls[0][0]).toBe(request);
    });
  }

  it("forwards a POST it does not own without answering it", async () => {
    const origin = new Response("ok");
    const fetch = stubFetch(() => origin);
    const request = makeRequest("https://akshath.me/cataclysm/download-notes", {
      method: "POST",
      body: "{}",
    });

    const response = await handlerWith(fetch)(request, makeEnv());

    expect(response).toBe(origin);
  });
});
