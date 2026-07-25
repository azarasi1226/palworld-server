#!/usr/bin/env python3
"""Source RCON クライアント (Python 標準ライブラリのみ)。

Palworld 向けの注意:
- 認証応答の ID が仕様どおりでない場合があるため、type==2 の応答を認証成功とみなす
- 応答パケットの文字列が NUL 終端されていないことがあるため rstrip で処理する

使い方: rcon.py --host 127.0.0.1 --port 25575 --password X "ShowPlayers"
"""

import argparse
import socket
import struct
import sys

SERVERDATA_AUTH = 3
SERVERDATA_AUTH_RESPONSE = 2
SERVERDATA_EXECCOMMAND = 2
SERVERDATA_RESPONSE_VALUE = 0


def build_packet(req_id: int, ptype: int, body: str) -> bytes:
    payload = struct.pack("<ii", req_id, ptype) + body.encode("utf-8") + b"\x00\x00"
    return struct.pack("<i", len(payload)) + payload


def read_packet(sock: socket.socket):
    raw_len = recv_exact(sock, 4)
    (length,) = struct.unpack("<i", raw_len)
    if length < 10 or length > 4110:
        raise ValueError(f"invalid packet length: {length}")
    data = recv_exact(sock, length)
    req_id, ptype = struct.unpack("<ii", data[:8])
    body = data[8:].rstrip(b"\x00").decode("utf-8", errors="replace")
    return req_id, ptype, body


def recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("connection closed by server")
        buf += chunk
    return buf


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=25575)
    ap.add_argument("--password", required=True)
    ap.add_argument("--timeout", type=float, default=10.0)
    ap.add_argument("command")
    args = ap.parse_args()

    try:
        with socket.create_connection((args.host, args.port), timeout=args.timeout) as sock:
            sock.settimeout(args.timeout)

            sock.sendall(build_packet(1, SERVERDATA_AUTH, args.password))
            req_id, ptype, _ = read_packet(sock)
            # 一部実装は AUTH 前に空の RESPONSE_VALUE を返す
            if ptype == SERVERDATA_RESPONSE_VALUE:
                req_id, ptype, _ = read_packet(sock)
            if ptype != SERVERDATA_AUTH_RESPONSE or req_id == -1:
                print("auth failed", file=sys.stderr)
                return 2

            sock.sendall(build_packet(2, SERVERDATA_EXECCOMMAND, args.command))
            _, _, body = read_packet(sock)
            if body:
                print(body)
            return 0
    except (OSError, ValueError, ConnectionError) as e:
        print(f"rcon error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
