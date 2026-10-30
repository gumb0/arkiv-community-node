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
      return page.entities.map((flat) => ({
        key: flat.$key,
        creator: flat.$creator,
        createdAt: flat.$createdAt,
        updatedAt: flat.$updatedAt,
        expiresAt: flat.$expiresAt,
        attributes: flat.$attributes as Record<string, Attribute>,
      }))
    },
    // The SDK's getEntityCount at this version takes no query and
    // counts every entity on the chain; the node's method takes one.
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
