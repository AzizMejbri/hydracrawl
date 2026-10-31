#!/usr/bin/env python3
"""Tiny RESP client for hydracrawl.

Examples:
    python3 resp_cli.py PING
    python3 resp_cli.py SET greeting "hello world"
    python3 resp_cli.py GET greeting
    python3 resp_cli.py

The script builds RESP arrays for you, so you never type \r\n yourself.
"""

import argparse
import shlex
import socket
import sys

CRLF = b"\r\n"


def encode_command(parts):
    out = bytearray(b"*%d\r\n" % len(parts))
    for part in parts:
        data = part.encode("utf-8")
        out += b"$%d\r\n" % len(data)
        out += data + CRLF
    return bytes(out)


class RespReader:
    def __init__(self, sock):
        self.sock = sock
        self.buf = bytearray()

    def _fill(self):
        chunk = self.sock.recv(65536)
        if not chunk:
            raise ConnectionError("server closed the connection")
        self.buf += chunk

    def _line(self):
        while True:
            end = self.buf.find(CRLF)
            if end >= 0:
                line = bytes(self.buf[:end])
                del self.buf[: end + 2]
                return line
            self._fill()

    def _exact(self, size):
        while len(self.buf) < size:
            self._fill()
        data = bytes(self.buf[:size])
        del self.buf[:size]
        return data

    def read_reply(self):
        line = self._line()
        if not line:
            raise ValueError("empty RESP line")

        kind = line[:1]
        body = line[1:]

        if kind == b"+":
            return "simple", body.decode("utf-8", "backslashreplace")
        if kind == b"-":
            return "error", body.decode("utf-8", "backslashreplace")
        if kind == b":":
            return "integer", int(body)
        if kind == b"$":
            size = int(body)
            if size == -1:
                return "bulk", None
            data = self._exact(size)
            if self._exact(2) != CRLF:
                raise ValueError("bulk string missing CRLF")
            return "bulk", data
        if kind == b"*":
            size = int(body)
            if size == -1:
                return "array", None
            return "array", [self.read_reply() for _ in range(size)]

        raise ValueError(f"unknown RESP type {kind!r}")


def format_reply(kind, value, indent=0):
    pad = " " * indent
    if kind == "simple":
        return f"{pad}(simple) {value}"
    if kind == "error":
        return f"{pad}(error) {value}"
    if kind == "integer":
        return f"{pad}(integer) {value}"
    if kind == "bulk":
        if value is None:
            return f"{pad}(bulk) nil"
        return f"{pad}(bulk) {value.decode('utf-8', 'backslashreplace')!r}"
    if kind == "array":
        if value is None:
            return f"{pad}(array) nil"
        lines = [f"{pad}(array)"]
        for item_kind, item_value in value:
            lines.append(format_reply(item_kind, item_value, indent + 2))
        return "\n".join(lines)
    return f"{pad}{kind}: {value!r}"


def send_and_print(sock, reader, parts):
    sock.sendall(encode_command(parts))
    reply = reader.read_reply()
    print(format_reply(*reply))
    return 0 if reply[0] != "error" else 1


def interactive(sock, reader):
    prompt = "resp> " if sys.stdin.isatty() else ""
    while True:
        try:
            line = input(prompt)
        except EOFError:
            print()
            return 0
        except KeyboardInterrupt:
            print()
            return 0

        line = line.strip()
        if not line:
            continue
        if line in {"quit", "exit", ":q"}:
            return 0
        try:
            parts = shlex.split(line)
        except ValueError as exc:
            print(f"input error: {exc}", file=sys.stderr)
            continue

        try:
            send_and_print(sock, reader, parts)
        except (ConnectionError, OSError, ValueError) as exc:
            print(f"request failed: {exc}", file=sys.stderr)
            return 1


def main():
    parser = argparse.ArgumentParser(description="Send RESP commands to hydracrawl")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=6378, type=int)
    parser.add_argument("--timeout", default=2.0, type=float)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    sock = None
    try:
        sock = socket.create_connection((args.host, args.port), timeout=args.timeout)
        sock.settimeout(args.timeout)
        reader = RespReader(sock)

        if args.command:
            return send_and_print(sock, reader, args.command)
        return interactive(sock, reader)
    except (ConnectionError, OSError, ValueError, socket.timeout) as exc:
        print(f"connection failed: {exc}", file=sys.stderr)
        return 1
    finally:
        if sock is not None:
            sock.close()


if __name__ == "__main__":
    raise SystemExit(main())
