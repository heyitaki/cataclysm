import { defineConfig } from "vitest/config";

// Plain Node, not @cloudflare/vitest-pool-workers: its vitest 4 line dropped
// fetchMock, so outbound GitHub calls cannot be mocked there. The handler takes
// fetch as an injected dependency instead.
export default defineConfig({
  test: {
    environment: "node",
  },
});
