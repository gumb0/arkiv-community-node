// The two addresses the records are trusted by: the load balancer's,
// which writes the listing, the agreements and the counts, and the
// settle key's, which writes the receipts. Network values shipped with
// the distribution and keyed by chain id, like genesis and bootnodes;
// LB_ADDRESS and SETTLE_ADDRESS in .env override them, for a private
// deployment.

import { readFileSync } from "node:fs"
import { getAddress, type Hex } from "viem"

type Shipped = Record<string, { name?: string; lb?: string; settle?: string }>

export function lbAddress(chainId: number, file: string, override = process.env.LB_ADDRESS): Hex {
  if (override) return getAddress(override)
  const shipped = JSON.parse(readFileSync(file, "utf8")) as Shipped
  const entry = shipped[String(chainId)]
  if (!entry?.lb) {
    throw new Error(
      `no load balancer address is shipped for chain ${chainId}; set LB_ADDRESS in .env`,
    )
  }
  return getAddress(entry.lb)
}

/** The settle address, or none while no payouts are made on this chain. */
export function settleAddress(
  chainId: number,
  file: string,
  override = process.env.SETTLE_ADDRESS,
): Hex | undefined {
  if (override) return getAddress(override)
  const shipped = JSON.parse(readFileSync(file, "utf8")) as Shipped
  const settle = shipped[String(chainId)]?.settle
  return settle ? getAddress(settle) : undefined
}
