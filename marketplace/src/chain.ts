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
