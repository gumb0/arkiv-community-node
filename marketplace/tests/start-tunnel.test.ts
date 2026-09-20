// start-tunnel over a fake chain: the settings it writes from the
// agreement and the listing, and the refusal without an agreement.
// Run: npm test

import { deepStrictEqual as deepEqual, strictEqual as equal, match, ok, throws } from "node:assert/strict"
import { describe, it } from "node:test"
import { Entity, addr, i32, key, str, type Attributes } from "@arkiv-network/sdk"
import { recoverMessageAddress, stringToBytes, type Hex } from "viem"
import { privateKeyToAccount } from "viem/accounts"
import { splitHostPort, startTunnel } from "../src/commands/start-tunnel.ts"
import { KIND } from "../src/records.ts"
import { tokenMessage } from "../src/token.ts"
import { fakeChain, type Rows } from "./chain.ts"

const LB = "0xCA4B166EE155Cb2816Dc25f94Dc1fD102a26c997" as Hex
const KEY = `0x${"11".repeat(32)}` as Hex
const ME = privateKeyToAccount(KEY).address
const LISTING = `0x${"a1".repeat(32)}` as Hex
const AGREEMENT = `0x${"9c".repeat(32)}` as Hex

function record(k: Hex, kind: string, attributes: Record<string, unknown>, payload: object): Entity {
  return new Entity({
    key: k,
    creator: LB,
    createdAt: 100n,
    expiresAt: 5000n,
    attributes: { kind: str(kind), v: i32(1), ...attributes } as Attributes,
    payload: stringToBytes(JSON.stringify(payload)),
  })
}

const listing = (tunnelServer: string) =>
  record(LISTING, KIND.listing, {}, { wei_per_call: "1", tunnel_server: tunnelServer, max_providers: 100 })
const agreement = record(AGREEMENT, KIND.agreement, { provider: addr(ME), offer: key(LISTING) }, { wei_per_call: "1", remote_port: 20007 })

async function run(rows: Rows) {
  const lines: string[] = []
  let written = ""
  let unlocked = false
  const outcome = await startTunnel({
    reader: fakeChain(rows).reader,
    lb: LB,
    me: ME,
    privateKey: async () => {
      unlocked = true
      return KEY
    },
    write: async (text) => {
      written = text
    },
    print: (line) => lines.push(line),
  })
  return { outcome, lines, written, unlocked }
}

describe("start-tunnel", () => {
  it("writes the server, the port and the signed token from the records", async () => {
    const { outcome, written, unlocked } = await run({ listing: [listing("203.0.113.10:7000")], agreement: [agreement] })
    ok("written" in outcome, "written")
    ok(unlocked)
    const values = Object.fromEntries(written.trim().split("\n").map((line) => line.split("=", 2)))
    equal(values.TUNNEL_SERVER_ADDR, "203.0.113.10")
    equal(values.TUNNEL_SERVER_PORT, "7000")
    equal(values.TUNNEL_REMOTE_PORT, "20007")
    equal(values.TUNNEL_AGREEMENT, AGREEMENT)
    const signer = await recoverMessageAddress({ message: tokenMessage(AGREEMENT), signature: values.TUNNEL_TOKEN as Hex })
    equal(signer, ME, "the token is this key's signature over the agreement id")
    deepEqual(Object.keys(values).sort(), ["TUNNEL_AGREEMENT", "TUNNEL_REMOTE_PORT", "TUNNEL_SERVER_ADDR", "TUNNEL_SERVER_PORT", "TUNNEL_TOKEN"])
  })

  it("refuses without an agreement, before the key is unlocked", async () => {
    const { outcome, unlocked, written } = await run({ listing: [listing("203.0.113.10:7000")] })
    ok("refused" in outcome)
    match(outcome.refused, /no agreement yet/)
    equal(unlocked, false)
    equal(written, "")
  })

  it("refuses when the listing is gone, after the agreement is found", async () => {
    const { outcome, unlocked } = await run({ agreement: [agreement] })
    ok("refused" in outcome)
    match(outcome.refused, /listing is gone/)
    equal(unlocked, false)
  })

  it("reads the tunnel server as host and port", () => {
    deepEqual(splitHostPort("203.0.113.10:7000"), ["203.0.113.10", 7000])
    deepEqual(splitHostPort("tunnel.example.org"), ["tunnel.example.org", 7000])
    deepEqual(splitHostPort("[2001:db8::1]:7100"), ["[2001:db8::1]", 7100])
    throws(() => splitHostPort("host:notaport"), /no valid port/)
  })
})
