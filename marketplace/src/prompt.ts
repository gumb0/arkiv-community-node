// A password read from the terminal with the echo off. The commands
// run in a container with a terminal attached (`docker compose run`),
// and a password must never show on screen or land in a log.

import { stdin, stdout } from "node:process"

const ENTER = ["\r", "\n"]
const CTRL_C = ""
const BACKSPACE = ["", "\b"]

export async function askPassword(question: string): Promise<string> {
  if (!stdin.isTTY) {
    throw new Error("a password prompt needs a terminal")
  }
  stdout.write(question)
  stdin.setRawMode(true)
  stdin.resume()
  stdin.setEncoding("utf8")
  let password = ""
  try {
    for await (const chunk of stdin) {
      for (const char of chunk as string) {
        if (ENTER.includes(char)) {
          stdout.write("\n")
          return password
        }
        if (char === CTRL_C) {
          stdout.write("\n")
          process.exit(130)
        }
        if (BACKSPACE.includes(char)) {
          password = password.slice(0, -1)
        } else {
          password += char
        }
      }
    }
    return password
  } finally {
    stdin.setRawMode(false)
    stdin.pause()
  }
}
