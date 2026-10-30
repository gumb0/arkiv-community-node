// What a failure from the node reads as, and the reader's row: every part
// the commands read is present, or the row is refused with the part named.
// Run: npm test

import { match, strictEqual as equal, throws } from "node:assert/strict"
import { describe, it } from "node:test"
import { Entity, i32, str, type Attributes } from "@arkiv-network/sdk"
import { stringToBytes, type Hex } from "viem"
import { explainRefusal, fromEntity } from "../src/chain.ts"

/** An error the way viem throws one: a class name, a short message, the node's words in `details`. */
function rpcError(name: string, details: string, cause?: Error): Error {
  const error = new Error(`Invalid parameters were provided to the RPC method.\nURL: http://execution:8545\nRequest body: {...}\n\nDetails: ${details}\nVersion: viem@2.56.8`)
  error.name = name
  Object.assign(error, { details })
  if (cause) error.cause = cause
  return error
}

describe("a refusal from the node", () => {
  it("is one line with the node's words, not viem's whole text", () => {
    const line = explainRefusal(rpcError("InvalidParamsRpcError", "unknown field `contentType`"))
    equal(line?.split("\n")[0], "your node refused a request from marketplace.sh: unknown field `contentType`")
    match(line ?? "", /git pull && \.\/setup\.sh --refresh/)
    equal(line?.includes("Request body"), false)
    equal(line?.includes("viem@"), false)
  })

  it("is found down the cause chain", () => {
    const wrapped = new Error("query failed", { cause: rpcError("RpcRequestError", "method not found") })
    match(explainRefusal(wrapped) ?? "", /^your node refused a request from marketplace.sh: method not found/)
  })

  it("is the SDK's query error without the query it repeats", () => {
    // The SDK wraps a query the node rejected in its own class, whose
    // cause is the node's data rather than an error.
    const error = new Error(
      "Query rejected (parse, -32001): unexpected token at position 3. Query: kind = str('rpc.lb_listing') AND v = i32(1)",
      { cause: { position: 3 } },
    )
    error.name = "QueryError"
    const line = explainRefusal(error)
    equal(
      line?.split("\n")[0],
      "your node refused a request from marketplace.sh: Query rejected (parse, -32001): unexpected token at position 3",
    )
    equal(line?.includes("rpc.lb_listing"), false)
  })

  it("leaves every other failure to its own words", () => {
    const transport = new Error("fetch failed")
    transport.name = "HttpRequestError"
    equal(explainRefusal(transport), undefined)
    equal(explainRefusal(new Error("record 0x01 came without its payload")), undefined)
  })
})

const KEY = `0x${"a1".repeat(32)}` as Hex
const LB = "0xCA4B166EE155Cb2816Dc25f94Dc1fD102a26c997" as Hex

const full = () => ({
  key: KEY,
  creator: LB,
  createdAt: 100n,
  updatedAt: 120n,
  expiresAt: 5000n,
  attributes: { kind: str("rpc.offer"), v: i32(1) } as Attributes,
  payload: stringToBytes("{}"),
})

describe("a row from the SDK's entity", () => {
  it("carries every part the commands read", () => {
    const row = fromEntity(new Entity(full()))
    equal(row.key, KEY)
    equal(row.creator, LB)
    equal(row.createdAt, 100n)
    equal(row.updatedAt, 120n)
    equal(row.expiresAt, 5000n)
    equal(row.attributes.kind?.value, "rpc.offer")
    equal(Buffer.from(row.payload).toString("utf8"), "{}")
  })

  it("is refused without a part, naming it", () => {
    throws(() => fromEntity(new Entity({ ...full(), payload: undefined })), /payload/)
    throws(() => fromEntity(new Entity({ ...full(), updatedAt: undefined })), /last write/)
  })
})
