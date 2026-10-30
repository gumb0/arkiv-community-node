// What a failure from the node reads as. Run: npm test

import { match, strictEqual as equal } from "node:assert/strict"
import { describe, it } from "node:test"
import { explainRefusal } from "../src/chain.ts"

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
