// The marketplace records as the provider reads and writes them: the
// one place a record's shape is spelled in this package.

import { i32, key, str, jsonToPayload, type AttributeInputs } from "@arkiv-network/sdk"
import { bytesToString, type Hex } from "viem"
import type { Row } from "./chain.ts"

const SCHEMA_VERSION = 1

export const KIND = {
  listing: "rpc.lb_listing",
  offer: "rpc.offer",
  agreement: "rpc.agreement",
  counter: "rpc.counter",
  receipt: "rpc.receipt",
} as const

// --- query text ------------------------------------------------------------
// Typed literals, joined by AND, every query starting from a kind at
// this schema version so a newer record never takes a row.

export function byKind(kind: string, ...conditions: string[]): string {
  return [`kind = str('${kind}')`, `v = i32(${SCHEMA_VERSION})`, ...conditions].join(" AND ")
}

export const creator = (address: Hex): string => `$creator = addr(${address.toLowerCase()})`
export const alive = (head: bigint): string => `$expiresAt > u64(${head})`
export const attrAddr = (name: string, address: Hex): string => `${name} = addr(${address.toLowerCase()})`

// --- reading ---------------------------------------------------------------

function attribute(row: Row, name: string, type: string): unknown {
  const value = row.attributes[name]
  if (value === undefined || value.type !== type) {
    throw new Error(`record ${row.key} has no ${type} attribute ${name}`)
  }
  return value.value
}

function payloadJson(row: Row): Record<string, unknown> {
  return JSON.parse(bytesToString(row.payload)) as Record<string, unknown>
}

/**
 * The oldest of several records of one kind, by creation block. Not by
 * expiry: a record that is refreshed moves its expiry, a creation
 * block never moves. A page's own order promises nothing.
 */
export function oldest<T extends { createdAt: bigint }>(records: T[]): T | undefined {
  return records.reduce<T | undefined>(
    (found, record) => (found === undefined || record.createdAt < found.createdAt ? record : found),
    undefined,
  )
}

export type Listing = {
  key: Hex
  createdAt: bigint
  expiresAt: bigint
  weiPerCall: bigint
  tunnelServer: string
  maxProviders: number
}

export function decodeListing(row: Row): Listing {
  const payload = payloadJson(row)
  return {
    key: row.key,
    createdAt: row.createdAt,
    expiresAt: row.expiresAt,
    weiPerCall: BigInt(payload.wei_per_call as string),
    tunnelServer: payload.tunnel_server as string,
    maxProviders: payload.max_providers as number,
  }
}

export type Specs = {
  chain_id: number
  head: number
  el: string
  cl: string
  hw: { cpus: number; mem_gb: number }
}

export type Offer = { key: Hex; expiresAt: bigint; lbListing: Hex; specs: Specs }

export function decodeOffer(row: Row): Offer {
  const payload = payloadJson(row)
  return {
    key: row.key,
    expiresAt: row.expiresAt,
    lbListing: attribute(row, "lb_listing", "key") as Hex,
    specs: payload.specs as Specs,
  }
}

export type Agreement = {
  key: Hex
  createdAt: bigint
  expiresAt: bigint
  provider: Hex
  offer: Hex
  weiPerCall: bigint
  remotePort: number
}

export function decodeAgreement(row: Row): Agreement {
  const payload = payloadJson(row)
  return {
    key: row.key,
    createdAt: row.createdAt,
    expiresAt: row.expiresAt,
    provider: attribute(row, "provider", "addr") as Hex,
    offer: attribute(row, "offer", "key") as Hex,
    weiPerCall: BigInt(payload.wei_per_call as string),
    remotePort: payload.remote_port as number,
  }
}

// --- writing ---------------------------------------------------------------

export type OfferRecord = { attributes: AttributeInputs; payload: Uint8Array; contentType: "application/json" }

/** An offer against `lbListing`, with the node's specs in the payload. */
export function offerRecord(lbListing: Hex, specs: Specs): OfferRecord {
  return {
    attributes: { kind: str(KIND.offer), v: i32(SCHEMA_VERSION), lb_listing: key(lbListing) },
    payload: jsonToPayload({ specs }),
    contentType: "application/json",
  }
}

// --- the count and the payout ----------------------------------------------

export type Counter = {
  key: Hex
  createdAt: bigint
  /** The block of the last write; the creation block until the first one. */
  updatedAt: bigint
  expiresAt: bigint
  agreement: Hex
  provider: Hex
  state: "open" | "closed"
  count: number
  weiPerCall: bigint
  openedBlock: number
  closedBlock?: number
}

export function decodeCounter(row: Row): Counter {
  const payload = payloadJson(row)
  const state = attribute(row, "state", "str")
  if (state !== "open" && state !== "closed") {
    throw new Error(`record ${row.key} has state ${String(state)}, expected open or closed`)
  }
  return {
    key: row.key,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    expiresAt: row.expiresAt,
    agreement: attribute(row, "agreement", "key") as Hex,
    provider: attribute(row, "provider", "addr") as Hex,
    state,
    count: payload.count as number,
    weiPerCall: BigInt(payload.wei_per_call as string),
    openedBlock: payload.opened_block as number,
    ...(payload.closed_block === undefined ? {} : { closedBlock: payload.closed_block as number }),
  }
}

export type Receipt = {
  key: Hex
  createdAt: bigint
  counter: Hex
  provider: Hex
  agreement: Hex
  count: number
  amountWei: bigint
  payout: { chainId: number; tx: string }
}

export function decodeReceipt(row: Row): Receipt {
  const payload = payloadJson(row)
  const payout = payload.payout as { chain_id: number; tx: string }
  return {
    key: row.key,
    createdAt: row.createdAt,
    counter: attribute(row, "counter", "key") as Hex,
    provider: attribute(row, "provider", "addr") as Hex,
    agreement: payload.agreement as Hex,
    count: payload.count as number,
    amountWei: BigInt(payload.amount_wei as string),
    payout: { chainId: payout.chain_id, tx: payout.tx },
  }
}
