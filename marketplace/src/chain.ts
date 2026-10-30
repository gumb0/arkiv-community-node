// The chain as the commands see it, through the provider's own node:
// reads by query, and writes signed with the provider key. Behind a
// small surface so the commands are tested over a fake.

import {
  createPublicClient,
  createWalletClient,
  ExpirationTime,
  type Entity,
} from "@arkiv-network/sdk"
import { defineChain, http, type Chain, type Hex } from "viem"
import { privateKeyToAccount } from "viem/accounts"
import type { OfferRecord } from "./records.ts"

export type Reader = {
  chainId: number
  head(): Promise<bigint>
  balance(address: Hex): Promise<bigint>
  query(text: string): Promise<Entity[]>
  count(text: string): Promise<number>
}

export type Created = { entityKey: Hex; expiresAt: bigint }

export type Writer = {
  createOffer(record: OfferRecord, days: number): Promise<Created>
}

const PAGE = 200

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
          key: true,
          creator: true,
          createdAt: true,
          updatedAt: true,
          expiresAt: true,
          payload: true,
          attributes: true,
        },
      })
      return page.entities
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
 * `undefined` for any other failure. The node refusing what these
 * commands send is what a node newer than them looks like, so the
 * line names the update.
 */
export function explainRefusal(error: unknown): string | undefined {
  for (let link: unknown = error; link instanceof Error; link = link.cause) {
    if (!/Rpc(Request)?Error$/.test(link.name)) continue
    const details = (link as { details?: string }).details || link.message.split("\n")[0]
    return (
      `your node refused a request from these commands: ${details}\n` +
      "  If the node was updated recently, update these commands too: git pull && ./setup.sh --refresh"
    )
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
      const created = await wallet.createEntity({
        ...record,
        expires: ExpirationTime.fromDays(days),
      })
      return { entityKey: created.entityKey, expiresAt: created.expiresAt }
    },
  }
}
