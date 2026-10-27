// `status`: where this provider stands, from the records alone, as the
// facts status.sh renders: the key, the load balancer's terms, the
// offer, the agreement, the tunnel's agreement, the counts, the
// payouts, and the next step towards serving.

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

/** The chain's block time, for turning a block count into seconds. */
const SECONDS_PER_BLOCK = 2

export type Status = {
  reader: Reader
  lb: Hex
  settle: Hex
  /** Earlier settle keys: their receipts are payouts too. */
  settlePrevious: Hex[]
  me: Hex
  /** What the tunnel is configured for, from .env; unset before start-tunnel ran. */
  tunnel: { agreement?: string; port?: number } | undefined
}

/**
 * The operator's next step towards serving, or null once the tunnel is
 * set up for the agreement: the key needs gas before an offer, an
 * offer needs the load balancer's acceptance, an agreement needs its
 * tunnel.
 */
export type Next = "fund" | "post-offer" | "acceptance" | "start-tunnel" | null

/**
 * How the tunnel's settings relate to the agreement: none written yet,
 * the agreement's own, another agreement's (or port), or an agreement
 * that has ended.
 */
export type TunnelState = "unconfigured" | "current" | "other" | "ended"

/**
 * One flat object, every field present and null where there is
 * nothing, so status.sh reads each by name. Amounts are in GLM as
 * strings (the shell has no 18-decimal arithmetic); spans are seconds.
 */
export type Facts = {
  address: Hex
  balance_glm: string
  listing_glm_per_request: string | null
  listing_slots_taken: number | null
  listing_max_providers: number | null
  offer_key: Hex | null
  offer_expires_in_seconds: number | null
  agreement_key: Hex | null
  agreement_port: number | null
  agreement_glm_per_request: string | null
  agreement_expires_in_seconds: number | null
  tunnel_state: TunnelState
  tunnel_agreement: string | null
  tunnel_port: number | null
  count: number | null
  /** Null while the load balancer has not written the record since opening it: its 0 is no news. */
  count_written_seconds_ago: number | null
  count_opened_seconds_ago: number | null
  count_opened_block: number | null
  count_record: Hex | null
  /** Closed counter records with no receipt yet: payouts still owed, and the requests they cover. */
  awaiting_records: number
  awaiting_requests: number
  payouts_receipts: number
  payouts_total_glm: string | null
  payouts_last_tx: string | null
  payouts_last_chain_id: number | null
  next: Next
}

export async function status(o: Status): Promise<Facts> {
  const head = await o.reader.head()
  const seconds = (blocks: bigint) => Number(blocks) * SECONDS_PER_BLOCK

  // The gas balance on the Arkiv chain; payouts go to the same key on
  // the payout chain and show under the receipts, not here.
  const balance = await o.reader.balance(o.me)

  const listings = await o.reader.query(byKind(KIND.listing, creator(o.lb), alive(head)))
  const listing = oldest(listings.map(decodeListing))
  const taken = listing ? await o.reader.count(byKind(KIND.agreement, creator(o.lb), alive(head))) : null

  const offer = (await o.reader.query(byKind(KIND.offer, creator(o.me), alive(head)))).map(decodeOffer)[0]

  const agreements = await o.reader.query(byKind(KIND.agreement, creator(o.lb), attrAddr("provider", o.me), alive(head)))
  const agreement = oldest(agreements.map(decodeAgreement))

  // The tunnel is configured once, at start-tunnel; an agreement that
  // ended and was made again has a new id and may have a new port, and
  // the tunnel keeps serving the old one until start-tunnel runs again.
  const configured = o.tunnel?.agreement?.toLowerCase()
  let tunnel_state: TunnelState = "unconfigured"
  if (agreement && configured) {
    tunnel_state = configured === agreement.key.toLowerCase() && o.tunnel?.port === agreement.remotePort ? "current" : "other"
  } else if (configured) {
    tunnel_state = "ended"
  }

  const counters = (
    await o.reader.query(byKind(KIND.counter, creator(o.lb), attrAddr("provider", o.me), alive(head)))
  ).map(decodeCounter)
  const open = counters.find((c) => c.state === "open")

  // One read per settle address, each by its creator: a receipt anyone
  // else wrote is nobody's payout. Each address once, so a list that
  // repeats one, or names the current key, does not count its receipts
  // twice.
  const receipts: ReturnType<typeof decodeReceipt>[] = []
  const payers = new Set<Hex>([o.settle, ...o.settlePrevious].map((a) => a.toLowerCase() as Hex))
  for (const payer of payers) {
    const page = await o.reader.query(byKind(KIND.receipt, creator(payer), attrAddr("provider", o.me)))
    receipts.push(...page.map(decodeReceipt))
  }
  const paid = new Set(receipts.map((r) => r.counter))
  const unpaid = counters.filter((c) => c.state === "closed" && !paid.has(c.key))
  // The newest by creation block; a page's own order promises nothing.
  const last = receipts.length > 0 ? receipts.reduce((newest, r) => (r.createdAt > newest.createdAt ? r : newest)) : undefined

  // The steps in reverse: an agreement needs only its tunnel, whatever
  // the balance; without one, an offer waits for acceptance; before an
  // offer, the key needs gas.
  let next: Next
  if (agreement) {
    next = tunnel_state === "current" ? null : "start-tunnel"
  } else if (offer) {
    next = "acceptance"
  } else {
    next = balance === 0n ? "fund" : "post-offer"
  }

  return {
    address: o.me,
    balance_glm: formatEther(balance),
    listing_glm_per_request: listing ? formatEther(listing.weiPerCall) : null,
    listing_slots_taken: taken,
    listing_max_providers: listing?.maxProviders ?? null,
    offer_key: offer?.key ?? null,
    offer_expires_in_seconds: offer ? seconds(offer.expiresAt - head) : null,
    agreement_key: agreement?.key ?? null,
    agreement_port: agreement?.remotePort ?? null,
    agreement_glm_per_request: agreement ? formatEther(agreement.weiPerCall) : null,
    agreement_expires_in_seconds: agreement ? seconds(agreement.expiresAt - head) : null,
    tunnel_state,
    tunnel_agreement: o.tunnel?.agreement ?? null,
    tunnel_port: o.tunnel?.port ?? null,
    count: open?.count ?? null,
    count_written_seconds_ago: open && open.updatedAt !== open.createdAt ? seconds(head - open.updatedAt) : null,
    count_opened_seconds_ago: open ? seconds(head - open.createdAt) : null,
    count_opened_block: open?.openedBlock ?? null,
    count_record: open?.key ?? null,
    awaiting_records: unpaid.length,
    awaiting_requests: unpaid.reduce((sum, c) => sum + c.count, 0),
    payouts_receipts: receipts.length,
    payouts_total_glm: last ? formatEther(receipts.reduce((sum, r) => sum + r.amountWei, 0n)) : null,
    payouts_last_tx: last?.payout.tx ?? null,
    payouts_last_chain_id: last?.payout.chainId ?? null,
    next,
  }
}
