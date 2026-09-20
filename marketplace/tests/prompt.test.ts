// The password prompt over a stream in place of the terminal: the
// answer comes back, nothing is echoed, and a second prompt in the
// same command reads the next line. Run: npm test

import { strictEqual as equal, match } from "node:assert/strict"
import { describe, it } from "node:test"
import { PassThrough } from "node:stream"
import { askPassword } from "../src/prompt.ts"

describe("the password prompt", () => {
  it("reads two answers in a row and echoes neither", async () => {
    const input = new PassThrough()
    const output = new PassThrough()
    let echoed = ""
    output.on("data", (chunk: Buffer) => (echoed += chunk.toString()))
    const ask = (prompt: string) => askPassword(prompt, { input, output })
    // One answer at a time, the way a terminal delivers them.
    input.write("first\n")
    equal(await ask("Password: "), "first")
    input.write("second\n")
    equal(await ask("Again: "), "second")
    match(echoed, /Password: /)
    equal(echoed.includes("first"), false, "the answer is not echoed")
  })
})
