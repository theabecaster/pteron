import { applyD1Migrations, env } from "cloudflare:test";

// Idempotent: it records what it applied, so running once per test file is fine.
await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
