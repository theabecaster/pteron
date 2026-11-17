import type { D1Migration } from "cloudflare:test";
import type { Env as GatewayEnv } from "../src/env";

declare global {
  namespace Cloudflare {
    interface Env extends GatewayEnv {
      TEST_MIGRATIONS: D1Migration[];
    }
  }
}
