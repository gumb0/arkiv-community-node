// The record shapes: what an offer is written as, what a listing and
// an agreement read as, and the query text. Run: npm test

import { deepStrictEqual as deepEqual, strictEqual as equal, throws } from "node:assert/strict"
import { describe, it } from "node:test"
import { Entity, addr, i32, key, str, type Attributes } from "@arkiv-network/sdk"
import { bytesToString, stringToBytes, type Hex } from "viem"
import {
  KIND,
  alive,
  attrAddr,
  byKind,
  creator,
  decodeAgreement,
  decodeCounter,
  decodeListing,
  decodeOffer,
  decodeReceipt,
  offerRecord,
  oldest,
} from "../src/records.ts"

const LISTING = `0x${"a1".repeat(32)}` as Hex
const LB = "0xCA4B166EE155Cb2816Dc25f94Dc1fD102a26c997" as Hex
const ME = "0x2121212121212121212121212121212121212121" as Hex

const specs = {
  chain_id: 7738577,
  head: 123456,
  el: "arkiv-reth/v0.2.0",
  cl: "lighthouse/v8.2.1",
  hw: { cpus: 8, mem_gb: 32 },
}

/** A queried entity, the way the SDK hands one back. */
function entity(fields: { key: Hex; expiresAt: bigint; attributes: Record<string, unknown>; payload: object }): Entity {
  return new Entity({
    key: fields.key,
    creator: LB,
    createdAt: 100n,
    expiresAt: fields.expiresAt,
    attributes: fields.attributes as Attributes,
    payload: stringToBytes(JSON.stringify(fields.payload)),
  })
}

describe("the offer", () => {
  it("is written with the attributes and payload ENTITIES.md names", () => {
    const record = offerRecord(LISTING, specs)
    deepEqual(record.attributes, {
      kind: str("rpc.offer"),
      v: i32(1),
      lb_listing: key(LISTING),
    })
    equal(record.contentType, "application/json")
    deepEqual(JSON.parse(bytesToString(record.payload)), { specs })
  })

  it("reads back", () => {
    const offer = decodeOffer(
      entity({
        key: `0x${"0f".repeat(32)}` as Hex,
        expiresAt: 500n,
        attributes: { kind: str(KIND.offer), v: i32(1), lb_listing: key(LISTING) },
        payload: { specs },
      }),
    )
    equal(offer.lbListing, LISTING)
    equal(offer.expiresAt, 500n)
    deepEqual(offer.specs, specs)
  })
})

