import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import smokeScript from "../scripts/smoke.sh?raw";
import { type DbLog, Gateway, type Registered, T0, errorOf, reset, spyOnDb, testEnv } from "./helpers";

/**
 * `POST /v1/push` passes on the notification the helper builds and nothing else. The
 * fixtures follow `PushMessage::payload` and `gateway::push_body` in Relay/src, one for each
 * category and each field the helper leaves out when it has no value. The helper sets
 * `expiration` to an hour from its own clock (`KEEP_SECONDS`), and the type is always `alert`.
 */

let gw: Gateway;
let device: Registered;
let log: DbLog;
beforeEach(async () => {
  await reset();
  gw = new Gateway();
  device = await gw.register();
  const spy = spyOnDb(env.DB);
  gw.env = { ...testEnv, DB: spy.db };
  log = spy.log;
});

const PLACE = { server: "https://rex.example.ts.net", session_id: "session:s1", block_id: "block:01a1-b1" };

/** A blocked agent: time-sensitive, with a sound, a subtitle (the session), a tab and a collapse id. */
const BLOCKED = {
  payload: {
    aps: {
      alert: { title: "Claude · api", body: "Which DB?", subtitle: "work" },
      "interruption-level": "time-sensitive",
      "thread-id": "block:01a1-b1",
      category: "AGENT_BLOCKED",
      sound: "default",
    },
    ...PLACE,
    window_id: "window:w1",
  },
  push_type: "alert",
  priority: 10,
  expiration: T0 + 3600,
  collapse_id: "01a1-b1-e40c292c",
};

/** A blocked agent in a session that names its tab: no subtitle, and no tab id was found. */
const BLOCKED_BARE = {
  payload: {
    aps: {
      alert: { title: "Codex · Rex", body: "Needs your permission" },
      "interruption-level": "time-sensitive",
      "thread-id": "block:01a1-b1",
      category: "AGENT_BLOCKED",
      sound: "default",
    },
    ...PLACE,
  },
  push_type: "alert",
  priority: 10,
  expiration: T0 + 3600,
  collapse_id: "01a1-b1",
};

/**
 * A blocked agent from a helper that also names the wait (`record`, `fp`), which the app
 * needs for its Enter and Interrupt: the category with the actions.
 */
const BLOCKED_ACT = {
  ...BLOCKED,
  payload: {
    ...BLOCKED.payload,
    aps: { ...BLOCKED.payload.aps, category: "AGENT_BLOCKED_ACT" },
    record: "claude",
    fp: "c3a1f0e29b7d4658",
  },
};

/** A finished agent: passive, no sound, priority 5. */
const DONE = {
  payload: {
    aps: {
      alert: { title: "Claude · api", body: "Finished" },
      "interruption-level": "passive",
      "thread-id": "block:01a1-b1",
      category: "AGENT_DONE",
    },
    ...PLACE,
    window_id: "window:w1",
  },
  push_type: "alert",
  priority: 5,
  expiration: T0 + 3600,
  collapse_id: "01a1-b1-e40c292c",
};

/** A notice from the terminal: active, with a sound, no collapse id. Its body may be empty. */
const NOTICE = {
  payload: {
    aps: {
      alert: { title: "Deploy", body: "", subtitle: "work" },
      "interruption-level": "active",
      "thread-id": "block:01a1-b1",
      category: "NOTICE",
      sound: "default",
    },
    ...PLACE,
    window_id: "window:w1",
  },
  push_type: "alert",
  priority: 10,
  expiration: T0 + 3600,
};

/** The longest title and body the helper sends (120 and 1000 characters), counted as characters. */
const LONGEST = {
  ...NOTICE,
  payload: { ...NOTICE.payload, aps: { ...NOTICE.payload.aps, alert: { title: "🦖".repeat(120), body: "é".repeat(1000) } } },
};

describe("the payload the helper sends", () => {
  it.each([
    ["a blocked agent", BLOCKED],
    ["a blocked agent without a subtitle or a tab", BLOCKED_BARE],
    ["a blocked agent with the wait it is about", BLOCKED_ACT],
    ["a record id of 128 characters", { ...BLOCKED_ACT, payload: { ...BLOCKED_ACT.payload, record: "é".repeat(128) } }],
    ["a finished agent", DONE],
    ["a notice", NOTICE],
    ["the longest title and body", LONGEST],
  ])("is passed on unchanged for %s", async (_name, body) => {
    const response = await gw.push(device.push_secret, body);
    expect(response.status).toBe(200);
    expect(gw.calls).toHaveLength(1);
    expect(gw.calls[0]?.body).toBe(JSON.stringify(body.payload));
    expect(gw.calls[0]?.headers["apns-priority"]).toBe(String(body.priority));
  });

  it("is what scripts/smoke.sh pushes", async () => {
    const body = /^PUSH_BODY='(.+)'$/m.exec(smokeScript)?.[1] ?? "";
    const response = await gw.request("POST", "/v1/push", { auth: device.push_secret, raw: body });
    expect(response.status).toBe(200);
    expect(gw.calls[0]?.body).toBe(JSON.stringify(JSON.parse(body).payload));
  });

  it("is accepted with every field at its longest", async () => {
    const payload = {
      aps: {
        alert: { title: "t".repeat(120), subtitle: "s".repeat(256), body: "b".repeat(1000) },
        "interruption-level": "active",
        "thread-id": "i".repeat(256),
        category: "NOTICE",
        sound: "default",
      },
      server: "h".repeat(512),
      session_id: "s".repeat(256),
      window_id: "w".repeat(256),
      block_id: "b".repeat(256),
      record: "r".repeat(128),
      fp: "f".repeat(16),
    };
    expect((await gw.push(device.push_secret, { payload, push_type: "alert" })).status).toBe(200);
  });
});

