// `post-offer`: the node's specs as an offer against the load
// balancer's listing, through the node itself. Every reason not to
// post is checked first, so an operator never spends gas on an offer
// the load balancer would skip.

import { formatEther, type Hex } from "viem"
import type { Reader, Writer } from "../chain.ts"
import type { NodeFacts } from "../node.ts"
import {
  KIND,
  alive,
  attrAddr,
  byKind,
  creator,
  decodeAgreement,
  decodeListing,
  decodeOffer,
  offerRecord,
  oldest,
} from "../records.ts"

export const OFFER_DAYS = 1

export type PostOffer = {
  node: NodeFacts
  reader: Reader
  lb: Hex
  me: Hex
  /** Unlocks the key and connects the writer; asked for only once posting is due. */
  writer: () => Promise<Writer>
  print: (line: string) => void
}

export type Outcome = { posted: Hex } | { refused: string }

export async function postOffer(o: PostOffer): Promise<Outcome> {
  if (o.node.syncing) {
    return refuse(o, "your node is still syncing. Post the offer once status.sh shows it current.")
  }
  const head = await o.reader.head()

  // Several listings: the oldest is the one in use, the one offers have
  // been pointing at the longest.
  const listings = await o.reader.query(byKind(KIND.listing, creator(o.lb), alive(head)))
  const listing = oldest(listings.map(decodeListing))
  if (!listing) {
    return refuse(
      o,
      `no listing from the load balancer ${o.lb} on chain ${o.reader.chainId}: it is not running, or your node is on another network.`,
    )
  }

  // Two records for one provider can exist for a while; the oldest is
  // the one in force.
  const agreements = await o.reader.query(byKind(KIND.agreement, creator(o.lb), attrAddr("provider", o.me), alive(head)))
  const agreement = oldest(agreements.map(decodeAgreement))
  if (agreement) {
    return refuse(
      o,
      `you already have an agreement: ${agreement.key}, tunnel port ${agreement.remotePort}, expires at block ${agreement.expiresAt}. Run start-tunnel; a new offer is only needed after it ends.`,
    )
  }

  const offer = (await o.reader.query(byKind(KIND.offer, creator(o.me), alive(head)))).map(decodeOffer)[0]
  if (offer) {
    return refuse(
      o,
      `you already have a live offer: ${offer.key}, expires at block ${offer.expiresAt}. The load balancer answers within minutes; run status to see.`,
    )
  }

  const balance = await o.reader.balance(o.me)
  if (balance === 0n) {
    return refuse(o, `your key ${o.me} has no GLM for gas. Fund it from the network's faucet, then post again.`)
  }

  const taken = await o.reader.count(byKind(KIND.agreement, creator(o.lb), alive(head)))
  o.print(`The load balancer pays ${formatEther(listing.weiPerCall)} GLM per request served.`)
  o.print(`Slots: ${taken} of ${listing.maxProviders} taken.`)
  o.print(`Posting your offer: chain ${o.node.specs.chain_id}, head ${o.node.specs.head}, ${o.node.specs.el}, ${o.node.specs.cl}, ${o.node.specs.hw.cpus} CPUs, ${o.node.specs.hw.mem_gb} GB.`)

  const writer = await o.writer()
  const created = await writer.createOffer(offerRecord(listing.key, o.node.specs), OFFER_DAYS)
  o.print(`Posted: offer ${created.entityKey}, valid until block ${created.expiresAt} (about one day).`)
  o.print("The load balancer looks for offers every few minutes. Run status to see the answer.")
  return { posted: created.entityKey }
}

function refuse(o: PostOffer, why: string): Outcome {
  o.print(`Not posting: ${why}`)
  return { refused: why }
}
