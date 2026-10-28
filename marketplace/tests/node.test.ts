// The machine's memory for the offer, over a fake sysfs. Run: npm test

import { strictEqual as equal } from "node:assert/strict"
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { totalmem, tmpdir } from "node:os"
import { join } from "node:path"
import { describe, it } from "node:test"
import { installedMemoryGb } from "../src/node.ts"

/** A sysfs memory directory: 128 MiB blocks, `online` of them on and `offline` off. */
function sysfs(online: number, offline = 0): string {
  const root = mkdtempSync(join(tmpdir(), "memory-"))
  writeFileSync(join(root, "block_size_bytes"), "8000000\n")
  for (let i = 0; i < online + offline; i++) {
    mkdirSync(join(root, `memory${i}`))
    writeFileSync(join(root, `memory${i}`, "online"), i < online ? "1\n" : "0\n")
  }
  return root
}

describe("the memory the offer reports", () => {
  it("is the online memory blocks, in whole GiB", () => {
    // 125 blocks of 128 MiB are 15.6 GiB: a 16 GB machine after the
    // firmware's share, which the kernel's own total would put at 15.
    equal(installedMemoryGb(sysfs(125)), 16)
    equal(installedMemoryGb(sysfs(252)), 32)
  })

  it("leaves offline blocks out", () => {
    equal(installedMemoryGb(sysfs(64, 8)), 8)
  })

  it("falls back to the kernel's total where there are no memory blocks", () => {
    equal(installedMemoryGb(join(tmpdir(), "no-such-memory-dir")), Math.round(totalmem() / 2 ** 30))
  })
})
