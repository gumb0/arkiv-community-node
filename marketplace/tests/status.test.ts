// status over a fake chain: each fact from the records, and what it is
// when a record is missing. Run: npm test

import { deepStrictEqual as deepEqual, strictEqual as equal } from "node:assert/strict"
import { describe, it } from "node:test"
import { Entity, addr, i32, key, str, type Attributes } from "@arkiv-network/sdk"
import { stringToBytes, type Hex } from "viem"
import { status } from "../src/commands/status.ts"
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

function record(k: Hex, kind: string, attributes: Record<string, unknown>, payload: object, expiresAt = 5000n, createdAt = 100n, creator: Hex = LB, updatedAt = createdAt): Entity {
  return new Entity({
    key: k,
    creator,
    createdAt,
    updatedAt,
    expiresAt,
    attributes: { kind: str(kind), v: i32(1), ...attributes } as Attributes,
    payload: stringToBytes(JSON.stringify(payload)),
  })
}

const rows: Rows = {
  listing: [record(LISTING, KIND.listing, {}, { wei_per_call: "1000000000000000", tunnel_server: "203.0.113.10:7000", max_providers: 100 })],
  offer: [record(OFFER, KIND.offer, { lb_listing: key(LISTING) }, { specs: {} }, 1000n + 1800n, 100n, ME)],
  agreement: [record(AGREEMENT, KIND.agreement, { provider: addr(ME), offer: key(OFFER) }, { wei_per_call: "1000000000000000", remote_port: 20007 }, 1000n + 129600n)],
  counter: [
    record(COUNTER_OPEN, KIND.counter, { agreement: key(AGREEMENT), provider: addr(ME), state: str("open") }, { count: 48213, wei_per_call: "1000000000000000", opened_block: 900 }, 5000n, 100n, LB, 700n),
    record(COUNTER_CLOSED, KIND.counter, { agreement: key(AGREEMENT), provider: addr(ME), state: str("closed") }, { count: 100, wei_per_call: "1000000000000000", opened_block: 500, closed_block: 900 }),
    record(COUNTER_PAID, KIND.counter, { agreement: key(AGREEMENT), provider: addr(ME), state: str("closed") }, { count: 250, wei_per_call: "1000000000000000", opened_block: 100, closed_block: 500 }),
  ],
  receipt: [
    record(`0x${"e1".repeat(32)}` as Hex, KIND.receipt, { counter: key(COUNTER_PAID), provider: addr(ME) }, {
      agreement: AGREEMENT, count: 250, wei_per_call: "1000000000000000", amount_wei: "250000000000000000",
      payout: { chain_id: 560048, tx: "0x925d33c7" },
    }, 5000n, 100n, SETTLE),
  ],
  taken: 7,
}

type Tunnel = { agreement?: string; port?: number } | undefined

const TUNNEL: Tunnel = { agreement: AGREEMENT, port: 20007 }

async function facts(rows: Rows, settle: Hex, tunnel: Tunnel, settlePrevious: Hex[] = []) {
  return status({ reader: fakeChain(rows).reader, lb: LB, settle, settlePrevious, me: ME, tunnel })
}

