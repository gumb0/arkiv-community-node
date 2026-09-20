// status over a fake chain: each line from the records, and what it
// says when a record is missing. Run: npm test

import { deepStrictEqual as deepEqual, strictEqual as equal, match } from "node:assert/strict"
import { describe, it } from "node:test"
import { Entity, addr, i32, key, str, type Attributes } from "@arkiv-network/sdk"
import { stringToBytes, type Hex } from "viem"
import { status, timeLeft } from "../src/commands/status.ts"
import { KIND } from "../src/records.ts"
import { fakeChain, type Rows } from "./chain.ts"

const LB = "0xCA4B166EE155Cb2816Dc25f94Dc1fD102a26c997" as Hex
const SETTLE = "0x411E31d7eBbfd636Af234954db5f598Cd80a878C" as Hex
const ME = "0x2121212121212121212121212121212121212121" as Hex
const LISTING = `0x${"a1".repeat(32)}` as Hex
const OFFER = `0x${"0f".repeat(32)}` as Hex
const AGREEMENT = `0x${"9c".repeat(32)}` as Hex
const COUNTER_OPEN = `0x${"c1".repeat(32)}` as Hex
const COUNTER_CLOSED = `0x${"c2".repeat(32)}` as Hex
const COUNTER_PAID = `0x${"c3".repeat(32)}` as Hex

function record(k: Hex, kind: string, attributes: Record<string, unknown>, payload: object, expiresAt = 5000n, createdAt = 100n): Entity {
  return new Entity({
    key: k,
    creator: LB,
    createdAt,
    expiresAt,
    attributes: { kind: str(kind), v: i32(1), ...attributes } as Attributes,
    payload: stringToBytes(JSON.stringify(payload)),
  })
}

const rows: Rows = {
  listing: [record(LISTING, KIND.listing, {}, { wei_per_call: "1000000000000000", tunnel_server: "203.0.113.10:7000", max_providers: 100 })],
  offer: [record(OFFER, KIND.offer, { lb_listing: key(LISTING) }, { specs: {} }, 1000n + 1800n)],
  agreement: [record(AGREEMENT, KIND.agreement, { provider: addr(ME), offer: key(OFFER) }, { wei_per_call: "1000000000000000", remote_port: 20007 }, 1000n + 129600n)],
  counter: [
    record(COUNTER_OPEN, KIND.counter, { agreement: key(AGREEMENT), provider: addr(ME), state: str("open") }, { count: 48213, wei_per_call: "1000000000000000", opened_block: 900 }),
    record(COUNTER_CLOSED, KIND.counter, { agreement: key(AGREEMENT), provider: addr(ME), state: str("closed") }, { count: 100, wei_per_call: "1000000000000000", opened_block: 500, closed_block: 900 }),
    record(COUNTER_PAID, KIND.counter, { agreement: key(AGREEMENT), provider: addr(ME), state: str("closed") }, { count: 250, wei_per_call: "1000000000000000", opened_block: 100, closed_block: 500 }),
  ],
  receipt: [
    record(`0x${"e1".repeat(32)}` as Hex, KIND.receipt, { counter: key(COUNTER_PAID), provider: addr(ME) }, {
      agreement: AGREEMENT, count: 250, wei_per_call: "1000000000000000", amount_wei: "250000000000000000",
      payout: { chain_id: 560048, tx: "0x925d33c7" },
    }),
  ],
  taken: 7,
}

type Tunnel = { agreement?: string; port?: number } | undefined

const TUNNEL: Tunnel = { agreement: AGREEMENT, port: 20007 }

async function lines(rows: Rows, settle: Hex | undefined, tunnel: Tunnel): Promise<string[]> {
  const out: string[] = []
  await status({ reader: fakeChain(rows).reader, lb: LB, settle, me: ME, tunnel, print: (line) => out.push(line) })
  return out
}

describe("status", () => {
  it("reads every line from the records", async () => {
    const out = await lines(rows, SETTLE, TUNNEL)
    deepEqual(out, [
      `Key: ${ME}, 1 GLM for gas on the Arkiv chain`,
      "Load balancer: pays 0.001 GLM per request, 7 of 100 slots taken",
      `Offer: ${OFFER}, expires in about 60 minutes`,
      `Agreement: ${AGREEMENT}, tunnel port 20007, 0.001 GLM per request, expires in about 3 days`,
      "Tunnel: configured for this agreement",
      `Counting: 48213 requests since block 900 (record ${COUNTER_OPEN})`,
      "Awaiting payout: 1 closed record, 100 requests",
      "Payouts: 1 receipt, 0.25 GLM in total; last transfer 0x925d33c7 on chain 560048",
    ])
  })

  it("says what is missing", async () => {
    const out = await lines({ balance: 0n }, undefined, undefined)
    match(out[0]!, /0 GLM for gas on the Arkiv chain/)
    match(out[1]!, /no listing from/)
    equal(out[2], "Offer: none")
    equal(out[3], "Agreement: none")
    equal(out[4], "Counting: no open record", "no tunnel line without an agreement")
    equal(out[5], "Awaiting payout: nothing")
    equal(out[6], "Payouts: no settle address is shipped for this chain yet")
  })

  it("says when the tunnel is not the agreement's", async () => {
    const notStarted = await lines(rows, SETTLE, undefined)
    equal(notStarted[4], "Tunnel: not started yet: run start-tunnel")
    const other = `0x${"9d".repeat(32)}`
    const stale = await lines(rows, SETTLE, { agreement: other, port: 20007 })
    equal(stale[4], `Tunnel: configured for agreement ${other} on port 20007, not for this one: run start-tunnel again`)
    const wrongPort = await lines(rows, SETTLE, { agreement: AGREEMENT, port: 20001 })
    equal(wrongPort[4], `Tunnel: configured for agreement ${AGREEMENT} on port 20001, not for this one: run start-tunnel again`)
    const upper = await lines(rows, SETTLE, { agreement: AGREEMENT.toUpperCase().replace("0X", "0x"), port: 20007 })
    equal(upper[4], "Tunnel: configured for this agreement", "case is no difference")
  })

  it("closed records without a receipt await payout, paid ones do not", async () => {
    const out = await lines({ ...rows, receipt: [] }, SETTLE, TUNNEL)
    equal(out[6], "Awaiting payout: 2 closed records, 350 requests")
    equal(out[7], "Payouts: none yet")
  })

  it("words a wait", () => {
    equal(timeLeft(0), "now")
    equal(timeLeft(90), "in about 2 minutes")
    equal(timeLeft(3600), "in about 60 minutes")
    equal(timeLeft(2 * 3600), "in about 2 hours", "hours from two on")
    equal(timeLeft(3 * 3600), "in about 3 hours")
    equal(timeLeft(47 * 3600), "in about 47 hours")
    equal(timeLeft(2 * 86400), "in about 2 days", "days from two on")
    equal(timeLeft(3 * 86400), "in about 3 days")
  })
})
