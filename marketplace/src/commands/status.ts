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
  /** The node is not current yet: what it shows may be out of date. */
  syncing: boolean
  lb: Hex
  /** Unset while no payouts are made on this chain. */
  settle: Hex | undefined
  /** Earlier settle keys: their receipts are payouts too. */
  settlePrevious: Hex[]
  me: Hex
  /** What the tunnel is configured for, from .env; unset before start-tunnel ran. */
  tunnel: { agreement?: string; port?: number } | undefined
  print: (line: string) => void
}

export async function status(o: Status): Promise<void> {
  if (o.syncing) {
    o.print("Your node is still syncing: what follows is what it has seen so far, and may be out of date.")
  }
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
  // The tunnel is configured once, at start-tunnel; an agreement that
  // ended and was made again has a new id and may have a new port, and
  // the tunnel keeps serving the old one until start-tunnel runs again.
  if (agreement) {
    const configured = o.tunnel?.agreement?.toLowerCase()
    if (!configured) {
      o.print("Tunnel: not started yet: run start-tunnel")
    } else if (configured !== agreement.key.toLowerCase() || o.tunnel?.port !== agreement.remotePort) {
      o.print(
        `Tunnel: configured for agreement ${o.tunnel?.agreement} on port ${o.tunnel?.port}, not for this one: run start-tunnel again`,
      )
    } else {
      o.print("Tunnel: configured for this agreement")
    }
  }

  const counters = (
    await o.reader.query(byKind(KIND.counter, creator(o.lb), attrAddr("provider", o.me), alive(head)))
  ).map(decodeCounter)
  const open = counters.find((c) => c.state === "open")
  if (!open) {
    o.print("Counting: no open record")
  } else {
    const where = `since block ${open.openedBlock}, record ${open.key}`
    const ago = timeAgo(Number(head - open.updatedAt) * SECONDS_PER_BLOCK)
    o.print(`Counting: ${open.count} requests as of the last write, ${ago} (${where})`)
    // The load balancer opens a record at zero and writes the count into
    // it from time to time: a 0 in a record it has not written since is
    // no news about the requests served.
    if (open.count === 0 && open.updatedAt === open.createdAt) {
      o.print("  The load balancer writes the count to the chain from time to time; requests served since its last write are not in it yet.")
    }
  }

  // One read per settle address, each by its creator: a receipt anyone
  // else wrote is nobody's payout. Each address once, so a list that
  // repeats one, or names the current key, does not count its receipts
  // twice.
  const receipts: ReturnType<typeof decodeReceipt>[] = []
  const payers = o.settle ? new Set<Hex>([o.settle, ...o.settlePrevious].map((a) => a.toLowerCase() as Hex)) : new Set<Hex>()
  for (const payer of payers) {
    const page = await o.reader.query(byKind(KIND.receipt, creator(payer), attrAddr("provider", o.me)))
    receipts.push(...page.map(decodeReceipt))
  }
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
  return seconds <= 0 ? "now" : `in ${about(seconds)}`
}

/** A time past in words: "about 3 hours ago", "about 40 minutes ago". */
export function timeAgo(seconds: number): string {
  return seconds <= 0 ? "just now" : `${about(seconds)} ago`
}

/** A span in words, rounded to minutes, then hours from two on, then days from two on. */
function about(seconds: number): string {
  const minutes = Math.round(seconds / 60)
  if (minutes < 120) return `about ${minutes} minute${minutes === 1 ? "" : "s"}`
  const hours = Math.round(minutes / 60)
  if (hours < 48) return `about ${hours} hours`
  return `about ${Math.round(hours / 24)} days`
}
