# Inferno for iPhone

An emulated iPhone 11, running as an app on a real iPhone.

This is a SwiftUI front end for [Inferno](https://github.com/ChefKissInc/Inferno) — ChefKiss's
QEMU fork that emulates Apple's T8030 (A13) platform well enough to boot iOS 14. The emulator is
built as a library and loaded into the app, so there is no helper process, no server, and nothing
to connect to: the machine runs inside the app that draws it.

> Inferno itself is by [Visual Ehrmanntraut](https://github.com/VisualEhrmanntraut) and the Inferno
> team at [ChefKiss](https://github.com/ChefKissInc). This repository is the iOS app around it, plus
> the changes to the emulator that iOS made necessary. **It is unofficial**, and not affiliated with
> or endorsed by ChefKiss.

<p align="center">
  <img src="docs/screenshots/home.jpg" height="420" alt="The iOS 14 home screen, with Cydia, inside the app">
  &nbsp;
  <img src="docs/screenshots/shell.jpg" height="420" alt="neofetch in the app's terminal">
  &nbsp;
  <img src="docs/screenshots/files.png" height="420" alt="A file sent from the host phone, in the guest's Files app">
</p>

**Found a bug, or have an idea?** [Open an issue](https://github.com/MakrSas/Inferno-iOS/issues/new/choose),
in English or Russian. Anything goes — see [Issues and ideas](#issues-and-ideas).

---

## What works

- **The guest's screen**, drawn from the emulator's own framebuffer memory — no VNC, no encoding,
  no socket. Touches land where your finger is. The panel can be an iPhone 11, an iPhone 8 or an
  SE: a smaller one is less work for the emulated cores, and it stays sharp, because the scale stays
  at two and iOS uses the same artwork.
- **Device buttons** — side button, volume, home.
- **Internet in the guest, with no companion VM.** The app is its own USB host: it switches the
  emulated device into CDC-NCM mode and lets traffic out through slirp. `apt` works.
- **File transfer both ways**, over a spare NVMe namespace the guest reads as raw bytes — megabytes
  a second on the test rig, with a checksum on both ends. The network is the fallback. Files sent to
  the guest land where the guest's own Files app can see them.
- **Apps installed with one tap.** *Install an .ipa in the guest* unpacks it on the phone, carries
  it in over that channel and registers it with SpringBoard — and says so when the app asks for a
  newer iOS than the guest's 14.
- **An app catalogue** of things an iOS 14 guest can actually run: DolphiniOS, Taurine, iSH and
  Provenance to start with, and any AltStore source you add.
- **A package manager on the phone.** Cydia repositories — bingner's, BigBoss, Chariz, Havoc and
  Filza's own to start with — are read, searched and downloaded on the phone, where the network is
  real and nothing times out; only the finished `.deb` goes into the guest. It knows what is
  installed, and can reinstall or remove it.
- **Cydia that works.** A restored image breaks it three ways at once — the root is read-only, dpkg
  looks for its database where there is none, and nothing in the guest can be setuid, so Cydia's
  `cydo` never becomes root. The app gives Cydia a root helper in its place, and repairs the part a
  guest reboot undoes on every start.
- **The phone's battery in the guest** — the charge, and the bolt while it charges — or a figure of
  your own. The guest's SMC answers with it, so the status bar, Settings and apps all see the same.
- **A network in the guest's status bar**: Wi-Fi or cellular as the phone has it, or whatever you
  set. Only a picture — the machine has no modem and no Wi-Fi, and the guest's apps still see none.
- **The phone's time zone in the guest.** The guest's clock is right, but its image comes with a
  zone of its own, hours away from yours; the app gives the guest the phone's zone, and follows the
  phone when that changes.
- **An agent in the guest** that takes the app's requests over the NVMe namespace instead of the
  console, so one command stuck on the console no longer stalls everything else. The app puts it in
  by itself and has launchd start it on every boot.
- **A shell into the guest**, waiting for the bootstrap's bash rather than giving up on a slow boot.
- **A real terminal**, not a log view: eighty columns, colours, cursor movement. `neofetch` draws
  its logo beside the text, `apt` redraws its progress line in place.
- **English and Russian**, following the system's language unless told otherwise — the emulator's
  log included, since that is what goes into a bug report.

## What does not

- **Speed.** There is no KVM on iOS and there never will be — everything is translated. Boot takes
  minutes, not seconds. What helps most is the translation buffer: measured on a phone, 64 MB gave
  8–11 frames a second and 256 MB gave 21–25. It is 128 MB by default, because it shares the
  process's memory with the guest; raise it in Settings → Translator.
- **Only 3 GiB.** iOS kills a process at exactly that, entitlement or no entitlement, so the guest
  gets 2 GB and the rest is the app's own.
- **Only three panel sizes** — 828×1792, 752×1336 and 640×1136. A row of the frame has to be a
  multiple of sixteen bytes, which is why the iPhone 8 is two pixels wider than the real one: at 750
  the guest never finishes booting.
- **No App Store apps.** Their binaries are encrypted with FairPlay, which only the real device that
  bought them can undo, so they install and die on launch. The catalogue holds only what is
  distributed outside the App Store.
- **No dependency resolution.** The package manager installs what you pick and shows dpkg's
  complaint as it is. Repositories that publish only `.zst` indexes do not open: iOS has nothing
  to decompress them with.
- **Sound is experimental**, and off by default. With the switch on, the guest plays, pauses and
  records, and its vibration reaches the phone; without it the machine boots faster and idles
  lighter, since the audio hardware is not described to the guest at all.
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

2. **Get `Inferno.ipa`** from [Releases](https://github.com/MakrSas/Inferno-iOS/releases), or build
   it yourself (see [Building](#building)). **Install it and StikDebug** with any sideloading tool —
   iLoader, AltStore, Sideloadly.

   StikDebug also needs **LocalDevVPN**, which is on the App Store. It is not a VPN in the usual
   sense — it is what lets the debugger reach the device over its own loopback.

3. **Set StikDebug up**: turn LocalDevVPN on, and put your pairing file into StikDebug (iLoader can
   hand it over).

4. **Assign the script, then launch Inferno through StikDebug**, so it starts with JIT. Before
   launching, long-press Inferno in StikDebug, choose **Assign Script** and pick **`legacy.js`**.
   Then launch it, and check that the app's folder has appeared in Files → On My iPhone → Inferno.

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
the machine, patches and packages, files, device buttons. Drag it wherever you like.

**Network.** On by default. If the guest never takes an address, the menu has *Bring the network up
in the guest*, which runs `ipconfig set en0 DHCP` on its console — the same thing the stock guide
tells you to type by hand.

**Files.** *Send a file to the guest* puts it where the guest's own Files app will find it.
*Fetch a file from the guest* takes a path and saves it into the app's `Guest` folder, visible in
Files on the host phone. *Install an .ipa in the guest* installs an app from a file on the phone.

**Apps and packages** are under *Patches*. *App catalogue* and *Package manager* download on the
phone and install into the guest; *Install a .deb into the guest* takes a package you already have.
*Restart SpringBoard* is what Cydia calls a respring. *Repair the package manager* is the slow half
of fixing Cydia, needed once per image — `firmware.sh` and configuring the bootstrap's packages —
and can take minutes. The quick half runs by itself on every start, once the guest's shell is up;
Settings → Machine can turn that off.

**The shell.** The terminal's *Shell* tab opens a shell over the guest's console, with its output
marked so the kernel's cannot be mistaken for it, and waits for the bootstrap's bash to come up — on
a phone that can be minutes. When the kernel log is too noisy to share the console with, *Over the
network* opens it over a socket instead.

**The guest's battery, status bar and time zone** are in Settings: the battery follows the phone or
holds a figure you set, the status bar shows the phone's network, one you make up, or is left alone,
and the time zone follows the phone unless you turn that off to pick one in the guest's own
Settings.

**Settings** hold everything else: cores, memory, translator, screen, terminal, network, language,
diagnostics, and the credits.

---

## Building

You need a Mac with Xcode — this is built with Xcode 27.0 (27A5237l) and the iOS 27 SDK; older
versions have not been tried — and the emulator's dependencies built for arm64 iOS into one prefix:
glib, pixman, libslirp, libucontext, lzfse, libpng, gmp, nettle and libtasn1.

The emulator lives in its own repository — [a fork of Inferno](https://github.com/MakrSas/Inferno/tree/ios)
carrying the changes iOS needed: the USB-NCM host, the built-in display, the coalesced UART, the
address-space memory patch, the extra NVMe namespace in the device tree. Clone it beside this one:

```bash
git clone -b ios https://github.com/MakrSas/Inferno.git inferno-src
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
app icon with `actool`, ad-hoc signs everything and produces `Inferno.ipa`. Besides Xcode's command
line tools it needs QEMU's keymaps — `brew install qemu` provides them, or point `INFERNO_KEYMAPS`
at a copy. There is no Xcode project.

It also wants `ldid` (`brew install ldid`), to sign the small programs the app carries into the
guest with the entitlements they need. Without it the app still builds, but leaves them out — and
with them the fast file channel, the agent and the status bar.

### Without a Mac — GitHub Actions

[`.github/workflows/build-ipa.yml`](.github/workflows/build-ipa.yml) does all of the above on
GitHub's own macOS runners, so a fork can produce an installable (unsigned) `Inferno.ipa` without
anyone owning a Mac. It runs only when started by hand from the Actions tab (`workflow_dispatch`);
the `.ipa` is attached to the run as an artifact. Release builds are made on a Mac, not here.

The nine iOS dependencies are built from source by
[`scripts/build-ios-deps.sh`](scripts/build-ios-deps.sh) (which also works locally:
`PREFIX=$PWD/prefix scripts/build-ios-deps.sh`) and the resulting `prefix/` is cached, keyed on that
script and the runner's Xcode, so only the first run pays the ~20-minute cost. The workflow still
does not touch any guest image, firmware or Apple key — those are yours to build.

The runner is `macos-26`, so `actool` there compiles `Inferno.icon` (Icon Composer, Xcode 26+)
directly — the built `.ipa` gets the real Liquid Glass icon, not a placeholder. `app/build.sh`
still probes `actool` before using it and falls back to `app/Resources/Assets.xcassets` — a flat
PNG rendering of the same artwork — if it ever runs on an older Xcode.

---

## Issues and ideas

**[Open an issue](https://github.com/MakrSas/Inferno-iOS/issues/new/choose) for anything at all:**

- **Something broke** — a crash, a hang, a black screen, a guest that will not boot or will not get
  an address.
- **Something could be better** — anything awkward, slow, confusing, or missing from the menu.
- **Something new** — a feature you would like to see, even a half-formed one.

Write in English or Russian, whichever is easier. For a bug it helps to know the iPhone and its iOS
version, the app's build (in Settings), what you did and what happened. The app keeps
`emulator.log` — and `emulator.prev.log`, the run before it, in case you restarted the app to see
what went wrong — and `guest-console.log` in its folder in Files; attach them if you can.

Pull requests are welcome too.

## Helping out

Most of what was learned here is written down, because most of it was expensive to learn. The notes
are in Russian, the language the work was done in.

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

[Inferno](https://github.com/ChefKissInc/Inferno) is by Visual Ehrmanntraut and the Inferno team at
ChefKiss. QEMU is the work of very many people. This app stands entirely on both — if it is useful
to you, consider [supporting ChefKiss](https://ko-fi.com/chefkiss).

This project is unofficial and is not affiliated with or endorsed by ChefKiss.

The app is under **GPL-3.0**; see [`LICENSE`](LICENSE). The emulator keeps Inferno's terms: GPL-3.0
as a whole, with ChefKiss's own code under AGPL-3.0, and the fork's changes under the same.

Inferno's boot splash artwork belongs to ChefKiss and is not covered by those licences, so builds
from here leave it out, and the screen stays dark until the guest draws.

No Apple firmware, image or key is distributed here, and none ever will be.
