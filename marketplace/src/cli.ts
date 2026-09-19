// The command line the wrapper script (marketplace.sh) calls inside
// the container: one subcommand per step of joining the marketplace.

import { existsSync } from "node:fs"
import { writeFile } from "node:fs/promises"
import type { Hex } from "viem"
import { lbAddress, settleAddress } from "./addresses.ts"
import { connectReader, connectWriter } from "./chain.ts"
import { createKeyCommand } from "./commands/create-key.ts"
import { postOffer } from "./commands/post-offer.ts"
import { startTunnel } from "./commands/start-tunnel.ts"
import { status } from "./commands/status.ts"
import { keyAddress, loadKey } from "./keystore.ts"
import { readNode } from "./node.ts"
import { askPassword } from "./prompt.ts"

const KEYSTORE = process.env.MARKETPLACE_KEYSTORE ?? "/secrets/provider-key.json"
const ADDRESSES = process.env.MARKETPLACE_ADDRESSES ?? "addresses.json"
// Where start-tunnel leaves the tunnel settings for marketplace.sh.
const TUNNEL_ENV = process.env.MARKETPLACE_TUNNEL_ENV ?? "/secrets/tunnel.env"
// The node's two clients, on the compose network.
const EL_URL = process.env.NODE_RPC_URL ?? "http://execution:8545"
const CL_URL = process.env.NODE_BEACON_URL ?? "http://consensus:5052"

const usage = `usage: marketplace <command>

  create-key    create your provider key (once)
  post-offer    offer your node to the load balancer
  status        your offer, agreement, counts and payouts
  start-tunnel  sign your tunnel token and write the tunnel settings
`

/** The key's address, or the step that was skipped. */
async function myAddress(): Promise<Hex> {
  if (!existsSync(KEYSTORE)) {
    throw new Error("you have no provider key yet: run ./marketplace.sh create-key first")
  }
  return keyAddress(KEYSTORE)
}

/**
 * The node's answer, or what a node that does not answer means to the
 * operator, instead of the transport's own error text.
 */
async function fromNode<T>(read: () => Promise<T>): Promise<T> {
  try {
    return await read()
  } catch (error) {
    const cause = error instanceof Error ? error.message.split("\n")[0] : String(error)
    throw new Error(
      `your node is not answering at ${EL_URL}: is it running? (docker compose ps)\n  ${cause}`,
    )
  }
}

async function startTunnelCommand(): Promise<void> {
  const me = await myAddress()
  const reader = await fromNode(() => connectReader(EL_URL))
  const outcome = await startTunnel({
    reader,
    lb: lbAddress(reader.chainId, ADDRESSES),
    me,
    privateKey: async () => (await loadKey(KEYSTORE, await askPassword("Key password: "))).privateKey,
    write: (lines) => writeFile(TUNNEL_ENV, lines, { mode: 0o600 }),
    print: (line) => console.log(line),
  })
  if ("refused" in outcome) process.exit(1)
}

async function statusCommand(): Promise<void> {
  const me = await myAddress()
  const reader = await fromNode(() => connectReader(EL_URL))
  await status({
    reader,
    lb: lbAddress(reader.chainId, ADDRESSES),
    settle: settleAddress(reader.chainId, ADDRESSES),
    me,
    print: (line) => console.log(line),
  })
}

async function postOfferCommand(): Promise<void> {
  const me = await myAddress()
  const node = await fromNode(() => readNode(EL_URL, CL_URL))
  const reader = await fromNode(() => connectReader(EL_URL))
  // The key is unlocked only once posting is due, after every refusal.
  const writer = async () => {
    const key = await loadKey(KEYSTORE, await askPassword("Key password: "))
    return connectWriter(EL_URL, reader.chainId, key.privateKey)
  }
  const outcome = await postOffer({
    node,
    reader,
    lb: lbAddress(reader.chainId, ADDRESSES),
    me,
    writer,
    print: (line) => console.log(line),
  })
  if ("refused" in outcome) process.exit(1)
}

async function main(args: string[]): Promise<void> {
  switch (args[0]) {
    case "create-key":
      await createKeyCommand(KEYSTORE)
      return
    case "post-offer":
      await postOfferCommand()
      return
    case "status":
      await statusCommand()
      return
    case "start-tunnel":
      await startTunnelCommand()
      return
    default:
      console.error(usage)
      process.exit(2)
  }
}

main(process.argv.slice(2)).catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error))
  process.exit(1)
})
