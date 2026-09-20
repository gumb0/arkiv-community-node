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

describe("the shipped addresses", () => {
  it("name the load balancer for tiramisu and no settle key yet", () => {
    equal(lbAddress(7738577, SHIPPED, undefined), LB)
    equal(settleAddress(7738577, SHIPPED, undefined), undefined)
  })

  it("refuse a chain nobody ships an address for, naming the override", () => {
    throws(() => lbAddress(1, SHIPPED, undefined), /chain 1; set LB_ADDRESS/)
    equal(settleAddress(1, SHIPPED, undefined), undefined)
  })

  it("take the .env override first, checksummed", () => {
    equal(lbAddress(1, SHIPPED, LB.toLowerCase()), LB)
    equal(settleAddress(1, SHIPPED, LB.toLowerCase()), LB)
  })

  it("read a settle address once one is shipped", () => {
    const dir = mkdtempSync(join(tmpdir(), "addresses-"))
    const file = join(dir, "addresses.json")
    writeFileSync(file, JSON.stringify({ "7": { lb: LB, settle: LB.toLowerCase() } }))
    equal(settleAddress(7, file, undefined), LB)
  })
})
