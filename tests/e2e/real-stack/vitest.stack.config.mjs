// Runs stack.launch.ts under AppBoundry's vitest, rooted in the AppBoundry checkout.
import { fileURLToPath } from "node:url";
export default {
  root: process.env.APPBOUNDRY_DIR,
  test: {
    globals: true,
    include: [fileURLToPath(new URL("./stack.launch.ts", import.meta.url))],
    testTimeout: 3_600_000,
    hookTimeout: 600_000,
    pool: "forks",
  },
  server: { fs: { strict: false } },
};