describe("status", () => {
  it("reads every fact from the records", async () => {
    deepEqual(await facts(rows, SETTLE, TUNNEL), {
      address: ME,
      balance_glm: "1",
      listing_glm_per_request: "0.001",
      listing_slots_taken: 7,
      listing_max_providers: 100,
      offer_key: OFFER,
      offer_expires_in_seconds: 3600,
      agreement_key: AGREEMENT,
      agreement_port: 20007,
      agreement_glm_per_request: "0.001",
      agreement_expires_in_seconds: 259200,
      tunnel_state: "current",
      tunnel_agreement: AGREEMENT,
      tunnel_port: 20007,
      count: 48213,
      count_written_seconds_ago: 600,
      count_opened_seconds_ago: 1800,
      count_opened_block: 900,
      count_record: COUNTER_OPEN,
      awaiting_records: 1,
      awaiting_requests: 100,
      payouts_receipts: 1,
      payouts_total_glm: "0.25",
      payouts_last_tx: "0x925d33c7",
      payouts_last_chain_id: 560048,
      next: null,
    })
  })

  it("is null where a record is missing", async () => {
    const out = await facts({ balance: 0n }, SETTLE, undefined)
    equal(out.balance_glm, "0")
    equal(out.listing_max_providers, null)
    equal(out.listing_slots_taken, null)
    equal(out.next, "no-listing")
    equal(out.offer_key, null)
    equal(out.agreement_key, null)
    equal(out.tunnel_state, "unconfigured")
    equal(out.count, null)
    equal(out.awaiting_records, 0)
    equal(out.payouts_receipts, 0)
    equal(out.payouts_total_glm, null)
  })

  it("names the next step towards serving, in the order of the steps", async () => {
    equal((await facts(rows, SETTLE, TUNNEL)).next, null)
    equal((await facts(rows, SETTLE, undefined)).next, "start-tunnel")
    equal((await facts(rows, SETTLE, { agreement: `0x${"77".repeat(32)}`, port: 20007 })).next, "start-tunnel")
    equal((await facts({ ...rows, agreement: [] }, SETTLE, TUNNEL)).next, "acceptance", "an offer waits for acceptance, whatever the tunnel was set up for")
    equal((await facts({ ...rows, agreement: [], offer: [] }, SETTLE, undefined)).next, "post-offer")
    equal((await facts({ ...rows, agreement: [], offer: [], balance: 0n }, SETTLE, undefined)).next, "fund")
    equal((await facts({ ...rows, balance: 0n }, SETTLE, TUNNEL)).next, null, "an agreement needs no gas")
    equal((await facts({ ...rows, agreement: [], listing: [] }, SETTLE, undefined)).next, "no-listing", "no offer is accepted without a listing")
    equal((await facts({ ...rows, listing: [] }, SETTLE, TUNNEL)).next, null, "an agreement outlives the listing")
  })

  it("tells whose agreement the tunnel is set up for", async () => {
    equal((await facts(rows, SETTLE, undefined)).tunnel_state, "unconfigured")
    const other = `0x${"9d".repeat(32)}`
    equal((await facts(rows, SETTLE, { agreement: other, port: 20007 })).tunnel_state, "other")
    equal((await facts(rows, SETTLE, { agreement: AGREEMENT, port: 20001 })).tunnel_state, "other", "the port counts too")
    equal((await facts(rows, SETTLE, { agreement: AGREEMENT.toUpperCase().replace("0X", "0x"), port: 20007 })).tunnel_state, "current", "case is no difference")
    // The agreement record expired while the tunnel kept running: the
    // tunnel is connected but nothing is counted or paid for it.
    const ended = await facts({ ...rows, agreement: [] }, SETTLE, TUNNEL)
    equal(ended.agreement_key, null)
    equal(ended.tunnel_state, "ended")
    equal(ended.tunnel_agreement, AGREEMENT)
  })

  it("closed records without a receipt await payout, paid ones do not", async () => {
    const out = await facts({ ...rows, receipt: [] }, SETTLE, TUNNEL)
    equal(out.awaiting_records, 2)
    equal(out.awaiting_requests, 350)
    equal(out.payouts_receipts, 0)
    equal(out.payouts_last_tx, null)
  })

  it("counts a receipt of a previous settle key as a payout, and a stranger's for nothing", async () => {
    // The settle key was rotated: the old key's receipts still say what
    // was paid. A receipt anyone else wrote says nothing.
    const previous = "0x8888888888888888888888888888888888888888" as Hex
    const stranger = "0x9999999999999999999999999999999999999999" as Hex
    const byPrevious = record(`0x${"e2".repeat(32)}` as Hex, KIND.receipt, { counter: key(COUNTER_CLOSED), provider: addr(ME) }, {
      agreement: AGREEMENT, count: 100, wei_per_call: "1000000000000000", amount_wei: "100000000000000000",
      payout: { chain_id: 560048, tx: "0x0ddba11" },
    }, 5000n, 200n, previous)
    const byStranger = record(`0x${"e3".repeat(32)}` as Hex, KIND.receipt, { counter: key(COUNTER_CLOSED), provider: addr(ME) }, {
      agreement: AGREEMENT, count: 100, wei_per_call: "1000000000000000", amount_wei: "100000000000000000",
      payout: { chain_id: 560048, tx: "0xbad" },
    }, 5000n, 300n, stranger)
    const withPrevious = { ...rows, receipt: [...rows.receipt!, byPrevious, byStranger] }

    const out = await facts(withPrevious, SETTLE, TUNNEL, [previous])
    equal(out.awaiting_records, 0)
    equal(out.payouts_receipts, 2)
    equal(out.payouts_total_glm, "0.35")
    equal(out.payouts_last_tx, "0x0ddba11")

    const without = await facts(withPrevious, SETTLE, TUNNEL)
    equal(without.awaiting_records, 1, "an unlisted key's receipt is nobody's")
    equal(without.awaiting_requests, 100)

    // A list that repeats an address, or names the current key, counts
    // each receipt once.
    const repeated = await facts(withPrevious, SETTLE, TUNNEL, [previous, previous, SETTLE])
    equal(repeated.payouts_receipts, 2)
    equal(repeated.payouts_total_glm, "0.35")
  })

  it("has no last write for a record the load balancer has not written since opening it", async () => {
    const fresh = record(COUNTER_OPEN, KIND.counter, { agreement: key(AGREEMENT), provider: addr(ME), state: str("open") }, { count: 0, wei_per_call: "1000000000000000", opened_block: 900 }, 5000n, 900n)
    const out = await facts({ ...rows, counter: [fresh] }, SETTLE, TUNNEL)
    equal(out.count, 0)
    equal(out.count_written_seconds_ago, null)
    equal(out.count_opened_seconds_ago, 200)
    const zero = record(COUNTER_OPEN, KIND.counter, { agreement: key(AGREEMENT), provider: addr(ME), state: str("open") }, { count: 0, wei_per_call: "1000000000000000", opened_block: 900 }, 5000n, 900n, LB, 950n)
    equal((await facts({ ...rows, counter: [zero] }, SETTLE, TUNNEL)).count_written_seconds_ago, 100, "a 0 the load balancer wrote is news")
  })
})
