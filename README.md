# Inferno for iPhone

An emulated iPhone 11, running as an app on a real iPhone.

This is a SwiftUI front end for [Inferno](https://github.com/ChefKissInc/Inferno) — ChefKiss's
QEMU fork that emulates Apple's T8030 (A13) platform well enough to boot iOS 14. The emulator is
built as a library and loaded into the app, so there is no helper process, no server, and nothing
to connect to: the machine runs inside the app that draws it.

> Inferno itself is by [@HeWhomCodes](https://github.com/ChefKissInc). This repository is the iOS
> app around it, plus the changes to the emulator that iOS made necessary.

---

## What works

- **The guest's screen**, drawn from the emulator's own framebuffer memory — no VNC, no encoding,
  no socket. Touches land where your finger is.
- **Device buttons** — side button, volume, home.
- **Internet in the guest, with no companion VM.** The app is its own USB host: it switches the
  emulated device into CDC-NCM mode and lets traffic out through slirp. `apt` works.
- **File transfer both ways**, over that same link — about 500 KB/s. Files sent to the guest land
  where the guest's own Files app can see them.
- **A shell into the guest**, on a channel of its own so the kernel log does not shred it.
- **A real terminal**, not a log view: eighty columns, colours, cursor movement. `neofetch` draws
  its logo beside the text, `apt` redraws its progress line in place.

## What does not

- **Speed.** There is no KVM on iOS and there never will be — everything is translated. Boot takes
  minutes, not seconds.
- **Only 3 GiB.** iOS kills a process at exactly that, entitlement or no entitlement, so the guest
  gets 2 GB and the rest is the app's own.
- **Only 828×1792.** The machine accepts other panel sizes and the guest boots on them, but iOS
  then draws nothing at all. Not solved.
- **The guest sometimes drops its own network** after using it — a known iOS behaviour, worked
  around by asking it to bring the interface back up.

---

## What you need

**A jailbroken guest image.** Not distributed here, and not optional. Follow ChefKiss's guides to
build one, then apply the jailbreak bootstrap:

- [Inferno setup](https://chefkiss.dev/guides/inferno/)
- [Jailbreak bootstrap](https://chefkiss.dev/guides/inferno-post-setup/jailbreak-bootstrap/)

> **The bootstrap is required, not a nicety.** Without bash on the guest's console there is no file
> transfer, no shell, and no way to bring the network up from inside. Half of what this app does
> talks to that shell.

**A device that can run the app with JIT.** The translator has to make memory executable, which iOS
does not allow on its own. [StikDebug](https://github.com/StephenDev0/StikDebug) provides it.

**About 9 GB free** for the guest image.

---

## Installing

1. **Build the guest image** by ChefKiss's guide, and apply the jailbreak patches.

2. **Install `Inferno.ipa` and StikDebug** with any sideloading tool — iLoader, AltStore, Sideloadly.

   StikDebug also needs **LocalDevVPN**, which is on the App Store. It is not a VPN in the usual
   sense — it is what lets the debugger reach the device over its own loopback.

3. **Set StikDebug up**: turn LocalDevVPN on, and put your pairing file into StikDebug (iLoader can
   hand it over).

4. **Launch Inferno through StikDebug**, so it starts with JIT. Then check that the app's folder has
   appeared in Files → On My iPhone → Inferno.

5. **Copy the guest images in.** Put `AppleSEPROM-Cebu-B1` and the `InfernoData` folder into that
   folder. The empty directories are already there; the files go straight into them:

   ```
   AppleSEPROM-Cebu-B1
   InfernoData/root.qcow2        (or root — the raw image)
   InfernoData/firmware
   InfernoData/syscfg
   InfernoData/ctrl_bits
   InfernoData/nvram
   InfernoData/effaceable
   InfernoData/panic_log
   InfernoData/sep_nvram
   InfernoData/sep_ssc
   InfernoData/root_ticket.der
   InfernoData/sep-firmware.n104.RELEASE.new.img4
   InfernoData/Restore/kernelcache.release.iphone12b
   InfernoData/Restore/Firmware/038-44135-124.dmg.trustcache
   InfernoData/Restore/Firmware/all_flash/DeviceTree.n104ap.im4p
   ```

   > **Take `root.qcow2`, not the raw `root`.** The raw image is nominally 34 GB holding about 9 GB
   > of data, and it relies on the file being sparse — which copying to a phone loses. The qcow2 is
   > its real size however you move it.

6. **Relaunch the app through StikDebug**, open the menu and start the machine.

**Always start it through StikDebug.** Without JIT the emulator does not fail cleanly — it wedges on
the first translated instruction, which looks like a hang and is much harder to read than a refusal.
The app checks and refuses instead.

---

## Using it

**The button** in the corner opens everything: the view (screen or terminal), starting and stopping
the machine, files, device buttons. Drag it wherever you like.

**Network.** On by default. If the guest never takes an address, the menu has *Bring the network up
in the guest*, which runs `ipconfig set en0 DHCP` on its console — the same thing the stock guide
tells you to type by hand.

**Files.** *Send a file to the guest* puts it where the guest's own Files app will find it.
*Fetch a file from the guest* takes a path and saves it into the app's `Guest` folder, visible in
Files on the host phone.

**The shell.** The terminal's *Shell* tab opens a channel into the guest. Where the network is up it
goes over a socket; where it is not, it falls back to the console with the shell's output marked so
the kernel's cannot be mistaken for it.

**Settings** hold everything else: cores, memory, translator, screen, terminal, language, and
diagnostics.

---

## Building

The emulator lives in its own repository — a fork of Inferno carrying the changes iOS needed: the
USB-NCM host, the built-in display, the coalesced UART, the address-space memory patch. Clone it
beside this one:

```bash
git clone <your-fork-of-ChefKissInc/Inferno> inferno-src
```

Meson cross-files hold absolute paths — the SDK, the toolchain, wherever the dependencies were
built — so this one is generated rather than committed:

```bash
PREFIX=path/to/built/deps ./make-cross-file.sh
```

Then build the emulator as a shared library for iOS:

```bash
meson setup build/inferno inferno-src \
  --cross-file=cross-ios-arm64.txt \
  -Dbuildtype=release -Dprefix=$PWD/prefix \
  -Dshared_lib=true -Db_staticpic=true -Dwerror=false \
  -Dkvm=disabled -Dhvf=disabled -Dwhpx=disabled \
  -Dcocoa=disabled -Dgtk=disabled -Dsdl=disabled -Dcurses=disabled \
  -Dcoreaudio=disabled -Dcurl=disabled -Dlibssh=disabled -Dbzip2=disabled \
  -Dvnc=enabled -Dvnc_jpeg=disabled -Dvnc_sasl=disabled \
  -Dtools=disabled -Dcoroutine_backend=ucontext

ninja -C build/inferno libqemu-aarch64-softmmu.dylib
```

`-Dshared_lib=true` is what makes it a library rather than a program; `ucontext` replaces the
coroutine backend because iOS has no usable `sigaltstack`. VNC stays enabled — the app draws from
the framebuffer directly, but the VNC path is still there as a fallback in the settings.

Then the app:

```bash
cd app && ./build.sh
```

`build.sh` compiles the SwiftUI front end with `swiftc`, bundles the emulator library, renders the
app icon with `actool`, ad-hoc signs everything and produces `Inferno.ipa`. It needs Xcode's command
line tools and nothing else — there is no Xcode project.

---

## Helping out

Most of what was learned here is written down, because most of it was expensive to learn.

- **[`TODO.md`](TODO.md)** — everything still open, with the reasoning behind each item and what was
  already ruled out. The best place to start.
- **[`FINDINGS.md`](FINDINGS.md)** — how the SEP panic was actually diagnosed. Worth reading not for
  the answer but for the method: a controlled A/B on identical state, which is what finally
  separated a real cause from three plausible ones.
- **[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)** — the traps, and there are many. The console has no
  flow control. A path with a space in it will not survive a long command. `"\r\n"` is one
  `Character` in Swift, and its `asciiValue` is a line feed.
- **[`ANDROID-PORT.md`](ANDROID-PORT.md)** — what the same app on Android would take. Android is the
  easier platform: executable memory is allowed, so no JIT helper, no split-wx, no 3 GiB ceiling.
- **[`HAPTICS-NOTES.md`](HAPTICS-NOTES.md)** — passing the guest's vibration through to the real
  phone.

### The test stand

Trying something against the guest on the phone costs a boot of several minutes. `macos-repro.sh`
runs the same machine natively on a Mac against a qcow2 overlay, so a hypothesis costs a minute and
leaves the real image untouched:

```bash
INFERNO_SRC=path/to/fork INFERNO_STAGE=path/to/images \
  ./macos-repro.sh mytest fresh on "some marker" 120
```

### The tools

`netlab/` holds what the USB and network work was built out of, in Python, small enough to read:
`tcpusb.py` speaks the emulator's URB protocol, `ncm.py` brings a CDC-NCM link up by hand,
`lockdown.py` and `pair.py` do usbmux and pairing, `slice.py` and `splice.py` take an APFS container
out of a disk image and put it back. `guestfs.py` moves files over the console alone, no network.

> `install-bootstrap.sh` needs sudo and rewrites somebody's guest image. Read it before running it.

---

## Credits and licence

[Inferno](https://github.com/ChefKissInc/Inferno) is by ChefKiss. QEMU is the work of very many
people. This app stands entirely on both.

The emulator is QEMU-derived and therefore **GPL-2.0**; this repository is under the same terms.

No Apple firmware, image or key is distributed here, and none ever will be.
