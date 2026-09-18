// The load balancer's address, a network value shipped with the
// distribution and keyed by chain id, like genesis and bootnodes. An
// LB_ADDRESS in .env overrides it, for a private deployment.

import { readFileSync } from "node:fs"
import { getAddress, type Hex } from "viem"

type Shipped = Record<string, { name?: string; lb?: string }>

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
