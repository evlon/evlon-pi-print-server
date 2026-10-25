# usb-printer-airprint

Turn a **USB-only HP LaserJet P1007** into a **WiFi network printer** that iPhones
and Android phones can print to — no app, no password, no cloud.

After installing, the printer shows up automatically in:

- **iOS / iPadOS** — AirPrint (`Share → Print`)
- **Android** — Mopria / Default Print Service
- **Anything else** — plain IPP at `ipp://<host>:631/printers/<queue>`

Tested on a Raspberry Pi 4 running Debian 13 (trixie) arm64.

```
┌────────┐   WiFi/IPP    ┌──────────────┐   USB    ┌─────────────────┐
│ phone  │ ────────────► │ Raspberry Pi │ ───────► │ HP LaserJet     │
│        │  Bonjour/mDNS │ CUPS + Avahi │          │ P1007 (USB only)│
└────────┘               └──────────────┘          └─────────────────┘
```

## Quick start

```bash
git clone https://github.com/<you>/usb-printer-airprint.git
cd usb-printer-airprint
sudo ./install.sh
```

The installer verifies itself **without using any paper**: it runs the real CUPS
filter chain and checks that it emits a valid HP PJL/XQX print stream, so you
know the driver and PPD are correct before a single sheet is spent. Add `--test`
only if you *also* want a physical test page (that uses one sheet).

Then, from a phone **on the same WiFi**:

| Platform | How |
|---|---|
| iPhone / iPad | Open a document → Share → Print → pick the printer |
| Android | Settings → Connected devices → Printing → enable Default Print Service; the printer appears automatically |
| Manual (any) | `ipp://<pi-ip>:631/printers/HP-LaserJet-P1007` |

CUPS web UI: `http://<pi-ip>:631/`

## Why this script exists

Making this particular printer work is notoriously annoying. This script encodes
the five things that actually matter, each of which is a silent failure
otherwise.

### 1. The printer speaks HBS — and that decides which driver to use

The P1007 has no PostScript/PCL interpreter; the host renders every page. Its
device ID says exactly which host protocol it wants:

```
MFG:Hewlett-Packard;MDL:HP LaserJet P1007;CMD:HBS,PJL,ACL;...
```

**`HBS` is Host-Based Streaming, the printer's native language.** This matters
more than any tuning option, and it is the difference between faint, dotted text
and crisp output:

| Driver | Format | Result on a P1007 |
|---|---|---|
| `hpcups` (HP, needs plugin) | **HBS** — native | crisp, solid text |
| `foo2xqx` (open source) | ZjStream/XQX — emulated | thin, washed-out, visibly "dashed" glyphs |

`foo2xqx` is not broken; it is simply written for a different printer. Its own
source says so:

```
Convert Ghostscript pbmraw format to a monochrome ZJS stream,
for driving the HP LaserJet M1005 MFP laser printer.
```

It drives a P1007 well enough to put ink on paper, so it looks like it works —
which is why this is easy to get wrong. Print the same page through HP's Windows
driver and the difference is obvious immediately. No amount of `Density`,
`halftone`, `RET` or resolution tuning closes that gap; the protocol differs.

So this installer uses **`hpcups`**, which needs HP's proprietary plugin (it
carries `prnt/plugins/hbpl1.so`, the HBS implementation). Without the plugin
every job dies with:

```
STATE: +hplip.plugin-error
HPCupsFilter.cpp 505: m_Job initialization failed with error = 48
Filter failed
```

The installer therefore fetches and installs `hplip-3.22.10-plugin.run`
(~11 MB, md5 verified) when it is missing, or takes a local copy via
`--hplip-plugin PATH`. The plugin lives in `/usr/share/hplip`, so it survives
reboots and does not need reinstalling.

> If you prefer to stay entirely open source, set
> `PPD_DRIVER_ID=foo2zjs:0/ppd/foo2zjs/HP-LaserJet_P1007.ppd`. It prints, but
> expect the faint dotted look described above.

