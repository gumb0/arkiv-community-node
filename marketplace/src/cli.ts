// The command line the wrapper script (marketplace.sh) calls inside
// the container: one subcommand per step of joining the marketplace.

import { lbAddress } from "./addresses.ts"
import { connectReader, connectWriter } from "./chain.ts"
import { createKeyCommand } from "./commands/create-key.ts"
import { postOffer } from "./commands/post-offer.ts"
import { keyAddress, loadKey } from "./keystore.ts"
import { readNode } from "./node.ts"
import { askPassword } from "./prompt.ts"

const KEYSTORE = process.env.MARKETPLACE_KEYSTORE ?? "/secrets/provider-key.json"
const ADDRESSES = process.env.MARKETPLACE_ADDRESSES ?? "addresses.json"
// The node's two clients, on the compose network.
const EL_URL = process.env.NODE_RPC_URL ?? "http://execution:8545"
const CL_URL = process.env.NODE_BEACON_URL ?? "http://consensus:5052"

const usage = `usage: marketplace <command>

  create-key    create your provider key (once)
  post-offer    offer your node to the load balancer
`

async function postOfferCommand(): Promise<void> {
  const me = await keyAddress(KEYSTORE)
  const node = await readNode(EL_URL, CL_URL)
  const reader = await connectReader(EL_URL)
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
    default:
      console.error(usage)
      process.exit(2)
  }
}

main(process.argv.slice(2)).catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error))
  process.exit(1)
})
