import { describe, expect, it } from "vitest";
import * as entry from "../src/worker";
import wranglerToml from "../wrangler.toml?raw";

describe("the Worker's entry", () => {
  it("is src/worker.ts in wrangler.toml", () => {
    expect(wranglerToml).toMatch(/^main = "src\/worker\.ts"$/m);
  });

  // The runtime takes every export of the entry as an entrypoint and refuses one that is not
  // a handler or a class: a constant there stops the Worker from starting.
  it("exports only the handlers and the Durable Object class", () => {
    expect(Object.keys(entry).sort()).toEqual(["Presence", "default"]);
    expect(typeof entry.default.fetch).toBe("function");
    expect(typeof entry.default.scheduled).toBe("function");
    expect(typeof entry.Presence).toBe("function");
  });
});