#### How this was actually found (a list of dead ends)

Worth reading before you start tuning, because every one of these *looks* like a
plausible cause and none of them is:

| Suspect | Why it seemed right | What it actually did |
|---|---|---|
| Empty / damp toner | faint grey output is the classic symptom | no effect; the same cartridge is perfect via Windows |
| `Density` 3 → 5 | `foo2xqx` defaults to 3 (medium) | stream said `@PJL SET DENSITY=5`, still dotted |
| `hpcups` needs plugin | error 48 is literally a plugin error | installing the plugin *is* required, but for HBS — see below |
| `RET=OFF` | HP's edge enhancement can split thin strokes | made it **worse**; `MEDIUM` was helping |
| `halftone=wts` / `as` / `standard` | dotted look = dithering | no visible change |
| `1200x600` vs `600x600` | avoids vertical interpolation | no improvement (larger stream, same look) |
| Firmware version | `FWVER` changed to 20100824 after a Windows session | irrelevant; firmware does not change the host protocol |

The test that settled it: **print the identical page from Windows**. Perfectly
crisp. Same printer, same paper, same toner — so the hardware was never the
problem, and the only remaining variable is the host-side data format.

Two things that cost a lot of time and are worth remembering:

1. **"It prints" is not "the driver is correct."** `foo2xqx` produces valid
   output for this printer. Every byte-level check passes. Only the *rendering*
   is wrong, and only on paper.
2. **`CMD:HBS` in the device ID is the answer.** Check the protocol a printer
   advertises before picking a driver, not after the output looks bad.

### 2. The firmware has to be pushed into the printer — every power-up

Being host-based, the P1007 boots with no firmware and must be fed
`/lib/firmware/hp/sihpP1007.dl` over USB before it will accept a job. Debian **removed these
firmware files for licensing reasons**, so a stock install cannot print at all.

The script downloads the blob and verifies it three ways (size, `@PJL` header,
sha256) before installing it.

**The alias trap:** `/usr/lib/udev/hpljP1007` contains

```
*P1007) MODEL=P1007; FWMODEL=P1005   # Alias
```

so it actually loads **`/lib/firmware/hp/sihpP1005.dl`**. Both names are
byte-identical, so the script installs *both* — but if you do this by hand and
only create `sihpP1007.dl`, the loader will report:

```
foo2zjs: Missing HP LaserJet P1007 firmware file /lib/firmware/hp/sihpP1005.dl
```

Two independent loading paths are installed:

- the package's udev rule, which fires on USB plug-in, and
- `printer-firmware-refresh.timer`, which re-checks every 5 minutes.

**The queue is recovered too.** When the printer is powered off, CUPS notices
the device vanish and stops the queue with *"Unplugged or turned off"* — and it
never restarts itself, so printing stays dead until somebody runs `cupsenable`
by hand. The refresh service therefore also re-enables the queue once the
printer is reachable again with its firmware loaded.

CUPS does not persist a reason that reliably separates "the printer went away"
from "an admin paused this queue", so recovery **errs towards fixing it**. To
keep a deliberate `cupsdisable` instead:

```bash
sudo touch /etc/printer-no-auto-enable
```

You can verify the firmware is loaded by asking the USB backend — a live
printer reports `FWVER:`:

```bash
/usr/lib/cups/backend/usb | grep '^direct'
# ... CMD:HBS,PJL,ACL;CLS:PRINTER;...;FWVER:20080415;" ...
```

### 3. CUPS is not listening on the network by default

Out of the box Debian's CUPS binds `localhost:631` only, so phones cannot even
reach it. The script installs a config that:

- binds `0.0.0.0:631`,
- keeps access to the local subnet (`Allow @LOCAL`),
- enables `Browsing On` + `BrowseLocalProtocols dnssd`,
- sets `IdleExitTimeout 0`,
- allows **`Print-Job` without authentication** while keeping `@SYSTEM` auth on
  all administrative operations.

