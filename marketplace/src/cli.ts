// The command line the wrapper script (marketplace.sh) calls inside
// the container: one subcommand per step of joining the marketplace.

import { createKeyCommand } from "./commands/create-key.ts"

const KEYSTORE = process.env.MARKETPLACE_KEYSTORE ?? "/secrets/provider-key.json"

const usage = `usage: marketplace <command>

  create-key    create your provider key (once)
`

async function main(args: string[]): Promise<void> {
  switch (args[0]) {
    case "create-key":
      await createKeyCommand(KEYSTORE)
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