describe("the fields beside the payload", () => {
  const send = (change: Record<string, unknown>): Promise<Response> => gw.push(device.push_secret, { ...BLOCKED, ...change });

  it.each([
    ["the gateway's own time", 0],
    ["an hour from now, as the helper asks", 3600],
    ["an hour by a helper whose clock is a minute ahead", 3660],
    ["an hour by a helper whose clock is a minute behind", 3540],
    ["a minute before now", -60],
  ])("accept an expiration of %s", async (_name, offset) => {
    gw.now = T0 + 500;
    expect((await send({ expiration: gw.now + offset })).status).toBe(200);
    expect(gw.calls[0]?.headers["apns-expiration"]).toBe(String(gw.now + offset));
  });

  it("accept a push without an expiration, a type or a priority, as an alert at priority 10", async () => {
    expect((await gw.push(device.push_secret, { payload: BLOCKED.payload })).status).toBe(200);
    expect(gw.calls[0]?.headers).toMatchObject({ "apns-push-type": "alert", "apns-priority": "10" });
    expect(gw.calls[0]?.headers).not.toHaveProperty("apns-expiration");
  });

  it.each([
    ["an expiration more than an hour and a minute from now", { expiration: T0 + 500 + 3661 }],
    ["an expiration a day from now", { expiration: T0 + 500 + 86400 }],
    ["an expiration more than a minute ago", { expiration: T0 + 500 - 61 }],
    ["an expiration of 0", { expiration: 0 }],
    ["a negative expiration", { expiration: -1 }],
    ["a fractional expiration", { expiration: T0 + 500.5 }],
    ["an expiration that is a string", { expiration: String(T0 + 3600) }],
    ["an expiration that is null", { expiration: null }],
    ["the push type background", { push_type: "background" }],
    ["the push type voip", { push_type: "voip" }],
    ["the push type liveactivity", { push_type: "liveactivity" }],
    ["a push type in another case", { push_type: "Alert" }],
  ])("refuse %s with 400 invalid_request and no D1 call", async (_name, change) => {
    gw.now = T0 + 500;
    const response = await send(change);
    expect(response.status).toBe(400);
    expect((await errorOf(response)).error).toBe("invalid_request");
    expect(log.statements).toEqual([]);
    expect(log.otherCalls).toBe(0);
    expect(gw.calls).toHaveLength(0);
  });

  it("measure the expiration against the gateway's clock at the time of the push", async () => {
    const expiration = T0 + 3600;
    gw.now = T0 + 61;
    expect((await send({ expiration })).status).toBe(200);
    gw.now = T0 + 3661;
    expect((await send({ expiration })).status).toBe(400);
    gw.now = T0 - 61;
    expect((await send({ expiration })).status).toBe(400);
  });
});

