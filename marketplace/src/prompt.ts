// A password read at the terminal with the echo off, through the
// `read` package (npm's own prompt): raw mode, backspace, ctrl-C and
// the muted echo are its job. Piped input is read as one line, so a
// script can answer the prompt too.

import { read, type Options } from "read"

/** The streams default to the process's own; a test hands in its own. */
export function askPassword(
  question: string,
  streams: Pick<Options, "input" | "output"> = {},
): Promise<string> {
  return read({ prompt: question, silent: true, replace: "", ...streams })
}