`IdleExitTimeout 0` is not cosmetic. Debian runs `cupsd -l`, i.e. socket
activated with an idle-exit timer: when cupsd exits, **the Bonjour
advertisement disappears too**, and phones stop seeing the printer after a
period of inactivity.

The config is validated with `cupsd -t` *before* being installed, so a bad
config can never leave CUPS broken.

### 4. `cups.service` does not start on a plain boot

The Debian unit is `WantedBy=printer.target`, which a normal boot never reaches
— cupsd would only come up when something connects locally. The script adds an
explicit `multi-user.target.wants/cups.service` symlink so the print server (and
its mDNS advertisement) is up right after boot.

### 5. The kernel's `usblp` driver steals the printer from CUPS

CUPS talks to the printer through **libusb**. The kernel's `usblp` driver also
wants to own the same USB interface, and when it wins, the CUPS `usb` backend
logs:

```
DEBUG: Failed to detach "usblp" module from 03f0:4817
```

…and then **enumerates no devices at all**. The printer is visible to `lsusb`
but invisible to CUPS, so the queue cannot even be created — the installer stops
with `printer not detected on USB`.

Because udev auto-loads `usblp` for any USB printer-class device, this can
appear and disappear between reboots, which makes it a maddening intermittent
failure. The installer therefore blacklists it via
`/etc/modprobe.d/blacklist-usblp.conf` and unloads it if present.

`usblp` is not needed: the firmware loader prefers the CUPS backend too, and
neither `foo2xqx` nor CUPS uses `/dev/usb/lp0`.

### 6. A docker bridge can make the printer undiscoverable

If Docker is installed, Avahi also publishes the printer on the `docker0`
bridge - an interface that is not on your LAN at all. That alone is untidy, but
it causes a silent, maddening failure: **mDNS then answers the query for
`<host>.local` with the docker bridge address.**

```console
$ avahi-resolve -n evlon-pi.local
evlon-pi.local	172.17.0.1        # docker0 - no phone can reach this
```

Everything looks healthy from the Pi: cupsd is up, the queue is enabled, the
printer answers at `192.168.5.61:631` with HTTP 200, and `avahi-browse` lists
four `_ipp._tcp` records. But when a phone discovers the printer and resolves
its hostname, it gets an unroutable address and gives up. The printer simply
never appears in the list.

The fix is to keep Avahi off the bridges:

```ini
# /etc/avahi/avahi-daemon.conf
[server]
deny-interfaces=docker0,docker1,docker2
```

The installer applies this automatically (it detects `docker*`, `br-*` and
`veth*` interfaces) and `verify_install` fails loudly if `<host>.local` still
resolves into `172.16.0.0/12`:

```
!! evlon-pi.local resolves to 172.17.0.1 (a docker bridge) - phones will not find the printer
```

If you add Docker networks later, re-run the installer to pick them up.

### 7. CUPS must listen on IPv6 as well as IPv4

`Listen 0.0.0.0:631` binds **IPv4 only**. That is not enough here, and the
failure is easy to miss because every IPv4 check keeps passing:

```console
$ ss -tln | grep 631
LISTEN  0.0.0.0:631          # IPv4 only - no [::]:631
```

Bonjour advertises the printer's **IPv6 address too** (a home LAN normally has a
global one via router advertisement), and iOS and Android prefer IPv6. The
phone resolves the printer to that IPv6 address, finds nothing listening, and
the printer never shows up - or a job fails. From the Pi everything looks
perfect:

```console
$ curl -s -o /dev/null -w '%{http_code}' http://192.168.5.61:631/           # 200
$ curl -s -o /dev/null -w '%{http_code}' 'http://[2409:8a04:...]:631/'      # 000
```

The fix is one extra line, and `verify_install` now checks for it explicitly:

