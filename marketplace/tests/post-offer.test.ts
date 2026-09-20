// post-offer over a fake node and a fake chain: every refusal, and the
// offer it posts when nothing refuses. Run: npm test

import { deepStrictEqual as deepEqual, strictEqual as equal, match, ok } from "node:assert/strict"
import { describe, it } from "node:test"
import { Entity, addr, i32, key, str, type Attributes } from "@arkiv-network/sdk"
import { bytesToString, stringToBytes, type Hex } from "viem"
import type { NodeFacts } from "../src/node.ts"
import { OFFER_DAYS, postOffer } from "../src/commands/post-offer.ts"
import { KIND } from "../src/records.ts"
import { fakeChain } from "./chain.ts"

const LB = "0xCA4B166EE155Cb2816Dc25f94Dc1fD102a26c997" as Hex
const ME = "0x2121212121212121212121212121212121212121" as Hex
const LISTING = `0x${"a1".repeat(32)}` as Hex
const OFFER = `0x${"0f".repeat(32)}` as Hex
const AGREEMENT = `0x${"9c".repeat(32)}` as Hex

const node: NodeFacts = {
  specs: { chain_id: 7738577, head: 1000, el: "arkiv-reth/v0.2.0", cl: "lighthouse/v8.2.1", hw: { cpus: 8, mem_gb: 32 } },
  syncing: false,
}

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

const listing = (k = LISTING, createdAt = 100n, expiresAt = 5000n) =>
  record(k, KIND.listing, {}, { wei_per_call: "1000000000000000", tunnel_server: "203.0.113.10:7000", max_providers: 100 }, expiresAt, createdAt)
const myAgreement = () => record(AGREEMENT, KIND.agreement, { provider: addr(ME), offer: key(OFFER) }, { wei_per_call: "1", remote_port: 20007 })
const myOffer = () => record(OFFER, KIND.offer, { lb_listing: key(LISTING) }, { specs: node.specs })

async function run(chain: ReturnType<typeof fakeChain>, facts = node) {
  const lines: string[] = []
  let unlocked = false
  const outcome = await postOffer({
    node: facts,
    reader: chain.reader,
    lb: LB,
    me: ME,
    writer: async () => {
      unlocked = true
      return chain.writer
    },
    print: (line) => lines.push(line),
  })
  return { outcome, lines, unlocked }
}

describe("post-offer", () => {
  it("posts the node's specs against the listing, for one day", async () => {
    const chain = fakeChain({ listing: [listing()] })
    const { outcome, lines, unlocked } = await run(chain)
    deepEqual(outcome, { posted: OFFER })
    ok(unlocked, "the key was unlocked to sign")
    equal(chain.created.length, 1)
    const { record: rec, days } = chain.created[0] ?? { record: undefined, days: 0 }
    ok(rec, "one offer written")
    equal(days, OFFER_DAYS)
    deepEqual(rec.attributes, { kind: str(KIND.offer), v: i32(1), lb_listing: key(LISTING) })
    deepEqual(JSON.parse(bytesToString(rec.payload)), { specs: node.specs })
    match(lines.join("\n"), /0\.001 GLM per request/)
    match(lines.join("\n"), /Slots: 3 of 100 taken/)
  })

  it("points at the oldest listing when there are several, whatever their expiry", async () => {
    // The one in use is refreshed, so its expiry is the later one.
    const other = `0x${"a2".repeat(32)}` as Hex
    const chain = fakeChain({ listing: [listing(other, 200n, 5000n), listing(LISTING, 100n, 9000n)] })
    await run(chain)
    deepEqual((chain.created[0]?.record.attributes as { lb_listing: unknown }).lb_listing, key(LISTING))
  })

  const refusals: [string, Parameters<typeof fakeChain>[0], NodeFacts, RegExp][] = [
    ["a syncing node", { listing: [listing()] }, { ...node, syncing: true }, /still syncing/],
    ["no listing", {}, node, /no listing from the load balancer/],
    ["a live agreement", { listing: [listing()], agreement: [myAgreement()] }, node, /already have an agreement.*port 20007/],
    ["a live offer", { listing: [listing()], offer: [myOffer()] }, node, /already have a live offer/],
    ["an unfunded key", { listing: [listing()], balance: 0n }, node, /no GLM for gas/],
  ]
  for (const [name, rows, facts, why] of refusals) {
    it(`refuses with ${name}, before the key is unlocked`, async () => {
      const chain = fakeChain(rows)
      const { outcome, unlocked } = await run(chain, facts)
      ok("refused" in outcome, "refused")
      match(outcome.refused, why)
      equal(unlocked, false, "no password asked")
      equal(chain.created.length, 0, "nothing written")
    })
  }
})