describe("the load balancer's records", () => {
  it("the listing reads its rate, tunnel server and cap", () => {
    const listing = decodeListing(
      entity({
        key: LISTING,
        expiresAt: 9000n,
        attributes: { kind: str(KIND.listing), v: i32(1) },
        payload: { wei_per_call: "1000000000000000", tunnel_server: "203.0.113.10:7000", max_providers: 100 },
      }),
    )
    equal(listing.key, LISTING)
    equal(listing.createdAt, 100n)
    equal(listing.weiPerCall, 1_000_000_000_000_000n)
    equal(listing.tunnelServer, "203.0.113.10:7000")
    equal(listing.maxProviders, 100)
  })

  it("the agreement reads its provider, offer, rate and port", () => {
    const agreement = decodeAgreement(
      entity({
        key: `0x${"9c".repeat(32)}` as Hex,
        expiresAt: 7200n,
        attributes: { kind: str(KIND.agreement), v: i32(1), provider: addr(ME), offer: key(`0x${"0f".repeat(32)}`) },
        payload: { wei_per_call: "1000000000000000", remote_port: 20007 },
      }),
    )
    equal(agreement.provider.toLowerCase(), ME.toLowerCase())
    equal(agreement.remotePort, 20007)
    equal(agreement.weiPerCall, 1_000_000_000_000_000n)
  })

  it("the counter record reads its count, its span and its state", () => {
    const base = { agreement: key(`0x${"9c".repeat(32)}`), provider: addr(ME) }
    const open = decodeCounter(
      entity({
        key: `0x${"c1".repeat(32)}` as Hex,
        expiresAt: 90000n,
        attributes: { kind: str(KIND.counter), v: i32(1), ...base, state: str("open") },
        payload: { count: 48213, wei_per_call: "1000000000000000", opened_block: 1204000 },
      }),
    )
    equal(open.state, "open")
    equal(open.count, 48213)
    equal(open.openedBlock, 1204000)
    equal(open.closedBlock, undefined, "absent while open")
    equal(open.agreement, `0x${"9c".repeat(32)}`)

    const closed = decodeCounter(
      entity({
        key: `0x${"c2".repeat(32)}` as Hex,
        expiresAt: 90000n,
        attributes: { kind: str(KIND.counter), v: i32(1), ...base, state: str("closed") },
        payload: { count: 48213, wei_per_call: "1000000000000000", opened_block: 1204000, closed_block: 1506400 },
      }),
    )
    equal(closed.state, "closed")
    equal(closed.closedBlock, 1506400)

    throws(
      () =>
        decodeCounter(
          entity({
            key: `0x${"c3".repeat(32)}` as Hex,
            expiresAt: 90000n,
            attributes: { kind: str(KIND.counter), v: i32(1), ...base, state: str("paid") },
            payload: { count: 1, wei_per_call: "1", opened_block: 1 },
          }),
        ),
      /expected open or closed/,
    )
  })

  it("the receipt reads the record it pays, the amount and the transfer", () => {
    const receipt = decodeReceipt(
      entity({
        key: `0x${"e1".repeat(32)}` as Hex,
        expiresAt: 0n,
        attributes: { kind: str(KIND.receipt), v: i32(1), counter: key(`0x${"c2".repeat(32)}`), provider: addr(ME) },
        payload: {
          agreement: `0x${"9c".repeat(32)}`,
          count: 48213,
          wei_per_call: "1000000000000000",
          amount_wei: "48213000000000000000",
          payout: { chain_id: 560048, tx: "0x925d33c7" },
        },
      }),
    )
    equal(receipt.counter, `0x${"c2".repeat(32)}`)
    equal(receipt.agreement, `0x${"9c".repeat(32)}`)
    equal(receipt.count, 48213)
    equal(receipt.amountWei, 48_213_000_000_000_000_000n)
    deepEqual(receipt.payout, { chainId: 560048, tx: "0x925d33c7" })
  })

  it("a record without the attribute or the payload is an error, not a guess", () => {
    throws(() => decodeAgreement(new Entity({ key: LISTING, createdAt: 1n, expiresAt: 1n, attributes: {}, payload: stringToBytes("{}") })), /provider/)
    throws(() => decodeListing(new Entity({ key: LISTING, createdAt: 1n, expiresAt: 1n, attributes: {} })), /payload/)
  })

  it("the oldest is by creation block, not by expiry", () => {
    // The kept record is refreshed, so its expiry is the later one.
    const kept = { key: LISTING, createdAt: 100n, expiresAt: 9000n }
    const extra = { key: `0x${"a2".repeat(32)}` as Hex, createdAt: 200n, expiresAt: 5000n }
    equal(oldest([extra, kept]), kept)
    equal(oldest([kept, extra]), kept)
    equal(oldest([]), undefined)
  })
})

describe("the query text", () => {
  it("is typed literals joined by AND, from the kind and the version", () => {
    equal(
      byKind(KIND.agreement, creator(LB), attrAddr("provider", ME), alive(123n)),
      "kind = str('rpc.agreement') AND v = i32(1) AND $creator = addr(0xca4b166ee155cb2816dc25f94dc1fd102a26c997) AND provider = addr(0x2121212121212121212121212121212121212121) AND $expiresAt > u64(123)",
    )
  })
})