```
Listen 0.0.0.0:631
Listen [::]:631
```

```
ok CUPS listening on IPv4 :631
ok CUPS listening on IPv6 :631
```

## Options

```
sudo ./install.sh [options]

  --name NAME          CUPS queue name            (default: HP-LaserJet-P1007)
  --desc TEXT          Human readable description (default: HP LaserJet P1007)
  --device-uri URI     Skip USB auto-detection and use this URI
  --firmware-file PATH Use a local firmware file instead of downloading
  --plugin-fallback    If the firmware mirror fails, extract the firmware
                       from the official HPLIP plugin (~11 MB download)
  --test               Submit a physical test page (uses one sheet of paper)
  --no-apt-update      Skip 'apt-get update'
  --dry-run            Show what would be done, change nothing
  --uninstall          Remove queue, firmware, systemd units and config
  -h, --help           This help
```

Every setting is also available as an environment variable, which is the
supported way to adapt the script to a **different but similar** HP printer:

```bash
sudo MODEL_TAG=P1006 \
     USB_MODEL_MATCH='LaserJet P1006' \
     PPD_DRIVER_ID='drv:///hpcups.drv/hp-laserjet_p1006.ppd' \
     FIRMWARE_NAME=sihpP1006.dl \
     ./install.sh
```

Before adapting it, check what protocol the target printer advertises (`CMD:`
in its device ID) — that is what determines whether hpcups or foo2xqx is right,
and it matters far more than any option. See section 1.

The script is **idempotent** — re-running it re-creates the queue and rewrites
the config from scratch, backing up the previous CUPS configuration first to
`/root/cups-backup-<timestamp>/`.

## Verifying by hand

```bash
# is cupsd up and listening on BOTH families?
systemctl is-active cups && ss -tln | grep 631

# which driver does the queue really use? (want: hpcups, NOT foo2xqx)
grep -E 'NickName|cupsFilter' /etc/cups/ppd/HP-LaserJet-P1007.ppd

# is the HBS driver from HP's plugin present?
ls -l /usr/share/hplip/prnt/plugins/hbpl1.so

# is the printer announced over Bonjour? (look for mopria-certified / URF)
avahi-browse -rtp _ipp._tcp

# print something
lp -d HP-LaserJet-P1007 /etc/hostname
lpstat -l -W completed -o | tail -5      # want: job-completed-successfully
```

Only one of those six checks catches wrong output: **the driver check**. A
`foo2xqx` queue passes every other one while printing faint dotted text, because
its data stream is structurally valid. When output quality is the complaint,
start there — and confirm by printing the same page from a machine with HP's
official driver.

## Troubleshooting

**Text prints faint, grey, or visibly made of dots and dashes**
The queue is on `foo2xqx` instead of `hpcups`. Check the driver as above and
re-run `sudo ./install.sh`. See section 1 — this is a protocol difference, not a
tuning problem, so do not start with density or halftone options.

**Jobs fail with `Filter failed` / `hplip.plugin-error`**
`hpcups` is in use but HP's plugin is missing. Re-run `sudo ./install.sh`, or
install `hplip-3.22.10-plugin.run` by hand and pass `--hplip-plugin PATH`.
Confirm `hbpl1.so` exists as shown above.

**`foo2zjs: Missing HP LaserJet P1007 firmware file /lib/firmware/hp/sihpP1005.dl`**
The alias name is missing. `sudo ./install.sh` installs both names.

**Job completes but nothing prints**
Check firmware is loaded (`FWVER:` in the backend output above) and that the
printer has paper. A P1007 with no paper still reports the job as completed.

**`printer not detected on USB`, or jobs that used to work now fail**
Check whether `usblp` came back:

```bash
lsmod | grep usblp
/usr/lib/cups/backend/usb 2>&1 | grep -E 'Failed to detach|^direct'
```

