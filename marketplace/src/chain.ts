// The chain as the commands see it, through the provider's own node:
// reads by query, and writes signed with the provider key. Behind a
// small surface so the commands are tested over a fake.

import { createPublicClient, createWalletClient, ExpirationTime } from "@arkiv-network/sdk"
import { defineChain, http, type Chain, type Hex } from "viem"
import { privateKeyToAccount } from "viem/accounts"
import type { OfferRecord } from "./records.ts"

/** One attribute of a row: the node's type tag and the decoded value. */
export type Attribute = { type: string; value: unknown }

/**
 * A row as the commands read it: the entity's key, creator and
 * blocks, and its attributes by name, the payload among them. The one
 * shape the rest of the package sees, whatever the SDK's rows look
 * like.
 */
export type Row = {
  key: Hex
  creator: Hex
  createdAt: bigint
  /** The block of the last write; the creation block until the first one. */
  updatedAt: bigint
  expiresAt: bigint
  attributes: Record<string, Attribute>
}

export type Reader = {
  chainId: number
  head(): Promise<bigint>
  balance(address: Hex): Promise<bigint>
  query(text: string): Promise<Row[]>
  count(text: string): Promise<number>
}

export type Created = { entityKey: Hex; expiresAt: bigint }

export type Writer = {
  createOffer(record: OfferRecord, days: number): Promise<Created>
}

/** The node's page maximum. */
const PAGE = 100

export async function connectReader(rpcUrl: string): Promise<Reader> {
  const client = createPublicClient({ transport: http(rpcUrl) })
  const chainId = await client.getChainId()
  return {
    chainId,
    head: () => client.getBlockNumber(),
    balance: (address) => client.getBalance({ address }),
    query: async (text) => {
      const page = await client.query(text, {
        limit: PAGE,
        select: {
          $key: true,
          $creator: true,
          $createdAt: true,
          $updatedAt: true,
          $expiresAt: true,
          $attributes: true,
        },
      })
      return page.entities.map(fromFlat)
    },
    // The SDK has no count call that takes a query at this version;
    // the node's method does.
    count: async (text) => {
      const count = await client.request({
        method: "arkiv_getEntityCount",
        params: [{ query: text }],
      } as never)
      return Number(count)
    },
  }
}

/**
 * A JSON-RPC error from the node, in one line: what the node said,
 * instead of viem's whole text with the request body and its version.
 * `undefined` for any other failure. The node refusing what
 * marketplace.sh sends is what a node newer than this checkout looks
 * like, so the line names the update.
 */
export function explainRefusal(error: unknown): string | undefined {
  const refused = (said: string) =>
    `your node refused a request from marketplace.sh: ${said}\n` +
    "  If the node was updated recently, update this checkout too: git pull && ./setup.sh --refresh"
  for (let link: unknown = error; link instanceof Error; link = link.cause) {
    // The SDK's own class for a query the node rejected (its cause is
    // the node's data, not an error): the message repeats the query,
    // which the operator has not typed and cannot act on.
    if (link.name === "QueryError") return refused(link.message.replace(/\. Query: [\s\S]*$/, ""))
    if (/Rpc(Request)?Error$/.test(link.name)) {
      return refused((link as { details?: string }).details || link.message.split("\n")[0] || link.name)
    }
  }
  return undefined
}

/** A flat row as the SDK answers one, with every selected part. */
type Flat = {
  $key?: Hex | undefined
  $creator?: Hex | undefined
  $createdAt?: bigint | undefined
  $updatedAt?: bigint | undefined
  $expiresAt?: bigint | undefined
  $attributes?: Record<string, Attribute> | undefined
}

/**
 * The SDK's flat row as the package's own. The types say every part
 * is there; this says so of the node's answer, naming the part a row
 * lacks rather than failing later on an undefined block.
 */
export function fromFlat(flat: Flat): Row {
  const present = <T>(value: T | undefined, what: string): T => {
    if (value === undefined) throw new Error(`record ${flat.$key} came without its ${what}`)
    return value
  }
  return {
    key: present(flat.$key, "key"),
    creator: present(flat.$creator, "creator"),
    createdAt: present(flat.$createdAt, "creation block"),
    updatedAt: present(flat.$updatedAt, "block of its last write"),
    expiresAt: present(flat.$expiresAt, "expiry"),
    attributes: present(flat.$attributes, "attributes"),
  }
}

export function connectWriter(rpcUrl: string, chainId: number, privateKey: Hex): Writer {
  const chain: Chain = defineChain({
    id: chainId,
    name: `arkiv-${chainId}`,
    nativeCurrency: { name: "Golem", symbol: "GLM", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
  })
  const wallet = createWalletClient({
    chain,
    transport: http(rpcUrl),
    account: privateKeyToAccount(privateKey),
    pollingInterval: 1000,
  })
  return {
    createOffer: async (record, days) => {
      const created = await wallet.createEntity(record.schema, record.values, {
        expiration: ExpirationTime.fromDays(days),
      })
      return { entityKey: created.entityKey, expiresAt: created.expiresAt }
    },
  }
}
