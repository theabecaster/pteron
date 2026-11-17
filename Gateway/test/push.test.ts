import { beforeEach, describe, expect, it } from "vitest";
import {
  Gateway,
  PAYLOAD,
  PRODUCTION_TOKEN,
  SANDBOX_TOKEN,
  T0,
  appleError,
  deviceRows,
  errorOf,
  reset,
  secretRows,
} from "./helpers";

let gw: Gateway;
beforeEach(async () => {
  await reset();
  gw = new Gateway();
});

const bytesOf = (value: unknown): number => new TextEncoder().encode(JSON.stringify(value)).byteLength;

/**
 * A payload whose JSON is exactly `bytes` long in UTF-8. Up to 4100 bytes every field is
 * within its own length limit, so only the size decides.
 */
function payloadOfSize(bytes: number): Record<string, unknown> {
  const build = (server: string): Record<string, unknown> => ({
    aps: { alert: { title: "Claude · api", body: "€".repeat(1000) }, "thread-id": "b".repeat(256), category: "NOTICE" },
    server,
    session_id: "s".repeat(256),
    block_id: "b".repeat(256),
  });
  return build("x".repeat(bytes - bytesOf(build(""))));
}

describe("POST /v1/push", () => {
  it("sends to the sandbox host with the forced topic and the payload unchanged", async () => {
    const device = await gw.register(SANDBOX_TOKEN, "sandbox");
    const response = await gw.push(device.push_secret, {
      payload: PAYLOAD,
      push_type: "alert",
      priority: 10,
      collapse_id: "01a1-b1-e40c292c",
      expiration: T0 + 3600,
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ apns_id: "11111111-2222-3333-4444-555555555555" });

    expect(gw.calls).toHaveLength(1);
    const call = gw.calls[0];
    expect(call?.url).toBe(`https://api.sandbox.push.apple.com/3/device/${SANDBOX_TOKEN}`);
    expect(call?.method).toBe("POST");
    expect(call?.headers).toEqual({
      authorization: expect.stringMatching(/^bearer [\w-]+\.[\w-]+\.[\w-]+$/),
      "apns-topic": "dev.abrahamgonzalez.rexduo",
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-collapse-id": "01a1-b1-e40c292c",
      "apns-expiration": String(T0 + 3600),
      "content-type": "application/json",
    });
    expect(call?.body).toBe(JSON.stringify(PAYLOAD));
  });

  it("sends to the production host for a production device", async () => {
    const device = await gw.register(PRODUCTION_TOKEN, "production");
    expect((await gw.push(device.push_secret)).status).toBe(200);
    expect(gw.calls[0]?.url).toBe(`https://api.push.apple.com/3/device/${PRODUCTION_TOKEN.toLowerCase()}`);
  });

  it("defaults the type to alert and the priority to 10, and omits absent headers", async () => {
    const device = await gw.register();
    await gw.push(device.push_secret, { payload: PAYLOAD });
    await gw.push(device.push_secret, { payload: PAYLOAD, push_type: "alert" });
    await gw.push(device.push_secret, { payload: PAYLOAD, push_type: "alert", priority: 5, expiration: T0 });
    expect(gw.calls.map((c) => [c.headers["apns-push-type"], c.headers["apns-priority"]])).toEqual([
      ["alert", "10"],
      ["alert", "10"],
      ["alert", "5"],
    ]);
    expect(gw.calls[0]?.headers).not.toHaveProperty("apns-collapse-id");
    expect(gw.calls[0]?.headers).not.toHaveProperty("apns-expiration");
    expect(gw.calls[2]?.headers["apns-expiration"]).toBe(String(T0));
  });

  it("gives the caller no way to choose the host, the topic or the token", async () => {
    const device = await gw.register();
    const response = await gw.request("POST", "/v1/push?topic=com.evil&host=evil.example", {
      auth: device.push_secret,
      headers: { "apns-topic": "com.evil", host: "evil.example" },
      body: {
        payload: PAYLOAD,
        push_type: "alert",
        topic: "com.evil",
        "apns-topic": "com.evil",
        host: "evil.example",
        environment: "production",
        apns_token: "ff".repeat(32),
        token: "ff".repeat(32),
        device_id: "other",
      },
    });
    expect(response.status).toBe(200);
    expect(gw.calls[0]?.url).toBe(`https://api.sandbox.push.apple.com/3/device/${SANDBOX_TOKEN}`);
    expect(gw.calls[0]?.headers["apns-topic"]).toBe("dev.abrahamgonzalez.rexduo");
    expect(gw.calls[0]?.body).toBe(JSON.stringify(PAYLOAD));
  });

  it("answers an empty apns_id when Apple sends none", async () => {
    const device = await gw.register();
    gw.apple = () => new Response(null, { status: 200 });
    expect(await (await gw.push(device.push_secret)).json()).toEqual({ apns_id: "" });
  });

  it("answers the same 401 for an unknown, missing or malformed secret, without calling Apple", async () => {
    const device = await gw.register();
    const body = { payload: PAYLOAD, push_type: "alert" };
    const answers = [
      await gw.request("POST", "/v1/push", { auth: "B".repeat(43), body }),
      await gw.request("POST", "/v1/push", { body }),
      await gw.request("POST", "/v1/push", { auth: "not a secret", body }),
      await gw.request("POST", "/v1/push", { headers: { authorization: `Basic ${device.push_secret}` }, body }),
      // The owner key manages the device. It does not push.
      await gw.request("POST", "/v1/push", { auth: device.owner_key, body }),
    ];
    const bodies = new Set<string>();
    for (const answer of answers) {
      expect(answer.status).toBe(401);
      bodies.add(await answer.text());
    }
    expect(bodies.size).toBe(1);
    expect(gw.calls).toHaveLength(0);
  });

  it("accepts a payload of exactly 4096 bytes and answers 413 for one byte more", async () => {
    const device = await gw.register();
    const largest = payloadOfSize(4096);
    expect((largest.server as string).length).toBeLessThan(500);
    expect((await gw.push(device.push_secret, { payload: largest, push_type: "alert" })).status).toBe(200);
    expect(new TextEncoder().encode(gw.calls[0]?.body).byteLength).toBe(4096);

    const response = await gw.push(device.push_secret, { payload: payloadOfSize(4097), push_type: "alert" });
    expect(response.status).toBe(413);
    expect((await errorOf(response)).error).toBe("payload_too_large");
    expect(gw.calls).toHaveLength(1);
  });

  it("measures the payload in bytes, not characters", async () => {
    const device = await gw.register();
    // Every field is within its limit in characters: 1000 of three bytes each, 512 of two.
    const payload = { ...PAYLOAD, aps: { alert: { title: "t", body: "€".repeat(1000) } }, server: "é".repeat(512) };
    expect(JSON.stringify(payload).length).toBeLessThan(4096);
    expect(bytesOf(payload)).toBeGreaterThan(4096);
    const response = await gw.push(device.push_secret, { payload, push_type: "alert" });
    expect(response.status).toBe(413);
    expect(gw.calls).toHaveLength(0);
  });

  it("answers 413 for a body over 8 KB, by Content-Length and by what is actually read", async () => {
    const device = await gw.register();
    const big = JSON.stringify({ payload: payloadOfSize(9000), push_type: "alert" });
    const declared = await gw.request("POST", "/v1/push", {
      auth: device.push_secret,
      raw: "{}",
      headers: { "content-length": "9000" },
    });
    expect(declared.status).toBe(413);

    // A streamed body has no Content-Length, so only the bounded read can stop it.
    const chunk = new TextEncoder().encode(big.slice(0, 3000));
    let sent = 0;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (sent++ < 1000) controller.enqueue(chunk);
        else controller.close();
      },
    });
    const streamed = await gw.request("POST", "/v1/push", { auth: device.push_secret, raw: stream });
    expect(streamed.status).toBe(413);
    expect((await errorOf(streamed)).error).toBe("payload_too_large");
    // It stopped at the limit instead of draining three megabytes.
    expect(sent).toBeLessThan(10);
    expect(gw.calls).toHaveLength(0);
  });

  it.each([
    ["voip", { payload: PAYLOAD, push_type: "voip" }],
    ["background", { payload: PAYLOAD, push_type: "background" }],
    ["liveactivity", { payload: PAYLOAD, push_type: "liveactivity" }],
    ["a push type that is not a string", { payload: PAYLOAD, push_type: 1 }],
    ["an array payload", { payload: [1, 2], push_type: "alert" }],
    ["a string payload", { payload: JSON.stringify(PAYLOAD), push_type: "alert" }],
    ["a null payload", { payload: null, push_type: "alert" }],
    ["no payload", { push_type: "alert" }],
    ["priority 7", { payload: PAYLOAD, push_type: "alert", priority: 7 }],
    ["a string priority", { payload: PAYLOAD, push_type: "alert", priority: "10" }],
    ["a collapse id over 64 bytes", { payload: PAYLOAD, push_type: "alert", collapse_id: "c".repeat(65) }],
    ["an empty collapse id", { payload: PAYLOAD, push_type: "alert", collapse_id: "" }],
    ["a collapse id with a line break", { payload: PAYLOAD, push_type: "alert", collapse_id: "a\r\nx: y" }],
    ["a collapse id that is not ASCII", { payload: PAYLOAD, push_type: "alert", collapse_id: "é" }],
    ["a negative expiration", { payload: PAYLOAD, push_type: "alert", expiration: -1 }],
    ["a fractional expiration", { payload: PAYLOAD, push_type: "alert", expiration: T0 + 1.5 }],
    ["an expiration two hours away", { payload: PAYLOAD, push_type: "alert", expiration: T0 + 7200 }],
    ["a body that is an array", [PAYLOAD]],
  ])("answers 400 for %s", async (_name, body) => {
    const device = await gw.register();
    const response = await gw.push(device.push_secret, body);
    expect(response.status).toBe(400);
    expect((await errorOf(response)).error).toBe("invalid_request");
    expect(gw.calls).toHaveLength(0);
  });

  it("accepts a collapse id of exactly 64 bytes", async () => {
    const device = await gw.register();
    const id = "c".repeat(64);
    expect((await gw.push(device.push_secret, { payload: PAYLOAD, push_type: "alert", collapse_id: id })).status).toBe(
      200,
    );
    expect(gw.calls[0]?.headers["apns-collapse-id"]).toBe(id);
  });

  it("answers 400 for a body that is not JSON or not UTF-8", async () => {
    const device = await gw.register();
    for (const raw of ["{nope", "", new Uint8Array([0x7b, 0xff, 0xfe, 0x7d])]) {
      const response = await gw.request("POST", "/v1/push", { auth: device.push_secret, raw });
      expect(response.status).toBe(400);
      expect((await errorOf(response)).error).toBe("invalid_request");
    }
  });

  it.each([
    [410, "Unregistered"],
    [410, "ExpiredToken"],
    [400, "BadDeviceToken"],
    [400, "DeviceTokenNotForTopic"],
  ])("answers 410 and marks the device dead when Apple says %i %s", async (status, reason) => {
    const device = await gw.register();
    const second = await gw.mint(device, "laptop");
    const third = await gw.mint(device, "laptop");
    const other = await gw.register(PRODUCTION_TOKEN, "production");
    gw.apple = appleError(status, reason);
    const response = await gw.push(second.push_secret);
    expect(response.status).toBe(410);
    expect(await errorOf(response)).toMatchObject({ error: "unregistered", reason });
    const rows = await deviceRows();
    expect(rows).toHaveLength(2);
    expect(rows.find((row) => row.device_id === device.device_id)).toMatchObject({ dead: 1, push_count: 1 });
    expect(rows.find((row) => row.device_id === other.device_id)).toMatchObject({ dead: 0 });
    expect(await secretRows()).toHaveLength(4);

    // Every secret of that phone stops with it, not only the one that pushed, and Apple is
    // not asked again.
    gw.apple = () => new Response(null, { status: 200 });
    for (const secret of [device.push_secret, second.push_secret, third.push_secret]) {
      const later = await gw.push(secret);
      expect(later.status).toBe(410);
      expect((await errorOf(later)).error).toBe("unregistered");
    }
    expect(gw.calls).toHaveLength(1);
    expect((await gw.push(other.push_secret)).status).toBe(200);
  });

  it.each([
    [500, "InternalServerError"],
    [503, "ServiceUnavailable"],
    [429, "TooManyRequests"],
    [400, "BadCollapseId"],
    [403, "BadCertificateEnvironment"],
  ])("answers 502 with Apple's status and reason for %i %s, and keeps the device", async (status, reason) => {
    const device = await gw.register();
    gw.apple = appleError(status, reason);
    const response = await gw.push(device.push_secret);
    expect(response.status).toBe(502);
    expect(await errorOf(response)).toMatchObject({ error: "apns_error", status, reason });
    expect(await deviceRows()).toHaveLength(1);
  });

  it("answers 502 with an empty reason when Apple's error body is not what it documents", async () => {
    const device = await gw.register();
    gw.apple = () => new Response("<html>bad gateway</html>", { status: 502 });
    const response = await gw.push(device.push_secret);
    expect(await errorOf(response)).toMatchObject({ error: "apns_error", status: 502, reason: "" });
  });

  it("answers 502 apns_unreachable when the request to Apple throws", async () => {
    const device = await gw.register();
    gw.apple = () => {
      throw new TypeError("Network connection lost.");
    };
    const response = await gw.push(device.push_secret);
    expect(response.status).toBe(502);
    expect((await errorOf(response)).error).toBe("apns_unreachable");
    expect(await deviceRows()).toHaveLength(1);
  });

  it("counts the pushes of all a device's secrets on the device's row", async () => {
    const device = await gw.register();
    gw.now = T0 + 1;
    const second = await gw.mint(device, "laptop");
    for (let i = 0; i < 3; i++) await gw.push(device.push_secret);
    await gw.push(second.push_secret);
    expect(await deviceRows()).toMatchObject([{ device_id: device.device_id, push_day: T0 / 86400, push_count: 4 }]);
    // Both reach the same phone.
    expect(new Set(gw.calls.map((c) => c.url)).size).toBe(1);
  });
});
