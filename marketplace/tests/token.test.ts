// The tunnel token: the message signed, and the signature recovering
// to the key's address. Run: npm test

import { strictEqual as equal } from "node:assert/strict"
import { describe, it } from "node:test"
import { recoverMessageAddress, type Hex } from "viem"
import { privateKeyToAccount } from "viem/accounts"
import { signToken, tokenMessage } from "../src/token.ts"

const KEY = `0x${"11".repeat(32)}` as Hex
const AGREEMENT = `0x${"9C".repeat(32)}` as Hex

describe("the tunnel token", () => {
  it("is the prefixed lowercase id", () => {
    equal(tokenMessage(AGREEMENT), `arkiv-rpc:0x${"9c".repeat(32)}`)
  })

  it("is a signature by the key over the message", async () => {
    const token = await signToken(KEY, AGREEMENT)
    equal(token.length, 2 + 65 * 2, "65 bytes, hex")
    const signer = await recoverMessageAddress({ message: tokenMessage(AGREEMENT), signature: token })
    equal(signer, privateKeyToAccount(KEY).address)
  })
})
