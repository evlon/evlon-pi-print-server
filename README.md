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

### 1. The printer is *host-based* (GDI), and needs the right driver

The P1007 has no PostScript/PCL interpreter — the host renders every page. CUPS
ships an `hpcups` queue for it, but that one **requires HP's proprietary plugin**.
Without the plugin every job dies with:

```
STATE: +hplip.plugin-error
HPCupsFilter.cpp 505: m_Job initialization failed with error = 48
Filter failed
```

The open-source answer is **foo2zjs** — and specifically the **`foo2xqx`**
driver, *not* `foo2zjs`. The upstream Makefile is authoritative:

```
*P1[05]0[5678]*) driver=foo2xqx;;
```

So the queue must be built with the `foo2zjs:` PPD (which is a *Foomatic* PPD
that calls `foo2xqx-wrapper` through `foomatic-rip`): the script selects
`foo2zjs:0/ppd/foo2zjs/HP-LaserJet_P1007.ppd` and then **verifies the resulting
PPD contains no `hpcups` reference**, aborting if it does.

> The PPD is generated on demand by CUPS from the `printer-driver-foo2zjs`
> package. Nothing needs to be downloaded — but note that
> `foomatic-db-compressed-ppds` does *not* contain it, and a bare
> `foomatic-db-compressed-ppds list | grep foo2zjs` returns nothing. Don't be
> fooled by that: `lpinfo -m` and the CUPS driver helper both know about it.

### 2. The firmware has to be pushed into the printer — every power-up

Being host-based, the P1007 boots with no firmware and must be fed
/lib/firmware/hp/sihpP1007.dl over USB before it will accept a job. Debian **removed these
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
     PPD_DRIVER_ID='foo2zjs:0/ppd/foo2zjs/HP-LaserJet_P1006.ppd' \
     FIRMWARE_NAME=sihpP1006.dl \
     ./install.sh
```

The script is **idempotent** — re-running it re-creates the queue and rewrites
the config from scratch, backing up the previous CUPS configuration first to
`/root/cups-backup-<timestamp>/`.

## Verifying by hand

```bash
# is cupsd up and listening?
systemctl is-active cups && ss -tln | grep 631

# is the queue using the open-source driver (must NOT say hpcups)?
grep -E 'ShortNickName|FoomaticIDs' /etc/cups/ppd/HP-LaserJet-P1007.ppd

# is the printer announced over Bonjour? (look for mopria-certified / URF)
avahi-browse -rtp _ipp._tcp

# print something
lp -d HP-LaserJet-P1007 /etc/hostname
lpstat -l -W completed -o | tail -5      # want: job-completed-successfully
```

## Troubleshooting

**Jobs fail with `Filter failed` / `hplip.plugin-error`**
The queue is still the `hpcups` one. Re-run `sudo ./install.sh`; it deletes and
recreates the queue. Confirm with the `grep` above.

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
| `/etc/cups/ppd/HP-LaserJet-P1007.ppd` | foo2xqx (Foomatic) PPD |
| `/lib/firmware/hp/sihpP1005.dl`, `sihpP1007.dl` | printer firmware (verified) |
| `/usr/local/sbin/printer-firmware-refresh` | watchdog: reap wedged processes, reload firmware, revive the queue |
| `/etc/systemd/system/printer-firmware-refresh.{service,timer}` | runs the above every 2 min and at boot |
| `/etc/systemd/system/multi-user.target.wants/cups.service` | start CUPS at boot |
| `/etc/modprobe.d/blacklist-usblp.conf` | stop `usblp` from taking the printer from CUPS |
| `/root/cups-backup-<ts>/` | backup of the original CUPS config |

Packages: `cups`, `cups-client`, `cups-filters`, `cups-ipp-utils`,
`avahi-daemon`, `avahi-utils`, `printer-driver-foo2zjs{,-common}`.

## Security notes

- Printing is **unauthenticated for the whole local subnet** — that is the
  deliberate trade-off that lets phones print with no setup. Restrict it with
  `ALLOW_NET=192.168.5.0/24`, or tighten `<Location />` afterwards.
- CUPS administration still requires system authentication.
- Nothing is exposed to the internet; do not port-forward 631.

## Uninstall

```bash
sudo ./install.sh --uninstall
```

Removes the queue, firmware, timers, the `usblp` blacklist, and restores the most
recent `/root/cups-backup-*/cupsd.conf`. Packages are left installed.

## License

MIT — see [LICENSE](LICENSE).
