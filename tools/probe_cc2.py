# /// script
# requires-python = ">=3.11"
# dependencies = ["paho-mqtt>=2"]
# ///
"""Measure the Centauri Carbon 2 LAN protocol and record raw payloads as test fixtures.

Credentials come from ElegooSlicer's printer_list.json. The access code is never
printed or written anywhere.

    uv run tools/probe_cc2.py capture --seconds 20 --out FILE
    uv run tools/probe_cc2.py register --client-id ID --out-dir DIR
    uv run tools/probe_cc2.py hold --client-id ID [--no-ping]
    uv run tools/probe_cc2.py connect-test --password-override X
"""

import argparse
import json
import queue
import sys
import time
from pathlib import Path

import paho.mqtt.client as mqtt

PRINTER_LIST = Path.home() / "Library/Application Support/ElegooSlicer/user/printer_list.json"
USERNAME = "elegoo"
GET_BASIC_INFO = 1002


def load_printer() -> dict:
    entries = json.loads(PRINTER_LIST.read_text()).values()
    cc2 = [e for e in entries if "Centauri Carbon 2" in e.get("printerModel", "")]
    if not cc2:
        sys.exit("no Centauri Carbon 2 entry in printer_list.json")
    return max(cc2, key=lambda e: e.get("lastActiveTime", 0))


def connect(client_id: str, password: str, host: str) -> tuple[mqtt.Client, queue.Queue]:
    inbox: queue.Queue = queue.Queue()
    connected: queue.Queue = queue.Queue()
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=client_id)
    client.username_pw_set(USERNAME, password)
    client.on_connect = lambda c, u, f, rc, p=None: connected.put(rc)
    client.on_message = lambda c, u, m: inbox.put((m.topic, m.payload))
    client.connect(host, 1883, 30)
    client.loop_start()
    rc = connected.get(timeout=10)
    if rc.is_failure:
        client.loop_stop()
        sys.exit(f"connect refused: {rc} (value {rc.value})")
    return client, inbox


def wait_for(inbox: queue.Queue, topic: str, seconds: float) -> bytes | None:
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            got_topic, payload = inbox.get(timeout=max(0.1, deadline - time.time()))
        except queue.Empty:
            return None
        if got_topic == topic:
            return payload
    return None


def cmd_capture(args, printer) -> None:
    client, inbox = connect(f"cc2probe_{int(time.time())}", printer["accessCode"], printer["host"])
    topic = f"elegoo/{printer['serialNumber']}/api_status"
    client.subscribe(topic)
    lines = []
    deadline = time.time() + args.seconds
    while time.time() < deadline:
        try:
            _, payload = inbox.get(timeout=max(0.1, deadline - time.time()))
            lines.append(payload.decode())
        except queue.Empty:
            break
    client.loop_stop()
    Path(args.out).write_text("".join(line + "\n" for line in lines))
    methods = sorted({json.loads(line).get("method") for line in lines})
    print(f"{len(lines)} messages in {args.seconds} s, methods {methods} -> {args.out}")


def register(client, inbox, sn: str, client_id: str) -> bytes | None:
    client.subscribe(f"elegoo/{sn}/{client_id}/register_response")
    client.subscribe(f"elegoo/{sn}/{client_id}/api_response")
    time.sleep(0.5)
    client.publish(f"elegoo/{sn}/api_register", json.dumps({"request_id": client_id}))
    return wait_for(inbox, f"elegoo/{sn}/{client_id}/register_response", 5)


def cmd_register(args, printer) -> None:
    sn, cid, out = printer["serialNumber"], args.client_id, Path(args.out_dir)
    client, inbox = connect(cid, printer["accessCode"], printer["host"])
    response = register(client, inbox, sn, cid)
    if response is None:
        client.loop_stop()
        sys.exit("no register_response within 5 s")
    error = json.loads(response).get("error")
    name = {
        "ok": "register_ok.json",
        "already registered": "register_already.json",
        "too many clients": "register_too_many.json",
    }.get(error, "register_other.json")
    (out / name).write_bytes(response)
    print(f"register error field: {error!r} -> {name}")
    if error in ("ok", "already registered"):
        response_topic = f"elegoo/{sn}/{cid}/api_response"
        client.publish(f"elegoo/{sn}/{cid}/api_request", json.dumps({"id": 1, "method": GET_BASIC_INFO, "params": {}}))
        snapshot = wait_for(inbox, response_topic, 5)
        if snapshot is not None:
            (out / "get_basic_info_response.json").write_bytes(snapshot)
        print(f"GetBasicInfo: {'recorded' if snapshot else 'no response'}")
        client.publish(f"elegoo/{sn}/{cid}/api_request", json.dumps({"type": "PING"}))
        pong = wait_for(inbox, response_topic, 5)
        if pong is not None:
            (out / "pong.json").write_bytes(pong)
        print(f"PING: {pong.decode() if pong else 'no response'}")
    client.loop_stop()


def cmd_hold(args, printer) -> None:
    sn, cid = printer["serialNumber"], args.client_id
    client, inbox = connect(cid, printer["accessCode"], printer["host"])
    response = register(client, inbox, sn, cid)
    print(f"register: {response.decode() if response else 'no response'}")
    try:
        while True:
            if not args.no_ping:
                client.publish(f"elegoo/{sn}/{cid}/api_request", json.dumps({"type": "PING"}))
            reply = wait_for(inbox, f"elegoo/{sn}/{cid}/api_response", 10)
            print(time.strftime("%H:%M:%S"), reply.decode() if reply else "no reply")
    except KeyboardInterrupt:
        client.disconnect()
        client.loop_stop()


def cmd_connect_test(args, printer) -> None:
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"cc2probe_{int(time.time())}")
    client.username_pw_set(USERNAME, args.password_override)
    result: queue.Queue = queue.Queue()
    client.on_connect = lambda c, u, f, rc, p=None: result.put(rc)
    client.connect(printer["host"], 1883, 30)
    client.loop_start()
    rc = result.get(timeout=10)
    client.loop_stop()
    print(f"CONNACK: {rc} (value {rc.value})")


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("capture")
    p.add_argument("--seconds", type=int, default=20)
    p.add_argument("--out", required=True)
    p = sub.add_parser("register")
    p.add_argument("--client-id", required=True)
    p.add_argument("--out-dir", required=True)
    p = sub.add_parser("hold")
    p.add_argument("--client-id", required=True)
    p.add_argument("--no-ping", action="store_true")
    p = sub.add_parser("connect-test")
    p.add_argument("--password-override", required=True)
    args = parser.parse_args()
    handler = {"capture": cmd_capture, "register": cmd_register, "hold": cmd_hold, "connect-test": cmd_connect_test}[
        args.cmd
    ]
    handler(args, load_printer())


if __name__ == "__main__":
    main()
