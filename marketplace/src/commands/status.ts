// `status`: where this provider stands, from the records alone, one
// line per thing: the key, the load balancer's terms, the offer, the
// agreement, the counts, the payouts.

import { formatEther, type Hex } from "viem"
import type { Reader } from "../chain.ts"
import {
  KIND,
  alive,
  attrAddr,
  byKind,
  creator,
  decodeAgreement,
  decodeCounter,
  decodeListing,
  decodeOffer,
  decodeReceipt,
  oldest,
} from "../records.ts"

/** The chain's block time, for turning a block count into a wait. */
const SECONDS_PER_BLOCK = 2

export type Status = {
  reader: Reader
  lb: Hex
  /** Unset while no payouts are made on this chain. */
  settle: Hex | undefined
  me: Hex
  print: (line: string) => void
}

export async function status(o: Status): Promise<void> {
  const head = await o.reader.head()
  const left = (expiresAt: bigint) => timeLeft(Number(expiresAt - head) * SECONDS_PER_BLOCK)

  // The gas balance on the Arkiv chain; payouts go to the same key on
  // the payout chain and show under receipts, not here.
  o.print(
    `Key: ${o.me}, ${formatEther(await o.reader.balance(o.me))} GLM for gas on the Arkiv chain`,
  )

  const listings = await o.reader.query(byKind(KIND.listing, creator(o.lb), alive(head)))
  const listing = oldest(listings.map(decodeListing))
  if (!listing) {
    o.print(`Load balancer: no listing from ${o.lb} on chain ${o.reader.chainId}`)
  } else {
    const taken = await o.reader.count(byKind(KIND.agreement, creator(o.lb), alive(head)))
    o.print(
      `Load balancer: pays ${formatEther(listing.weiPerCall)} GLM per request, ${taken} of ${listing.maxProviders} slots taken`,
    )
  }

  const offer = (await o.reader.query(byKind(KIND.offer, creator(o.me), alive(head)))).map(decodeOffer)[0]
  o.print(offer ? `Offer: ${offer.key}, expires ${left(offer.expiresAt)}` : "Offer: none")

  const agreements = await o.reader.query(byKind(KIND.agreement, creator(o.lb), attrAddr("provider", o.me), alive(head)))
  const agreement = oldest(agreements.map(decodeAgreement))
  o.print(
    agreement
      ? `Agreement: ${agreement.key}, tunnel port ${agreement.remotePort}, ${formatEther(agreement.weiPerCall)} GLM per request, expires ${left(agreement.expiresAt)}`
      : "Agreement: none",
  )

  const counters = (
    await o.reader.query(byKind(KIND.counter, creator(o.lb), attrAddr("provider", o.me), alive(head)))
  ).map(decodeCounter)
  const open = counters.find((c) => c.state === "open")
  o.print(
    open
      ? `Counting: ${open.count} requests since block ${open.openedBlock} (record ${open.key})`
      : "Counting: no open record",
  )

  const receipts = o.settle
    ? (await o.reader.query(byKind(KIND.receipt, creator(o.settle), attrAddr("provider", o.me)))).map(decodeReceipt)
    : []
  const paid = new Set(receipts.map((r) => r.counter))
  const unpaid = counters.filter((c) => c.state === "closed" && !paid.has(c.key))
  const unpaidCount = unpaid.reduce((sum, c) => sum + c.count, 0)
  o.print(
    unpaid.length > 0
      ? `Awaiting payout: ${unpaid.length} closed record${unpaid.length === 1 ? "" : "s"}, ${unpaidCount} requests`
      : "Awaiting payout: nothing",
  )

  if (!o.settle) {
    o.print("Payouts: no settle address is shipped for this chain yet")
    return
  }
  if (receipts.length === 0) {
    o.print("Payouts: none yet")
    return
  }
  const total = receipts.reduce((sum, r) => sum + r.amountWei, 0n)
  // The newest by creation block; a page's own order promises nothing.
  const last = receipts.reduce((newest, r) => (r.createdAt > newest.createdAt ? r : newest))
  o.print(
    `Payouts: ${receipts.length} receipt${receipts.length === 1 ? "" : "s"}, ${formatEther(total)} GLM in total; last transfer ${last.payout.tx} on chain ${last.payout.chainId}`,
  )
}

/** A wait in words: "in about 3 hours", "in about 40 minutes". */
export function timeLeft(seconds: number): string {
  if (seconds <= 0) return "now"
  const minutes = Math.round(seconds / 60)
  if (minutes < 120) return `in about ${minutes} minute${minutes === 1 ? "" : "s"}`
  const hours = Math.round(minutes / 60)
  if (hours < 48) return `in about ${hours} hours`
  return `in about ${Math.round(hours / 24)} days`
}