If you see `Failed to detach`, the blacklist is missing — re-run
`sudo ./install.sh`.

**The printer is wedged: a job sits at "Sending data to printer" forever**

This is the one failure a tool on the Pi cannot fix, and it is worth
understanding.

A host-based printer accepts the firmware in a narrow window after it powers
up. If it ever ends up in a confused state (an upload interrupted half-way, a
job killed mid-transfer, a brown-out) it stops consuming USB data. Then:

- the job hangs at *Sending data to printer*, and
- the stuck `usb` backend **keeps the USB device claimed**, so every later job
  *and* every later firmware upload hangs too — a total deadlock.

**The fix is to switch the printer off and on again.** That is the only
reliable cure; it is the printer's own state machine that is stuck, not the Pi.
A USB replug often works too, because it re-enumerates the device, but it
cannot clear a wedged printer as reliably as cutting its power.

Software recovery was tested and does **not** work here. All of these
re-enumerate the device and fire the udev firmware loader, and the printer
refuses the firmware every time:

```bash
# USBDEVFS_RESET ioctl on /dev/bus/usb/BBB/DDD
# echo 0 > .../authorized ; echo 1 > .../authorized
# echo 1-1.2 > /sys/bus/usb/drivers/usb/unbind ; ... bind
```

What the watchdog **does** guarantee is that the wedge never becomes permanent
damage. Every device operation is bounded by a timeout, and each run kills any
process that has wedged while holding the USB device, so the printer stays
visible and one power cycle brings it straight back. After three failed
software recoveries it backs off for 30 minutes and logs exactly what to do:

```
printer-firmware-refresh: SOFTWARE RECOVERY FAILED 3x. The printer is wedged;
only a PHYSICAL POWER CYCLE (switch the printer off, wait 10 s, switch it on
again) clears it.
```

Watch it with:

```bash
sudo journalctl -t printer-firmware-refresh -f
```

**Printing worked, then I power-cycled the printer and now nothing prints**
The firmware is reloaded automatically, and so is the queue. Check within a
couple of minutes:

```bash
lpstat -p HP-LaserJet-P1007            # want: is idle. enabled
/usr/lib/cups/backend/usb | grep FWVER  # want: FWVER:...
```

If the queue is still `disabled`, run `sudo cupsenable HP-LaserJet-P1007`; if
that happens repeatedly, see the `usblp` section above.

**Phone does not see the printer**

Work through these in order - each one looks fine until you check it:

```bash
# 1. is CUPS listening on BOTH families? (want 0.0.0.0:631 AND [::]:631)
ss -tln | grep 631

# 2. can the printer's IPv6 address actually be reached?
curl -s -o /dev/null -w '%{http_code}\n' "http://[$(ip -6 addr show wlan0 | awk '/scope global/{print $2}' | cut -d/ -f1)]:631/"

# 3. does the hostname resolve to a LAN address, not a docker bridge?
avahi-resolve -n $(hostname).local        # want 192.168.x.y, NOT 172.17.0.1
```

If (1) shows only `0.0.0.0:631`, see section 7. If (3) resolves to `172.17.0.1`,
see section 6. Re-running `sudo ./install.sh` fixes both.

Also check that the hostname resolves to a LAN address, not a docker bridge:

```bash
avahi-resolve -n $(hostname).local        # want 192.168.x.y, NOT 172.17.0.1
avahi-browse -rtp _ipp._tcp | grep '^='  # want only wlan0 / eth0, not docker0
```

If it resolves to `172.17.0.1`, see section 6 above - re-run `sudo ./install.sh`.
Both must be on the same subnet, and mDNS must not be filtered by the AP
(guest-network / "AP isolation" breaks it). As a workaround add it manually by
IP: `ipp://<pi-ip>:631/printers/HP-LaserJet-P1007`.

**`Files have gone away` in `/var/log/cups/error_log`**
A stale job record. Harmless.

