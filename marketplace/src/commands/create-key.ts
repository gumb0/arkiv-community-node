// `create-key`: the provider key, made once.

import { existsSync } from "node:fs"
import { askPassword } from "../prompt.ts"
import { createKey, keyAddress } from "../keystore.ts"

export async function createKeyCommand(keystorePath: string): Promise<void> {
  if (existsSync(keystorePath)) {
    console.log(`You already have a key: ${await keyAddress(keystorePath)}`)
    console.log(`It is in ${keystorePath}. Nothing was changed.`)
    return
  }
  console.log("Choose a password for the key file. You will type it again")
  console.log("when a command needs to sign something.")
  const password = await askPassword("Password: ")
  if (password.length < 8) {
    throw new Error("the password must be at least 8 characters")
  }
  const again = await askPassword("Again: ")
  if (again !== password) {
    throw new Error("the passwords do not match")
  }
  const address = await createKey(keystorePath, password)
  console.log(`Created your provider key: ${address}`)
  console.log(`It is in ${keystorePath}. Keep the file and the password:`)
  console.log("this key posts your offer, signs your tunnel token, and receives")
  console.log("your payouts. Fund it with a little GLM for gas before posting.")
}
