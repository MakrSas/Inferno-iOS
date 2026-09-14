#!/usr/bin/env python3
"""Turns the guest's /var/db/diagnostics tarball into a .logarchive the Mac's
`log show` will read.

The guest has no `log` binary, so its os_log store has to be decoded here. An
archive needs three things the tarball does not carry: the uuidtext and dsc
trees that name the format strings, and an Info.plist whose time references
point at the boot the tracev3 files belong to. The first two are taken from a
donor archive built once from the same guest image; the third is written from
the newest boot record in the timesync file.

    guest-logarchive.py <extracted-dir> <donor.logarchive> <out.logarchive>
"""
import datetime
import os
import plistlib
import shutil
import struct
import sys
import uuid


def newest_boot(timesync_dir):
    latest = None
    for name in sorted(os.listdir(timesync_dir)):
        data = open(os.path.join(timesync_dir, name), 'rb').read()
        off = 0
        while off + 48 <= len(data):
            tag, = struct.unpack_from('<H', data, off)
            if tag == 0xbbb0:
                boot = uuid.UUID(bytes=data[off + 8:off + 24])
                wall, = struct.unpack_from('<Q', data, off + 32)
                if latest is None or wall > latest[1]:
                    latest = (str(boot).upper(), wall)
                off += 48
            else:
                off += 32
    if latest is None:
        raise SystemExit('no boot record in %s' % timesync_dir)
    return latest


def main():
    src, donor, out = sys.argv[1], sys.argv[2], sys.argv[3]

    boot, wall = newest_boot(os.path.join(src, 'timesync'))

    if os.path.exists(out):
        shutil.rmtree(out)
    os.makedirs(out)

    # The format-string trees are the same for every run of one guest image.
    for name in ('dsc', 'uuidtext'):
        if os.path.isdir(os.path.join(donor, name)):
            shutil.copytree(os.path.join(donor, name), os.path.join(out, name))
    for name in os.listdir(donor):
        path = os.path.join(donor, name)
        if os.path.isdir(path) and len(name) == 2 and name not in ('dsc',):
            shutil.copytree(path, os.path.join(out, name))

    for name in ('Persist', 'Special', 'Signpost', 'HighVolume', 'timesync', 'Extra'):
        path = os.path.join(src, name)
        if os.path.isdir(path):
            shutil.copytree(path, os.path.join(out, name))

    ref = {'ContinuousTime': 0, 'UUID': boot, 'WallTime': wall}
    # `log show` refuses an archive whose window does not contain the events;
    # an hour past the boot is more than any single run here lasts.
    end = {'ContinuousTime': 3600 * 24 * 1000000000, 'UUID': boot, 'WallTime': wall + 3600 * 1000000000}
    info = {
        'ArchiveIdentifier': str(uuid.uuid4()).upper(),
        'EndTimeRef': end,
        'HighVolumeMetadata': {'OldestTimeRef': ref},
        'HighVolumeSizeLimit': 18446744073709551615,
        'LiveMetadata': {'OldestTimeRef': ref},
        'OSArchiveVersion': 6,
        'OSLoggingSupportProject': 'libtrace-1966.1.1',
        'OSLoggingSupportVersion': 1966.1,
        'PersistMetadata': {'OldestTimeRef': ref},
        'PersistSizeLimit': 18446744073709551615,
        'SignpostMetadata': {'OldestTimeRef': ref},
        'SignpostSizeLimit': 18446744073709551615,
        'SpecialMetadata': {'OldestTimeRef': ref},
        'SpecialSizeLimit': 18446744073709551615,
        'StartTimeRef': ref,
    }
    with open(os.path.join(out, 'Info.plist'), 'wb') as f:
        plistlib.dump(info, f)

    print('boot %s at %s -> %s' % (boot, datetime.datetime.fromtimestamp(wall / 1e9), out))


main()
