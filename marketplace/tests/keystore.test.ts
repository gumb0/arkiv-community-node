// The keystore: created once, unlocked by its password, readable by
// address without it. Run: npm test

import { mkdtempSync, readFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { strictEqual as equal, rejects, ok } from "node:assert/strict"
import { describe, it } from "node:test"
import { privateKeyToAccount } from "viem/accounts"
import { createKey, keyAddress, loadKey } from "../src/keystore.ts"

const dir = mkdtempSync(join(tmpdir(), "keystore-"))

describe("the provider key", () => {
  it("is created once and unlocked by its password", async () => {
    const path = join(dir, "key.json")
    const address = await createKey(path, "the password")
    const key = await loadKey(path, "the password")
    equal(key.address, address)
    equal(privateKeyToAccount(key.privateKey).address, address, "the key derives to the address")
    equal(await keyAddress(path), address, "the address reads without the password")
    await rejects(createKey(path, "another"), /already exists/)
    equal(await keyAddress(path), address, "the refusal changed nothing")
  })

  it("refuses a wrong password", async () => {
    const path = join(dir, "other.json")
    await createKey(path, "the password")
    await rejects(loadKey(path, "another password"))
  })

  it("is a standard keystore file", async () => {
    const path = join(dir, "standard.json")
    await createKey(path, "the password")
    // The keystore v3 shape; the crypto section's spelling varies by
    // writer and readers accept both.
    const json = JSON.parse(readFileSync(path, "utf8")) as {
      version?: number
      crypto?: unknown
      Crypto?: unknown
    }
    equal(json.version, 3)
    ok(json.crypto ?? json.Crypto, "the web3 keystore v3 shape")
  })
})
