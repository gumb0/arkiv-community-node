// `start-tunnel`: once the offer is accepted, the tunnel client's
// settings from the agreement and the listing: the server to dial, the
// port assigned to this node, and the signed token. Written to a file
// the wrapper script merges into .env before it renders and starts the
// tunnel; the operator types none of it.

import type { Hex } from "viem"
import type { Reader } from "../chain.ts"
import { KIND, alive, attrAddr, byKind, creator, decodeAgreement, decodeListing } from "../records.ts"
import { signToken } from "../token.ts"

const DEFAULT_TUNNEL_PORT = 7000

export type StartTunnel = {
  reader: Reader
  lb: Hex
  me: Hex
  /** Unlocks the key; asked for only once there is an agreement to sign. */
  privateKey: () => Promise<Hex>
  /** Where the settings go, for the wrapper to pick up. */
  write: (lines: string) => Promise<void>
  print: (line: string) => void
}

export type Outcome = { written: Record<string, string> } | { refused: string }

export async function startTunnel(o: StartTunnel): Promise<Outcome> {
  const head = await o.reader.head()

  const agreement = (
    await o.reader.query(byKind(KIND.agreement, creator(o.lb), attrAddr("provider", o.me), alive(head)))
  ).map(decodeAgreement)[0]
  if (!agreement) {
    return refuse(o, "you have no agreement yet. Post an offer with post-offer, then check status; the load balancer answers within minutes.")
  }

  const listings = (await o.reader.query(byKind(KIND.listing, creator(o.lb), alive(head)))).map(decodeListing)
  listings.sort((a, b) => (a.expiresAt < b.expiresAt ? -1 : 1))
  const listing = listings[0]
  if (!listing) {
    return refuse(o, `the load balancer's listing is gone from chain ${o.reader.chainId}; it is not running.`)
  }
  const [host, port] = splitHostPort(listing.tunnelServer)

  const token = await signToken(await o.privateKey(), agreement.key)
  const values: Record<string, string> = {
    TUNNEL_SERVER_ADDR: host,
    TUNNEL_SERVER_PORT: String(port),
    TUNNEL_REMOTE_PORT: String(agreement.remotePort),
    TUNNEL_AGREEMENT: agreement.key,
    TUNNEL_TOKEN: token,
  }
  await o.write(
    Object.entries(values)
      .map(([name, value]) => `${name}=${value}\n`)
      .join(""),
  )
  o.print(`Agreement ${agreement.key}: tunnel server ${host}:${port}, your port ${agreement.remotePort}.`)
  o.print("Signed the tunnel token with your key.")
  return { written: values }
}

/** "host:port", or "host" alone at the tunnel server's usual port. */
export function splitHostPort(address: string): [string, number] {
  const at = address.lastIndexOf(":")
  if (at < 0) return [address, DEFAULT_TUNNEL_PORT]
  const port = Number(address.slice(at + 1))
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`the listing's tunnel server ${address} has no valid port`)
  }
  return [address.slice(0, at), port]
}

function refuse(o: StartTunnel, why: string): Outcome {
  o.print(`Not starting the tunnel: ${why}`)
  return { refused: why }
}
