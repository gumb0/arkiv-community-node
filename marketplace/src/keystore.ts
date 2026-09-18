// The provider key: one secp256k1 key in a standard encrypted keystore
// file (the web3 keystore format every wallet imports), created once
// and unlocked with a password when a command needs to sign. The key
// posts the offer, signs the tunnel token and receives the payouts, so
// the file is the one thing an operator must keep.

import { existsSync } from "node:fs"
import { readFile, writeFile } from "node:fs/promises"
import { Wallet } from "ethers"
import { getAddress, type Hex } from "viem"

export type ProviderKey = { address: Hex; privateKey: Hex }

/** Creates a fresh key at `path`. Refuses to touch an existing file. */
export async function createKey(path: string, password: string): Promise<Hex> {
  if (existsSync(path)) {
    throw new Error(`${path} already exists: the key is created once`)
  }
  const wallet = Wallet.createRandom()
  const json = await wallet.encrypt(password)
  await writeFile(path, json, { mode: 0o600, flag: "wx" })
  return wallet.address as Hex
}

/** Unlocks the key at `path`. A wrong password is an error, not a key. */
export async function loadKey(path: string, password: string): Promise<ProviderKey> {
  const json = await readFile(path, "utf8")
  const wallet = await Wallet.fromEncryptedJson(json, password)
  return { address: wallet.address as Hex, privateKey: wallet.privateKey as Hex }
}

/**
 * The address a keystore file holds, without the password. Returned
 * checksummed, the way every other address is shown.
 */
export async function keyAddress(path: string): Promise<Hex> {
  const json = JSON.parse(await readFile(path, "utf8")) as { address?: string }
  if (typeof json.address !== "string") {
    throw new Error(`${path} is not a keystore file`)
  }
  // Keystore writers differ: ethers and geth store the address
  // lowercase without the 0x prefix, some tools with it.
  const hex = json.address.startsWith("0x") ? json.address : `0x${json.address}`
  return getAddress(hex)
}
