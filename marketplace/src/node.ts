// What the offer says about the node, read from the node itself: the
// operator types nothing. The execution client answers JSON-RPC, the
// beacon node its REST API; the hardware is the machine's.

import { cpus, totalmem } from "node:os"
import type { Specs } from "./records.ts"

/** One gibibyte; `totalmem` answers in bytes. */
const GIB = 2 ** 30

export type NodeFacts = {
  specs: Specs
  /** Any of the beacon node's three flags: not current yet. */
  syncing: boolean
}

async function rpc(url: string, method: string): Promise<string> {
  const response = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params: [] }),
  })
  const body = (await response.json()) as { result?: unknown; error?: { message: string } }
  if (body.error) throw new Error(`${method}: ${body.error.message}`)
  return String(body.result)
}

async function beacon(url: string, path: string): Promise<Record<string, unknown>> {
  const response = await fetch(`${url}${path}`)
  if (!response.ok) throw new Error(`${path}: HTTP ${response.status}`)
  const body = (await response.json()) as { data: Record<string, unknown> }
  return body.data
}

export async function readNode(elUrl: string, clUrl: string): Promise<NodeFacts> {
  const [chainId, head, el, version, syncing] = await Promise.all([
    rpc(elUrl, "eth_chainId"),
    rpc(elUrl, "eth_blockNumber"),
    rpc(elUrl, "web3_clientVersion"),
    beacon(clUrl, "/eth/v1/node/version"),
    beacon(clUrl, "/eth/v1/node/syncing"),
  ])
  const flag = (name: string) => syncing[name] === true || syncing[name] === "true"
  return {
    specs: {
      chain_id: Number(chainId),
      head: Number(head),
      el,
      cl: String(version.version),
      hw: { cpus: cpus().length, mem_gb: Math.round(totalmem() / GIB) },
    },
    syncing: flag("is_syncing") || flag("is_optimistic") || flag("el_offline"),
  }
}