**Downloading firmware fails**
The upstream `foo2zjs.rkkda.com` is dead. Pass a local file
(`--firmware-file sihpP1007.dl`) or use `--plugin-fallback`. Any 222443-byte
`sihpP1007.dl` with sha256
`f96eae07b6f7ea8bf94cb078707a6f23909bc5dea11df3cc5a1429ed8843652b` is genuine —
it is byte-identical to `hp_laserjet_p1007.fw.gz` inside the official HPLIP
plugin.

## What gets installed

| Path | Purpose |
|---|---|
| `/etc/cups/cupsd.conf` | LAN listening, dnssd, no-auth printing (validated) |
| `/etc/cups/ppd/HP-LaserJet-P1007.ppd` | hpcups PPD (native HBS driver) |
| `/usr/share/hplip/prnt/plugins/hbpl1.so` | HBS driver from HP's plugin |
| `/usr/share/hplip/data/firmware/hp_laserjet_p1007.fw.gz` | P1007 firmware from the plugin |
| `/lib/firmware/hp/sihpP1005.dl`, `sihpP1007.dl` | printer firmware (verified) |
| `/usr/local/sbin/printer-firmware-refresh` | watchdog: reap wedged processes, reload firmware, revive the queue |
| `/etc/systemd/system/printer-firmware-refresh.{service,timer}` | runs the above every 2 min and at boot |
| `/etc/systemd/system/multi-user.target.wants/cups.service` | start CUPS at boot |
| `/etc/modprobe.d/blacklist-usblp.conf` | stop `usblp` from taking the printer from CUPS |
| `/etc/avahi/avahi-daemon.conf` | `deny-interfaces` so mDNS ignores docker bridges |
| `/root/cups-backup-<ts>/` | backup of the original CUPS config |

Packages: `cups`, `cups-client`, `cups-filters`, `cups-ipp-utils`,
`avahi-daemon`, `avahi-utils`, `hplip`, `printer-driver-foo2zjs{,-common}`.

## Security notes

- Printing is **unauthenticated for the whole local subnet** — that is the
  deliberate trade-off that lets phones print with no setup. Restrict it with
  `ALLOW_NET=192.168.5.0/24`, or tighten `<Location />` afterwards.
- CUPS administration still requires system authentication.
- Nothing is exposed to the internet; do not port-forward 631.

## Daily use: a printer you switch off between jobs

A home printer like this one may print a couple of pages a week, while the Pi
stays on permanently. That is the intended setup — **leave the Pi running and
switch the printer off whenever you are not using it.** You do not need to
reboot the Pi, reload firmware, or re-add the queue.

```
before printing : press the printer's power button, wait ~10 s (LED goes green)
printing        : share from the phone, as usual
after           : press the printer's power button again
the Pi          : leave it on, indefinitely
```

Why the Pi should stay on: when it boots, the mDNS advertisement and the phone's
Bonjour cache both have to be rebuilt, which is exactly when "the printer does
not appear" happens. A Pi that is always on has none of that churn. It is also
cheap to keep running — the whole stack (cupsd, avahi, the watchdog) idles at a
few hundred MB of RAM and near-zero CPU.

**Wait for the job to finish before switching the printer off.** Cutting power
mid-transfer is what leaves the printer in the confused state described under
[the wedged-printer entry](#troubleshooting) — that is the one failure software
cannot clear. If in doubt, wait a few seconds after the last page comes out.

Switching the printer off is handled cleanly: the watchdog notices the device is
absent and does nothing at all, instead of treating it as missing firmware and
trying to reload it. On power-on, udev feeds the firmware within a second or two
and the queue is already there waiting.

## Uninstall

```bash
sudo ./install.sh --uninstall
```

Removes the queue, firmware, timers, the `usblp` blacklist, and restores the most
recent `/root/cups-backup-*/cupsd.conf`. Packages are left installed.

## License

MIT — see [LICENSE](LICENSE).
