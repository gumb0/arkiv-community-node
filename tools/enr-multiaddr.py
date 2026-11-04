#!/usr/bin/env python3
"""Print a libp2p TCP multiaddr for each ENR given, one per line.

Usage: python3 -I tools/enr-multiaddr.py <enr>[,<enr>...]

The consensus client's boot nodes come as ENRs (p2p.yaml, cl_boot_enrs),
but two Lighthouse flags want them in another form: --boot-nodes dials a
multiaddr directly, without waiting for discovery to answer, and
--trusted-peers takes the peer id, the multiaddr's last part. Both come
from fields of the ENR: its secp256k1 key, its IPv4 address and its TCP
port. The ENR's signature is not checked: the network's checksums vouch
for the file it came from.
"""

import base64
import sys

BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def rlp_decode(data):
    """Decode one RLP item: bytes for a string, a list for a list."""

    def item(i):
        prefix = data[i]
        # A single byte below 0x80 is its own value.
        if prefix < 0x80:
            return data[i : i + 1], i + 1
        # A string, its length in the prefix, then in following bytes.
        if prefix < 0xB8:
            end = i + 1 + prefix - 0x80
            return data[i + 1 : end], end
        if prefix < 0xC0:
            size = prefix - 0xB7
            start = i + 1 + size
            end = start + int.from_bytes(data[i + 1 : start], "big")
            return data[start:end], end
        # A list, its length the same two ways.
        if prefix < 0xF8:
            end = i + 1 + prefix - 0xC0
            return items(i + 1, end), end
        size = prefix - 0xF7
        start = i + 1 + size
        end = start + int.from_bytes(data[i + 1 : start], "big")
        return items(start, end), end

    def items(i, end):
        out = []
        while i < end:
            value, i = item(i)
            out.append(value)
        return out

    return item(0)[0]


def base58(data):
    """Bitcoin's base58, which libp2p writes peer ids in."""
    number = int.from_bytes(data, "big")
    text = ""
    while number:
        number, digit = divmod(number, 58)
        text = BASE58[digit] + text
    # Each leading zero byte is a leading "1".
    return "1" * (len(data) - len(data.lstrip(b"\0"))) + text


def multiaddr(enr):
    """The ENR's /ip4/<ip>/tcp/<port>/p2p/<peer id>."""
    if not enr.startswith("enr:"):
        raise ValueError("not an ENR")
    text = enr[4:]
    record = rlp_decode(base64.urlsafe_b64decode(text + "=" * (-len(text) % 4)))
    # The record is [signature, sequence number, key, value, key, value, ...].
    fields = {record[k].decode(): record[k + 1] for k in range(2, len(record) - 1, 2)}
    for name in ("secp256k1", "ip", "tcp"):
        if name not in fields:
            raise ValueError(f"no {name} field")
    # The peer id is the key in libp2p's PublicKey message (type
    # secp256k1, 33 bytes), short enough to be its own multihash
    # (identity, code 0).
    public_key = b"\x08\x02\x12\x21" + fields["secp256k1"]
    peer_id = base58(b"\x00" + bytes([len(public_key)]) + public_key)
    ip = ".".join(str(byte) for byte in fields["ip"])
    port = int.from_bytes(fields["tcp"], "big")
    return f"/ip4/{ip}/tcp/{port}/p2p/{peer_id}"


def main(args):
    if len(args) != 1 or not args[0]:
        print("Usage: python3 -I tools/enr-multiaddr.py <enr>[,<enr>...]", file=sys.stderr)
        return 2
    # All or nothing: a list with one unreadable ENR prints none.
    out = []
    for enr in args[0].split(","):
        try:
            out.append(multiaddr(enr))
        except IndexError:
            print(f"enr-multiaddr: cannot read {enr[:24]}...: the record is cut short", file=sys.stderr)
            return 1
        except ValueError as error:
            print(f"enr-multiaddr: cannot read {enr[:24]}...: {error}", file=sys.stderr)
            return 1
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
