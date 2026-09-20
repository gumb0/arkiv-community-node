// The marketplace records as the provider reads and writes them: the
// one place a record's shape is spelled in this package.

import { i32, key, str, jsonToPayload, type AttributeInputs, type Entity } from "@arkiv-network/sdk"
import { bytesToString, type Hex } from "viem"

export const SCHEMA_VERSION = 1

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
export const attrKey = (name: string, entityKey: Hex): string => `${name} = key(${entityKey.toLowerCase()})`
export const attrStr = (name: string, value: string): string => `${name} = str('${value.replace(/'/g, "''")}')`

// --- reading ---------------------------------------------------------------

function attribute(entity: Entity, name: string, type: string): unknown {
  const value = entity.attributes?.[name]
  if (value === undefined || value.type !== type) {
    throw new Error(`record ${entity.key} has no ${type} attribute ${name}`)
  }
  return value.value
}

function payloadJson(entity: Entity): Record<string, unknown> {
  if (entity.payload === undefined) {
    throw new Error(`record ${entity.key} came without its payload`)
  }
  return JSON.parse(bytesToString(entity.payload)) as Record<string, unknown>
}

function expiresAt(entity: Entity): bigint {
  if (entity.expiresAt === undefined) {
    throw new Error(`record ${entity.key} came without its expiry`)
  }
  return entity.expiresAt
}

function createdAt(entity: Entity): bigint {
  if (entity.createdAt === undefined) {
    throw new Error(`record ${entity.key} came without its creation block`)
  }
  return entity.createdAt
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

export function decodeListing(entity: Entity): Listing {
  const payload = payloadJson(entity)
  return {
    key: entity.key as Hex,
    createdAt: createdAt(entity),
    expiresAt: expiresAt(entity),
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

export function decodeOffer(entity: Entity): Offer {
  const payload = payloadJson(entity)
  return {
    key: entity.key as Hex,
    expiresAt: expiresAt(entity),
    lbListing: attribute(entity, "lb_listing", "key") as Hex,
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

export function decodeAgreement(entity: Entity): Agreement {
  const payload = payloadJson(entity)
  return {
    key: entity.key as Hex,
    createdAt: createdAt(entity),
    expiresAt: expiresAt(entity),
    provider: attribute(entity, "provider", "addr") as Hex,
    offer: attribute(entity, "offer", "key") as Hex,
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
  expiresAt: bigint
  agreement: Hex
  provider: Hex
  state: "open" | "closed"
  count: number
  weiPerCall: bigint
  openedBlock: number
  closedBlock?: number
}

export function decodeCounter(entity: Entity): Counter {
  const payload = payloadJson(entity)
  const state = attribute(entity, "state", "str")
  if (state !== "open" && state !== "closed") {
    throw new Error(`record ${entity.key} has state ${String(state)}, expected open or closed`)
  }
  return {
    key: entity.key as Hex,
    expiresAt: expiresAt(entity),
    agreement: attribute(entity, "agreement", "key") as Hex,
    provider: attribute(entity, "provider", "addr") as Hex,
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

export function decodeReceipt(entity: Entity): Receipt {
  const payload = payloadJson(entity)
  const payout = payload.payout as { chain_id: number; tx: string }
  return {
    key: entity.key as Hex,
    createdAt: createdAt(entity),
    counter: attribute(entity, "counter", "key") as Hex,
    provider: attribute(entity, "provider", "addr") as Hex,
    agreement: payload.agreement as Hex,
    count: payload.count as number,
    amountWei: BigInt(payload.amount_wei as string),
    payout: { chainId: payout.chain_id, tx: payout.tx },
  }
}
