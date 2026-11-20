import { env, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { DAY } from "../src/limits";
import { LEASE_WRITES_PER_DAY, MAX_LEASES, type Presence } from "../src/presence";
import { T0 } from "./helpers";

/** The Durable Object on its own, through its RPC methods, as the Worker calls it. */

let phones = 0;
/** A phone of its own for every test, so no test sees another's leases. */
function phone(): DurableObjectStub<Presence> {
  const namespace = env.PRESENCE_DO;
  if (!namespace) throw new Error("wrangler.toml lost the PRESENCE_DO binding");
  return namespace.get(namespace.idFromName(`phone:test-${phones++}-${crypto.randomUUID()}`));
}

/** A well-formed tag of its own for every `n`. */
function tag(n: number): string {
  return `tag${String(n).padStart(19, "0")}`;
}

async function stored(stub: DurableObjectStub<Presence>): Promise<{ keys: string[]; alarm: number | null }> {
  return runInDurableObject(stub, async (_instance, state) => ({
    keys: [...(await state.storage.list()).keys()],
    alarm: await state.storage.getAlarm(),
  }));
}

/** Adds `writes` to the day's count in the object's own state, as that many leases would. */
async function spend(stub: DurableObjectStub<Presence>, writes: number): Promise<void> {
  await runInDurableObject(stub, async (_instance, state) => {
    const value = await state.storage.get<{ writes: number }>("state");
    if (!value) throw new Error("no state to add to");
    await state.storage.put("state", { ...value, writes: value.writes + writes });
  });
}

describe("the presence Durable Object", () => {
  it("holds nothing for a phone that never had a lease, and writes nothing to say so", async () => {
    const stub = phone();
    expect(await stub.holds([tag(1)], T0)).toBe(false);
    expect(await stored(stub)).toEqual({ keys: [], alarm: null });
  });

  it("holds for a tag until its lease ends, and only for that tag", async () => {
    const stub = phone();
    expect(await stub.lease(tag(1), 600, T0)).toEqual({ stored: true });
    expect(await stub.holds([tag(1)], T0)).toBe(true);
    expect(await stub.holds([tag(2), tag(1)], T0 + 599)).toBe(true);
    expect(await stub.holds([tag(2)], T0)).toBe(false);
    expect(await stub.holds([], T0)).toBe(false);
    // At `until` the lease has ended.
    expect(await stub.holds([tag(1)], T0 + 600)).toBe(false);
  });

  it("renews a tag in place: a later lease moves its end, and the alarm with it", async () => {
    const stub = phone();
    await stub.lease(tag(1), 600, T0);
    await stub.lease(tag(1), 600, T0 + 300);
    expect(await stub.holds([tag(1)], T0 + 899)).toBe(true);
    expect((await stored(stub)).alarm).toBe((T0 + 900) * 1000);
  });

  it("removes only its own tag with ttl 0", async () => {
    const stub = phone();
    await stub.lease(tag(1), 600, T0);
    await stub.lease(tag(2), 600, T0);
    expect(await stub.lease(tag(1), 0, T0 + 10)).toEqual({ stored: true });
    expect(await stub.holds([tag(1)], T0 + 10)).toBe(false);
    expect(await stub.holds([tag(2)], T0 + 10)).toBe(true);
  });

  it("writes nothing to remove a tag it does not hold", async () => {
    const stub = phone();
    expect(await stub.lease(tag(1), 0, T0)).toEqual({ stored: true });
    expect(await stored(stub)).toEqual({ keys: [], alarm: null });
  });

  it(`holds at most ${MAX_LEASES} leases: a new tag takes the place of the one closest to its end`, async () => {
    const stub = phone();
    await stub.lease(tag(1), 900, T0);
    await stub.lease(tag(2), 100, T0); // ends first
    await stub.lease(tag(3), 800, T0);
    await stub.lease(tag(4), 700, T0);
    await stub.lease(tag(5), 600, T0);
    expect(await stub.holds([tag(2)], T0 + 50)).toBe(false);
    for (const n of [1, 3, 4, 5]) expect(await stub.holds([tag(n)], T0 + 50)).toBe(true);
  });

  it("drops leases that have ended before it counts the room left", async () => {
    const stub = phone();
    for (const n of [1, 2, 3, 4]) await stub.lease(tag(n), 60, T0);
    await stub.lease(tag(5), 600, T0 + 120);
    await stub.lease(tag(6), 600, T0 + 120);
    expect(await stub.holds([tag(5)], T0 + 121)).toBe(true);
    expect(await stub.holds([tag(6)], T0 + 121)).toBe(true);
  });

  it("sets one alarm at the latest end, which deletes every lease, then the day's count at the end of the day", async () => {
    const stub = phone();
    await stub.lease(tag(1), 600, T0);
    await stub.lease(tag(2), 300, T0);
    expect((await stored(stub)).alarm).toBe((T0 + 600) * 1000);

    expect(await runDurableObjectAlarm(stub)).toBe(true);
    expect(await stub.holds([tag(1), tag(2)], T0)).toBe(false);
    // Only the count of writes is left, without a tag, until the day is over.
    const between = await runInDurableObject(stub, async (_instance, state) => ({
      value: await state.storage.get("state"),
      alarm: await state.storage.getAlarm(),
    }));
    expect(between.value).toEqual({ leases: [], day: T0 / DAY, writes: 2, wake: T0 + DAY });
    expect(between.alarm).toBe((T0 + DAY) * 1000);

    expect(await runDurableObjectAlarm(stub)).toBe(true);
    expect(await stored(stub)).toEqual({ keys: [], alarm: null });
  });

  it("deletes everything at once when the last lease is removed on a day it wrote nothing new", async () => {
    const stub = phone();
    await stub.lease(tag(1), 600, T0);
    // The next day: the count of the day before no longer applies.
    expect(await stub.lease(tag(1), 0, T0 + DAY)).toEqual({ stored: true });
    expect(await stored(stub)).toEqual({ keys: [], alarm: null });
  });

  it(`writes at most ${LEASE_WRITES_PER_DAY} leases a day, still removes, and writes again the next day`, async () => {
    const stub = phone();
    for (let i = 0; i < 3; i++) expect(await stub.lease(tag(i), 600, T0 + i)).toEqual({ stored: true });
    // The rest of the day's writes, counted as the object counts them, without 1,500 calls.
    await spend(stub, LEASE_WRITES_PER_DAY - 4);
    // The last write of the day.
    expect(await stub.lease(tag(2), 600, T0 + 10)).toEqual({ stored: true });
    const late = T0 + 20;
    expect(await stub.lease(tag(1), 600, late)).toEqual({ stored: false, retryAfter: T0 + DAY - late });
    // A removal only ever lets a push through, so the cap never refuses one.
    expect(await stub.lease(tag(1), 0, late)).toEqual({ stored: true });
    expect(await stub.holds([tag(1)], late)).toBe(false);
    expect(await stub.lease(tag(1), 600, T0 + DAY)).toEqual({ stored: true });
  });

  it("keeps the day's count when its leases run out, so letting them end starts no new count", async () => {
    const stub = phone();
    await stub.lease(tag(1), 1, T0);
    await spend(stub, LEASE_WRITES_PER_DAY - 1);
    await runDurableObjectAlarm(stub);
    expect(await stub.holds([tag(1)], T0 + 5)).toBe(false);
    expect(await stub.lease(tag(1), 600, T0 + 10)).toMatchObject({ stored: false });
  });
});