describe("anything else in a payload", () => {
  const { payload } = BLOCKED;
  const aps = (change: Record<string, unknown>): unknown => ({ ...payload, aps: { ...payload.aps, ...change } });
  const alert = (change: Record<string, unknown>): unknown => aps({ alert: { ...payload.aps.alert, ...change } });
  const without = <T extends object>(object: T, key: keyof T): Partial<T> => {
    const copy: Partial<T> = { ...object };
    delete copy[key];
    return copy;
  };

  const cases: [string, unknown][] = [
    ["an unknown top-level key", { ...payload, extra: "x" }],
    ["a top-level key of another APNs feature", { ...payload, "apns-topic": "com.example.other" }],
    ["an unknown aps key", aps({ extra: "x" })],
    ["aps.badge", aps({ badge: 1 })],
    ["aps.content-available", aps({ "content-available": 1 })],
    ["aps.mutable-content", aps({ "mutable-content": 1 })],
    ["aps.target-content-id", aps({ "target-content-id": "x" })],
    ["an unknown alert key", alert({ "loc-key": "x" })],
    ["alert.launch-image", alert({ "launch-image": "x" })],

    ["a category the app does not have", aps({ category: "OTHER" })],
    ["a category in another case", aps({ category: "agent_blocked" })],
    ["a category that only starts like one of them", aps({ category: "AGENT_BLOCKED_ACTION" })],
    ["an empty category", aps({ category: "" })],
    ["the interruption level critical", aps({ "interruption-level": "critical" })],
    ["an interruption level in another case", aps({ "interruption-level": "Passive" })],

    ["an alert that is a string", aps({ alert: "Which DB?" })],
    ["an alert that is an array", aps({ alert: ["Which DB?"] })],
    ["a title that is a number", alert({ title: 1 })],
    ["a body that is null", alert({ body: null })],
    ["a subtitle that is an object", alert({ subtitle: { text: "work" } })],
    ["a sound that is an object", aps({ sound: { critical: 1, name: "default", volume: 1 } })],
    ["a category that is an array", aps({ category: ["NOTICE"] })],
    ["an interruption level that is a boolean", aps({ "interruption-level": true })],
    ["a thread id that is a number", aps({ "thread-id": 7 })],
    ["a server that is a number", { ...payload, server: 1 }],
    ["a session id that is null", { ...payload, session_id: null }],
    ["a window id that is an object", { ...payload, window_id: { id: "window:w1" } }],
    ["a block id that is an array", { ...payload, block_id: ["block:01a1-b1"] }],
    ["a record that is a number", { ...payload, record: 7 }],
    ["a fingerprint that is a number", { ...payload, fp: 1234567890123456 }],

    ["a title of 121 characters", alert({ title: "t".repeat(121) })],
    ["a subtitle of 257 characters", alert({ subtitle: "s".repeat(257) })],
    ["a body of 1001 characters", alert({ body: "b".repeat(1001) })],
    ["a sound that is not the default", aps({ sound: "chime.caf" })],
    ["a sound in another case", aps({ sound: "Default" })],
    ["an empty sound", aps({ sound: "" })],
    ["a thread id of 257 characters", aps({ "thread-id": "i".repeat(257) })],
    ["a server of 513 characters", { ...payload, server: "h".repeat(513) }],
    ["a session id of 257 characters", { ...payload, session_id: "s".repeat(257) }],
    ["a window id of 257 characters", { ...payload, window_id: "w".repeat(257) }],
    ["a block id of 257 characters", { ...payload, block_id: "b".repeat(257) }],
    ["a record of 129 characters", { ...payload, record: "r".repeat(129) }],
    ["an empty record", { ...payload, record: "" }],
    ["a record with a control character", { ...payload, record: "claude\u0000" }],
    ["a record with a line break", { ...payload, record: "claude\n2" }],
    ["a fingerprint of 15 characters", { ...payload, fp: "c3a1f0e29b7d465" }],
    ["a fingerprint of 17 characters", { ...payload, fp: "c3a1f0e29b7d46580" }],
    ["a fingerprint in capitals", { ...payload, fp: "C3A1F0E29B7D4658" }],
    ["a fingerprint that is not hex", { ...payload, fp: "g3a1f0e29b7d4658" }],
    ["a fingerprint with a line break after it", { ...payload, fp: "c3a1f0e29b7d4658\n" }],
    ["an empty fingerprint", { ...payload, fp: "" }],
    ["a key beside the record and the fingerprint", { ...payload, record: "claude", fp: "c3a1f0e29b7d4658", action: "enter" }],

    ["no aps", without(payload, "aps")],
    ["an aps that is an array", { ...payload, aps: [payload.aps] }],
    ["an aps that is a string", { ...payload, aps: "x" }],
    ["no alert", { ...payload, aps: without(payload.aps, "alert") }],
    ["no title", aps({ alert: without(payload.aps.alert, "title") })],
    ["no body", aps({ alert: without(payload.aps.alert, "body") })],
    ["an empty payload", {}],
  ];

  it.each(cases)("is refused with 400 invalid_request and no D1 call: %s", async (_name, changed) => {
    const response = await gw.push(device.push_secret, { ...BLOCKED, payload: changed });
    expect(response.status).toBe(400);
    expect((await errorOf(response)).error).toBe("invalid_request");
    expect(log.statements).toEqual([]);
    expect(log.otherCalls).toBe(0);
    expect(gw.calls).toHaveLength(0);
  });

  it("is refused when its name is one every object has", async () => {
    // Written as text, because an object literal would set the prototype instead of a key.
    for (const [where, text] of [
      ["payload", `{"aps":{"alert":{"title":"t","body":"b"}},"__proto__":"x"}`],
      ["aps", `{"aps":{"alert":{"title":"t","body":"b"},"constructor":"x"}}`],
      ["alert", `{"aps":{"alert":{"title":"t","body":"b","toString":"x"}}}`],
    ]) {
      const response = await gw.request("POST", "/v1/push", {
        auth: device.push_secret,
        raw: `{"payload":${text},"push_type":"alert"}`,
      });
      expect(response.status, where).toBe(400);
    }
    expect(log.statements).toEqual([]);
    expect(gw.calls).toHaveLength(0);
  });

  it("does not say what the refused value was", async () => {
    const response = await gw.push(device.push_secret, { ...BLOCKED, payload: aps({ category: "SECRET-WORD" }) });
    expect(await response.text()).not.toContain("SECRET-WORD");
    const record = await gw.push(device.push_secret, { ...BLOCKED, payload: { ...payload, record: "SECRET\u0001WORD" } });
    expect(record.status).toBe(400);
    expect(await record.text()).not.toContain("SECRET");
  });
});
