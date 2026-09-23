// The shipped addresses: by chain id, overridden from .env, and what a
// chain with none gets. Run: npm test

import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"
import { strictEqual as equal, throws } from "node:assert/strict"
import { describe, it } from "node:test"
import { lbAddress, settleAddress } from "../src/addresses.ts"

// The file the container ships, next to this package's src/.
const SHIPPED = fileURLToPath(new URL("../addresses.json", import.meta.url))
const LB = "0xCA4B166EE155Cb2816Dc25f94Dc1fD102a26c997"
const SETTLE = "0x411E31d7eBbfd636Af234954db5f598Cd80a878C"

describe("the shipped addresses", () => {
  it("name the load balancer and the settle key for tiramisu", () => {
    equal(lbAddress(7738577, SHIPPED, undefined), LB)
    equal(settleAddress(7738577, SHIPPED, undefined), SETTLE)
  })

  it("refuse a chain nobody ships an address for, naming the override", () => {
    throws(() => lbAddress(1, SHIPPED, undefined), /chain 1; set LB_ADDRESS/)
    equal(settleAddress(1, SHIPPED, undefined), undefined)
  })

  it("take the .env override first, checksummed", () => {
    equal(lbAddress(1, SHIPPED, LB.toLowerCase()), LB)
    equal(settleAddress(1, SHIPPED, LB.toLowerCase()), LB)
  })

  it("read a settle address in whatever case it is shipped", () => {
    const dir = mkdtempSync(join(tmpdir(), "addresses-"))
    const file = join(dir, "addresses.json")
    writeFileSync(file, JSON.stringify({ "7": { lb: LB, settle: SETTLE.toLowerCase() } }))
    equal(settleAddress(7, file, undefined), SETTLE)
  })

  it("has none for a chain that ships only a load balancer", () => {
    // Payouts start later than the marketplace does: a provider's
    // status says so rather than showing nothing.
    const dir = mkdtempSync(join(tmpdir(), "addresses-"))
    const file = join(dir, "addresses.json")
    writeFileSync(file, JSON.stringify({ "7": { lb: LB } }))
    equal(settleAddress(7, file, undefined), undefined)
  })
})
