#!/usr/bin/env python3
"""Assert the browser terminal is attached to a LIVE tmux session.

The HTTP/WS smoke tests only prove ttyd is reachable (200 / 404 / 101). ttyd
happily upgrades the WebSocket and serves its page even when `tmux attach`
finds nothing and prints "no sessions" into the terminal (as happened when a
PrivateTmp namespace hid the tmux control socket from the ttyd service). This
opens the ttyd WebSocket, performs the ttyd handshake, reads the terminal
output the session produces on attach, and fails if it looks empty or shows a
tmux "no sessions" / "no server" error.

Usage: ws_smoke.py <web_url>     # web_url = https://<host>/<token>/
"""
import json
import sys
import time

from websocket import create_connection, ABNF

# ttyd protocol: server->client output frames are prefixed with '0'.
OUTPUT = ord("0")

# tmux emits one of these when the requested session/server is absent.
FAILURE_MARKERS = ("no sessions", "no server running", "error connecting")

READ_SECONDS = 12


def main() -> int:
    web_url = sys.argv[1].rstrip("/") + "/"
    ws_url = web_url.replace("https://", "wss://", 1).replace("http://", "ws://", 1) + "ws"

    conn = create_connection(ws_url, subprotocols=["tty"], timeout=15)
    # First message is ttyd's init: auth token (empty — we authenticate via the
    # URL path) plus the initial window size. A generous width avoids the tmux
    # status line wrapping into noise.
    conn.send(json.dumps({"AuthToken": "", "columns": 220, "rows": 50}))

    collected = bytearray()
    conn.settimeout(2)
    deadline = time.time() + READ_SECONDS
    while time.time() < deadline:
        try:
            frame = conn.recv_frame()
        except Exception:
            continue
        if frame is None or frame.opcode not in (ABNF.OPCODE_BINARY, ABNF.OPCODE_TEXT):
            continue
        data = frame.data if isinstance(frame.data, (bytes, bytearray)) else frame.data.encode()
        if data and data[0] == OUTPUT:
            collected += data[1:]

    try:
        conn.close()
    except Exception:
        pass

    text = collected.decode("utf-8", "replace")
    lowered = text.lower()

    for marker in FAILURE_MARKERS:
        if marker in lowered:
            print(f"::error::Terminal attached but tmux reported '{marker}' — no live session.")
            print(text[:2000])
            return 1

    # A live session (agent UI or a shell + tmux status line) always paints
    # something on attach. Near-empty output means the terminal is dead.
    if len(text.strip()) < 16:
        print(f"::error::Terminal produced almost no output ({len(text.strip())} bytes) — session not alive.")
        print(repr(text[:2000]))
        return 1

    print(f"::notice::Live tmux session confirmed ({len(text)} bytes of terminal output on attach).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
