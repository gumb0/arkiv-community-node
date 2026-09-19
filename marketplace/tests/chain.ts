// A chain the commands run over in tests: rows per record kind,
// answered by the kind a query names, and the offers a writer wrote.

import type { Entity } from "@arkiv-network/sdk"
import type { Hex } from "viem"
import type { Reader, Writer } from "../src/chain.ts"
import type { OfferRecord } from "../src/records.ts"
import { KIND } from "../src/records.ts"

/** A record kind by its short name: "listing", "offer", … */
type Kind = keyof typeof KIND

/**
 * What the fake answers with: the entities of each kind a test sets
 * (an empty page for the rest), the key's balance, and `taken`, the
 * count of live agreements, which the commands show as "N of M slots".
 */
export type Rows = Partial<Record<Kind, Entity[]>> & { balance?: bigint; taken?: number }

export function fakeChain(rows: Rows, head = 1000n) {
  const created: { record: OfferRecord; days: number }[] = []
  const reader: Reader = {
    chainId: 7738577,
    head: async () => head,
    balance: async () => rows.balance ?? 10n ** 18n,
    query: async (text) => {
      for (const [name, kind] of Object.entries(KIND)) {
        if (text.includes(`str('${kind}')`)) return rows[name as Kind] ?? []
      }
      throw new Error(`unexpected query ${text}`)
    },
    count: async () => rows.taken ?? 3,
  }
  const writer: Writer = {
    createOffer: async (record, days) => {
      created.push({ record, days })
      return { entityKey: `0x${"0f".repeat(32)}` as Hex, expiresAt: head + 43200n }
    },
  }
  return { reader, writer, created }
}
