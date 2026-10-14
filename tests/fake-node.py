#!/usr/bin/env python3
"""A node for status.sh to look at in tests: execution JSON-RPC on POST,
the beacon node's REST API on GET, from one port.

  fake-node.py <port> <head> [syncing]

The head is the latest block; a block's hash is its number, so two fakes
agree on every block they both have. With "syncing" the beacon node says
it is still syncing and optimistic.
"""

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
HEAD = int(sys.argv[2])
SYNCING = len(sys.argv) > 3 and sys.argv[3] == "syncing"
CHAIN_ID = 999999


def block(number):
    return {"number": hex(number), "hash": f"0x{number:064x}", "timestamp": hex(int(time.time()))}


class Handler(BaseHTTPRequestHandler):
    def answer(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        method, params = request["method"], request.get("params", [])
        if method == "eth_chainId":
            result = hex(CHAIN_ID)
        elif method == "net_peerCount":
            result = "0x3"
        elif method == "eth_getBlockByNumber":
            result = block(HEAD if params[0] == "latest" else int(params[0], 16))
        else:
            result = None
        self.answer({"jsonrpc": "2.0", "id": request.get("id"), "result": result})

    def do_GET(self):
        if self.path == "/eth/v1/node/syncing":
            self.answer({"data": {"is_syncing": SYNCING, "is_optimistic": SYNCING, "el_offline": False}})
        elif self.path == "/eth/v1/node/peer_count":
            self.answer({"data": {"connected": "3"}})
        else:
            self.send_error(404)

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
