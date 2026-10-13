// The tunnel token: the agreement id signed by the provider key as an
// EIP-191 personal message. The tunnel server admits the client whose
// token was made by the agreement's provider. Nobody without the key can
// make one, but anyone who has a copy can use it while the agreement
// lives, so it is kept as private as the key.

import { privateKeyToAccount } from "viem/accounts"
import type { Hex } from "viem"

/** The signed text: a prefix that keeps the signature good for nothing else, then the id. */
export function tokenMessage(agreement: Hex): string {
  return `arkiv-rpc:${agreement.toLowerCase()}`
}

export function signToken(privateKey: Hex, agreement: Hex): Promise<Hex> {
  return privateKeyToAccount(privateKey).signMessage({ message: tokenMessage(agreement) })
}
