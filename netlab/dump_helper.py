"""Compact re-read of the device's configurations."""

from tcpusb import DESC_CONFIG, DESC_DEVICE, UsbError


def summarise(link):
    dev = link.get_descriptor(DESC_DEVICE, 0, 18)
    print(f"  конфигураций: {dev[17]}")
    for index in range(dev[17]):
        try:
            head = link.get_descriptor(DESC_CONFIG, index, 9)
            total = int.from_bytes(head[2:4], "little")
            raw = link.get_descriptor(DESC_CONFIG, index, total)
        except UsbError as exc:
            print(f"  #{index}: {exc}")
            continue
        name = link.string(raw[6])
        parts = []
        i = 0
        while i + 1 < len(raw):
            length = raw[i]
            if length == 0:
                break
            if raw[i + 1] == 0x04 and length >= 9:
                parts.append(f"i{raw[i + 2]}a{raw[i + 3]}:{raw[i + 5]:02x}/{raw[i + 6]:02x}/{raw[i + 7]:02x}")
            i += length
        print(f"  #{index} value={raw[5]} «{name}»: {' '.join(parts)}")
