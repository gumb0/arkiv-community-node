// What the offer says about the node, read from the node itself: the
// operator types nothing. The execution client answers JSON-RPC, the
// beacon node its REST API; the hardware is the machine's.

import { readFileSync, readdirSync } from "node:fs"
import { cpus, totalmem } from "node:os"
import { join } from "node:path"
import type { Specs } from "./records.ts"

/** One gibibyte; the sizes below are in bytes. */
const GIB = 2 ** 30

/**
 * The machine's memory in whole GiB, from the memory blocks the kernel
 * maps (what `lsmem` sums): the installed size less the firmware's share.
 * The kernel's own total is lower by what the kernel keeps for itself and
 * puts a 16 GB machine at 15; it is the fallback where a kernel has no
 * memory blocks.
 */
export function installedMemoryGb(sysfs = "/sys/devices/system/memory"): number {
  let bytes = 0
  try {
    const blockSize = parseInt(readFileSync(join(sysfs, "block_size_bytes"), "utf8"), 16)
    const online = readdirSync(sysfs).filter(
      (name) => /^memory\d+$/.test(name) && readFileSync(join(sysfs, name, "online"), "utf8").trim() === "1",
    ).length
    bytes = blockSize * online
  } catch {
    // No memory blocks on this kernel: the fallback below.
  }
  return Math.round((bytes > 0 ? bytes : totalmem()) / GIB)
}

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

/** Any of the beacon node's three flags: its view of the chain is not current yet. */
export async function nodeSyncing(clUrl: string): Promise<boolean> {
  const syncing = await beacon(clUrl, "/eth/v1/node/syncing")
  const flag = (name: string) => syncing[name] === true || syncing[name] === "true"
  return flag("is_syncing") || flag("is_optimistic") || flag("el_offline")
}

export async function readNode(elUrl: string, clUrl: string): Promise<NodeFacts> {
  const [chainId, head, el, version, syncing] = await Promise.all([
    rpc(elUrl, "eth_chainId"),
    rpc(elUrl, "eth_blockNumber"),
    rpc(elUrl, "web3_clientVersion"),
    beacon(clUrl, "/eth/v1/node/version"),
    nodeSyncing(clUrl),
  ])
  return {
    specs: {
      chain_id: Number(chainId),
      head: Number(head),
      el,
      cl: String(version.version),
      hw: { cpus: cpus().length, mem_gb: installedMemoryGb() },
    },
    syncing,
  }
}
