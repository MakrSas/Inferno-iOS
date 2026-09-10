#!/usr/bin/env python3
"""Asks the device to switch USB mode, then looks at what it becomes.

usbmuxd does this with a vendor request before anything else — that is what
`USBMUXD_DEFAULT_DEVICE_MODE=3` in the ChefKiss guide sets. The device answers
by re-enumerating with a different set of configurations, which is where the
CDC-NCM interfaces the guest registers but never exposes are expected to appear.
"""

import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from dump_helper import summarise
from tcpusb import DESC_DEVICE, Link, UsbError, listen

SOCK = "/tmp/iusb.sock"

# usbmuxd sends both of these as vendor IN requests to the device.
VENDOR_IN = 0xC0
REQ_GET_MODE = 0x45     # 4 bytes back: 3:3:3:0 initial, 5:3:3:0 otherwise
REQ_SET_MODE = 0x52     # desired mode goes in wIndex, one byte back


def main():
    modes = [int(x) for x in sys.argv[1:]] or [3]

    srv = listen(SOCK)
    print(f"Слушаю {SOCK}…")
    conn, _ = srv.accept()
    print("Эмулятор подключился.")
    time.sleep(1.0)

    link = Link(conn)
    link.reset()
    print(f"GET_MODE → {link.control(VENDOR_IN, REQ_GET_MODE, 0, 0, 4).hex()}")
    print("\n=== до смены режима ===")
    summarise(link)

    for mode in modes:
        print(f"\n→ SET_MODE wIndex={mode}")
        try:
            answer = link.control(VENDOR_IN, REQ_SET_MODE, 0, mode, 1)
            print(f"   ответ: {answer.hex()}")
        except UsbError as exc:
            print(f"   отказ: {exc}")
            continue

        # A mode change makes the device drop off the bus and come back, so the
        # old link dies and the emulator dials in again.
        print("   жду переподключения…")
        try:
            conn.close()
        except OSError:
            pass
        srv.settimeout(60)
        try:
            conn, _ = srv.accept()
        except OSError as exc:
            print(f"   не дождался: {exc}")
            return
        print("   переподключился")
        time.sleep(1.5)
        link = Link(conn)
        try:
            link.reset()
            link.get_descriptor(DESC_DEVICE, 0, 18)
        except UsbError as exc:
            print(f"   после сброса: {exc}")
        try:
            print(f"GET_MODE → {link.control(VENDOR_IN, REQ_GET_MODE, 0, 0, 4).hex()}")
        except UsbError as exc:
            print(f"GET_MODE: {exc}")
        print(f"=== после режима {mode} ===")
        try:
            summarise(link)
        except UsbError as exc:
            print(f"   не перечитать: {exc}")


if __name__ == "__main__":
    try:
        main()
    except (ConnectionError, KeyboardInterrupt) as exc:
        print(f"\nЗавершено: {exc}")
    except UsbError as exc:
        print(f"\nUSB: {exc}")
