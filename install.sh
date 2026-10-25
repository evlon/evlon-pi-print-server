#!/usr/bin/env bash
# =============================================================================
#  usb-printer-airprint
#  Turn a USB HP LaserJet P1007 into a WiFi network printer for phones.
#
#  Result: iPhone/iPad print via AirPrint, Android via Mopria/IPP - no app,
#          no password on the local subnet.
#
#  Tested on: Raspberry Pi 4, Debian 13 (trixie) arm64 / Raspberry Pi OS.
#             Should work on any Debian/Ubuntu on any architecture.
#
#  Usage:  sudo ./install.sh [options]
#          sudo ./install.sh --uninstall
#
#  Run with --help for all options.
# =============================================================================
set -euo pipefail

VERSION="1.0.0"
SCRIPT_NAME="$(basename "$0")"

# ---------------------------------------------------------------------------
# Defaults - every setting can be overridden by an environment variable.
# Useful when adapting this script to a different (but similar) HP printer.
# ---------------------------------------------------------------------------
PRINTER_NAME="${PRINTER_NAME:-HP-LaserJet-P1007}"
PRINTER_DESC="${PRINTER_DESC:-HP LaserJet P1007}"
PRINTER_LOCATION="${PRINTER_LOCATION:-$(hostname 2>/dev/null || echo print-server)}"

# udev firmware-loader helper is /usr/lib/udev/hplj<MODEL_TAG>; P1007 -> hpljP1007
MODEL_TAG="${MODEL_TAG:-P1007}"
# Substring used to find the printer among USB devices.
USB_MODEL_MATCH="${USB_MODEL_MATCH:-LaserJet P1007}"
# CUPS driver id (see `lpinfo -m`). P1007 is driven by foo2xqx via foomatic-rip.
# P1007 speaks HBS (Host-Based Streaming) natively. HP's own hpcups driver uses
# it and renders crisp text. foo2xqx only *emulates* the printer with the
# ZjStream dialect it was written for (the M1005), and on this printer that
# shows up as thin, washed-out, "dashed" text - while the same page printed
# through HP's Windows driver looks perfect. So hpcups is the correct choice,
# and it needs HP's proprietary plugin installed first.
PPD_DRIVER_ID="${PPD_DRIVER_ID:-drv:///hpcups.drv/hp-laserjet_p1007.ppd}"
HPLIP_PLUGIN_VER="${HPLIP_PLUGIN_VER:-3.22.10}"
HPLIP_PLUGIN_URL="${HPLIP_PLUGIN_URL:-https://www.openprinting.org/download/printdriver/auxfiles/HP/plugins/hplip-${HPLIP_PLUGIN_VER}-plugin.run}"
HPLIP_PLUGIN_MD5="${HPLIP_PLUGIN_MD5:-e21f6fc2eba23d33846b340c3a960586}"

# --- firmware -------------------------------------------------------------
# IMPORTANT: on this Debian package /usr/lib/udev/hpljP1007 maps
#   *P1007) MODEL=P1007; FWMODEL=P1005   # Alias
# and looks for /lib/firmware/hp/sihpP1005.dl. The two files are byte-identical,
# but the name that MUST exist is the alias name (sihpP1005.dl).
FIRMWARE_NAME="${FIRMWARE_NAME:-sihpP1005.dl}"
FIRMWARE_URL="${FIRMWARE_URL:-http://opt.cn2qq.com/opt-file/printer/sihpP1007.dl}"
FIRMWARE_MD5="${FIRMWARE_MD5:-ed18611a9c0c6c23b97d8c543fb2ec79}"
FIRMWARE_SHA256="${FIRMWARE_SHA256:-f96eae07b6f7ea8bf94cb078707a6f23909bc5dea11df3cc5a1429ed8843652b}"

# Optional fallback source: the official HPLIP proprietary plugin ships the very
# same firmware as hp_laserjet_p1007.fw.gz. Verified: extracted bytes are
# md5-identical to the mirror copy above.
HPLIP_PLUGIN_URL="${HPLIP_PLUGIN_URL:-https://www.openprinting.org/download/printdriver/auxfiles/HP/plugins/hplip-3.22.10-plugin.run}"
PLUGIN_FW_MEMBER="${PLUGIN_FW_MEMBER:-hp_laserjet_p1007.fw.gz}"

# --- network --------------------------------------------------------------
CUPS_PORT="${CUPS_PORT:-631}"
# USB vendor/product of the printer (used for a software port reset).
USB_VID="${USB_VID:-03f0}"
USB_PID="${USB_PID:-4817}"
# @LOCAL = any client on a directly attached subnet. Use e.g. 192.168.5.0/24
# to restrict further.
ALLOW_NET="${ALLOW_NET:-@LOCAL}"

# Print density 1-5. foo2xqx defaults to 3, which renders faint grey text on a
# P1007 - close to unreadable on a worn cartridge. 5 maps to
# "@PJL SET DENSITY=5" and is the safe default for this printer.
PRINT_DENSITY="${PRINT_DENSITY:-5}"
# Halftone algorithm. "wts" (Well Tempered Screens) gives the best greys.
PRINT_HALFTONE="${PRINT_HALFTONE:-wts}"

# --- behaviour ------------------------------------------------------------
DRY_RUN=0
DO_TEST=0
DO_APT_UPDATE=1
PLUGIN_FALLBACK=0
UNINSTALL=0
FIRMWARE_FILE=""
HPLIP_PLUGIN_FILE="${HPLIP_PLUGIN_FILE:-}"
DEVICE_URI="${DEVICE_URI:-}"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$BLU" "$RST" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s  !!%s %s\n' "$YEL" "$RST" "$*" >&2; }
die()  { printf '%s ERROR%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
$SCRIPT_NAME v$VERSION - USB HP LaserJet P1007 -> WiFi/AirPrint print server

Usage:
  sudo ./install.sh [options]
  sudo ./install.sh --uninstall

Options:
  --name NAME          CUPS queue name            (default: $PRINTER_NAME)
  --desc TEXT          Human readable description (default: $PRINTER_DESC)
  --device-uri URI     Skip USB auto-detection and use this URI
  --firmware-file PATH Use a local firmware file instead of downloading
  --hplip-plugin PATH  Use a local HPLIP plugin .run instead of downloading
                       (needed by hpcups; ~11 MB, md5 verified)
  --plugin-fallback    If the firmware mirror fails, extract the firmware
                       from the official HPLIP plugin (~11 MB download)
  --test               Submit a physical test page (uses one sheet of paper)
  --no-apt-update      Skip 'apt-get update'
  --dry-run            Show what would be done, change nothing
  --uninstall          Remove queue, firmware, systemd units and config
  -h, --help           This help
  -V, --version        Print version

Environment overrides: PRINTER_NAME, MODEL_TAG, USB_MODEL_MATCH, PPD_DRIVER_ID,
  FIRMWARE_NAME, FIRMWARE_URL, ALLOW_NET, CUPS_PORT ...
EOF
}

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)            PRINTER_NAME="$2"; shift 2 ;;
    --desc)            PRINTER_DESC="$2"; shift 2 ;;
    --device-uri)      DEVICE_URI="$2";   shift 2 ;;
    --firmware-file)   FIRMWARE_FILE="$2"; shift 2 ;;
    --hplip-plugin)    HPLIP_PLUGIN_FILE="$2"; shift 2 ;;
    --plugin-fallback) PLUGIN_FALLBACK=1; shift ;;
    --test)            DO_TEST=1; shift ;;
    --no-apt-update)   DO_APT_UPDATE=0; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    --uninstall)       UNINSTALL=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    -V|--version)      echo "$SCRIPT_NAME v$VERSION"; exit 0 ;;
    *)                 die "unknown option: $1 (try --help)" ;;
  esac
done

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# Run a command, letting its output through, but tolerate failure.
run_soft() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '  [dry-run] %s\n' "$*"
    return 0
  fi
  "$@" || true
}

# ---------------------------------------------------------------------------
# preconditions
# ---------------------------------------------------------------------------
require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    die "must run as root:  sudo ./$SCRIPT_NAME $*"
  fi
}

require_debian() {
  command -v apt-get >/dev/null 2>&1 || die "this installer targets Debian/Ubuntu (apt-get not found)"
  if [[ -f /etc/debian_version ]]; then
    ok "Debian/Ubuntu detected ($(cat /etc/debian_version))"
  else
    warn "no /etc/debian_version - continuing anyway"
  fi
}

# /usr/sbin is frequently missing from PATH under sudo.
fix_path() { export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"; }

# Work dir that survives a not-world-writable /tmp (a real quirk of some
# hardened images).
make_workdir() {
  local d
  d="$(mktemp -d 2>/dev/null || mktemp -d -p /var/tmp 2>/dev/null || mktemp -d -p /root)"
  printf '%s' "$d"
}

# ---------------------------------------------------------------------------
# uninstall
# ---------------------------------------------------------------------------
do_uninstall() {
  log "Uninstalling print server configuration"
  run_soft lpadmin -x "$PRINTER_NAME"
  run_soft systemctl disable --now printer-firmware-refresh.timer
  run_soft rm -f /etc/systemd/system/printer-firmware-refresh.service \
                /etc/systemd/system/printer-firmware-refresh.timer \
                /usr/local/sbin/printer-firmware-refresh
  run_soft rm -f "/lib/firmware/hp/$FIRMWARE_NAME" /lib/firmware/hp/sihpP1007.dl
  # Undo the boot-time autostart symlink added by enable_services().
  run_soft rm -f /etc/systemd/system/multi-user.target.wants/cups.service
  # Restore the kernel's usblp driver to its default (available) state.
  if [[ -f /etc/modprobe.d/blacklist-usblp.conf ]] && \
     grep -q 'usb-printer-airprint' /etc/modprobe.d/blacklist-usblp.conf; then
    run_soft rm -f /etc/modprobe.d/blacklist-usblp.conf
  fi
  run_soft systemctl daemon-reload

  local backup
  backup="$(ls -1dt /root/cups-backup-* 2>/dev/null | head -1 || true)"
  if [[ -n "$backup" && -f "$backup/cupsd.conf" ]]; then
    log "Restoring original cupsd.conf from $backup"
    run cp -a "$backup/cupsd.conf" /etc/cups/cupsd.conf
  else
    warn "no cupsd.conf backup found - leaving /etc/cups/cupsd.conf as-is"
  fi
  run_soft systemctl restart cups
  ok "Uninstalled. Packages (cups, foo2zjs) were left installed."
}

# ---------------------------------------------------------------------------
# packages
# ---------------------------------------------------------------------------
install_packages() {
  local pkgs=(
    cups
    cups-client
    cups-filters
    cups-ipp-utils
    avahi-daemon
    avahi-utils
    hplip
    printer-driver-foo2zjs
    printer-driver-foo2zjs-common
  )
  if [[ $DO_APT_UPDATE -eq 1 ]]; then
    log "apt-get update"
    run env DEBIAN_FRONTEND=noninteractive apt-get update -qq
  fi
  log "Installing packages: ${pkgs[*]}"
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
  ok "packages installed"
}

# ---------------------------------------------------------------------------
# firmware
# ---------------------------------------------------------------------------
verify_firmware() {           # $1 = path
  local f="$1"
  [[ -f "$f" ]] || return 1
  local size; size="$(stat -c %s "$f" 2>/dev/null || echo 0)"
  [[ "$size" -eq 222443 ]] || { warn "firmware size $size != 222443"; return 1; }
  # PJL/ACL header: 1b 25 2d 31 32 33 34 35 58  =  \x1b%-12345X  (9 bytes)
  local magic; magic="$(head -c 9 "$f" | od -An -tx1 | tr -d ' \n')"
  [[ "$magic" == "1b252d313233343558" ]] || { warn "unexpected firmware magic: $magic"; return 1; }
  if command -v sha256sum >/dev/null 2>&1 && [[ -n "$FIRMWARE_SHA256" ]]; then
    local got; got="$(sha256sum "$f" | awk '{print $1}')"
    [[ "$got" == "$FIRMWARE_SHA256" ]] || { warn "sha256 mismatch: $got"; return 1; }
  elif command -v md5sum >/dev/null 2>&1 && [[ -n "$FIRMWARE_MD5" ]]; then
    local got; got="$(md5sum "$f" | awk '{print $1}')"
    [[ "$got" == "$FIRMWARE_MD5" ]] || { warn "md5 mismatch: $got"; return 1; }
  else
    warn "no sha256sum/md5sum available - header check only"
  fi
  return 0
}

# Fallback: the HPLIP plugin is a Makeself 2.x archive, so --noexec --target
# unpacks it without running the bundled installer.
fetch_firmware_plugin() {     # $1 = workdir; echoes path to firmware binary
  local work="$1" plugin="$1/hplip-plugin.run" dir="$1/plugin"
  warn "extracting firmware from the official HPLIP plugin (this can be slow)"
  if ! curl -fL --retry 5 --retry-delay 3 --max-time 3600 -o "$plugin" "$HPLIP_PLUGIN_URL"; then
    warn "could not download the HPLIP plugin"
    return 1
  fi
  mkdir -p "$dir"
  if ! bash "$plugin" --noexec --target "$dir" >/dev/null 2>&1; then
    warn "plugin self-extraction failed"
    return 1
  fi
  local gz
  gz="$(find "$dir" -name "$PLUGIN_FW_MEMBER" -print -quit 2>/dev/null)"
  if [[ -z "$gz" || ! -f "$gz" ]]; then
    warn "$PLUGIN_FW_MEMBER not found in the plugin"
    return 1
  fi
  gzip -dc "$gz" >"$work/firmware.bin" || { warn "gunzip failed"; return 1; }
  printf '%s' "$work/firmware.bin"
}

fetch_firmware() {
  local work; work="$(make_workdir)"
  local dest="$work/firmware.bin"

  if [[ -n "$FIRMWARE_FILE" ]]; then
    log "Using local firmware file: $FIRMWARE_FILE"
    cp -f "$FIRMWARE_FILE" "$dest" || die "cannot read $FIRMWARE_FILE"
  else
    log "Downloading firmware from $FIRMWARE_URL"
    if ! curl -fL --retry 5 --retry-delay 3 --retry-all-errors --max-time 300 \
              -o "$dest" "$FIRMWARE_URL"; then
      warn "firmware mirror unreachable"
      if [[ $PLUGIN_FALLBACK -eq 1 ]]; then
        dest="$(fetch_firmware_plugin "$work")" || die "both firmware sources failed"
      else
        die "could not download firmware. Set --firmware-file PATH, or retry with --plugin-fallback"
      fi
    fi
  fi

  verify_firmware "$dest" || die "firmware failed verification (incomplete or wrong file)"
  ok "firmware verified ($(stat -c %s "$dest") bytes)"

  log "Installing firmware into /lib/firmware/hp/"
  run install -d -m 755 /lib/firmware/hp
  run install -m 644 "$dest" "/lib/firmware/hp/$FIRMWARE_NAME"
  # Also provide the non-alias name so either lookup path works.
  run install -m 644 "$dest" /lib/firmware/hp/sihpP1007.dl
  rm -rf "$work"
  ok "firmware installed as $FIRMWARE_NAME"
}

# ---------------------------------------------------------------------------
# HPLIP proprietary plugin
# ---------------------------------------------------------------------------
# hpcups needs HP's plugin for the P1007: it carries the HBS printer driver
# (prnt/plugins/hbpl1.so), without which every job dies with
# "hplip.plugin-error / Filter failed". Debian cannot ship it, so fetch it.
plugin_installed() {
  [[ -f /usr/share/hplip/prnt/plugins/hbpl1.so ]] || return 1
  [[ -f /usr/share/hplip/data/firmware/hp_laserjet_p1007.fw.gz ]] || return 1
  return 0
}

install_hplip_plugin() {
  if plugin_installed; then
    ok "HPLIP plugin already installed"
    return 0
  fi

  log "Installing the HPLIP proprietary plugin (provides the HBS driver)"
  local work; work="$(make_workdir)"
  local run="$work/hplip-plugin.run"

  if [[ -n "${HPLIP_PLUGIN_FILE:-}" ]]; then
    cp -f "$HPLIP_PLUGIN_FILE" "$run" || die "cannot read $HPLIP_PLUGIN_FILE"
  else
    log "Downloading $HPLIP_PLUGIN_VER plugin (~11 MB)"
    if ! curl -fL --retry 5 --retry-delay 5 --retry-all-errors --max-time 3600 \
              -o "$run" "$HPLIP_PLUGIN_URL"; then
      die "could not download the HPLIP plugin. Get hplip-${HPLIP_PLUGIN_VER}-plugin.run from
       https://www.openprinting.org/download/printdriver/auxfiles/HP/plugins/
       and pass --hplip-plugin PATH"
    fi
  fi

  if command -v md5sum >/dev/null 2>&1 && [[ -n "$HPLIP_PLUGIN_MD5" ]]; then
    local got; got="$(md5sum "$run" | awk '{print $1}')"
    [[ "$got" == "$HPLIP_PLUGIN_MD5" ]] || die "plugin md5 mismatch: $got"
  fi
  ok "plugin verified"

  chmod +x "$run"
  local ext="$work/extracted"
  mkdir -p "$ext"
  bash "$run" --noexec --target "$ext" >/dev/null 2>&1 || die "could not unpack the plugin"

  # installPlugin.py looks for plugin.spec in $HOMEDIR
  if [[ -f "$ext/plugin.spec" ]]; then
    run cp -f "$ext/plugin.spec" /usr/share/hplip/plugin.spec
  fi

  ( cd "$ext" && python3 installPlugin.py -i ) >/dev/null 2>&1 || true
  rm -rf "$work"

  if plugin_installed; then
    ok "HPLIP plugin installed (hbpl1.so + P1007 firmware)"
  else
    die "plugin installation failed - hpcups cannot drive this printer without it"
  fi
}
# ---------------------------------------------------------------------------
# USB driver
# ---------------------------------------------------------------------------
# The kernel's usblp driver claims the printer's USB interface. CUPS drives the
# printer through libusb instead, and when usblp holds the interface the CUPS
# 'usb' backend logs:
#     DEBUG: Failed to detach "usblp" module from 03f0:4817
# and then cannot enumerate the printer at all - so the queue cannot be built
# and jobs fail. usblp is not needed here, so keep it away from this system.
configure_usb_driver() {
  local conf="/etc/modprobe.d/blacklist-usblp.conf"
  if [[ -f "$conf" ]] && grep -q '^blacklist usblp' "$conf"; then
    ok "usblp already blacklisted"
  else
    log "Blacklisting the usblp kernel driver (it prevents CUPS from using the printer)"
    if [[ $DRY_RUN -eq 1 ]]; then
      printf '  [dry-run] write %s\n' "$conf"
    else
      cat >"$conf" <<'USBEOF'
# Installed by usb-printer-airprint (install.sh).
#
# The usblp kernel driver claims the printer's USB interface. CUPS drives the
# printer through libusb instead and then fails with:
#     Failed to detach "usblp" module from 03f0:4817
# which leaves the printer invisible to the CUPS 'usb' backend.
blacklist usblp
USBEOF
    fi
    ok "usblp will no longer be loaded"
  fi

  if lsmod 2>/dev/null | grep -qE '^usblp'; then
    log "Unloading usblp"
    if ! run modprobe -r usblp; then
      warn "could not unload usblp (it may be in use) - the blacklist applies at next boot"
    fi
  fi
}

# ---------------------------------------------------------------------------
# CUPS configuration
# ---------------------------------------------------------------------------
backup_cups_config() {
  local backup="/root/cups-backup-$(date +%Y%m%d-%H%M%S)"
  run install -d -m 700 "$backup"
  if [[ -f /etc/cups/cupsd.conf ]]; then
    run cp -a /etc/cups/cupsd.conf "$backup/"
  fi
  if [[ -f /etc/cups/printers.conf ]]; then
    run cp -a /etc/cups/printers.conf "$backup/"
  fi
  ok "original CUPS config backed up to $backup"
}

write_cupsd_conf() {
  log "Writing /etc/cups/cupsd.conf (LAN listening + Bonjour + no-auth printing)"
  local tmp; tmp="$(mktemp)"

  cat >"$tmp" <<'CUPSDCONF'
#
# CUPS configuration managed by usb-printer-airprint (install.sh)
# USB printer shared to phones over WiFi.
#

LogLevel warn
PageLogFormat
MaxLogSize 0
ErrorPolicy retry-job

# --- network exposure -------------------------------------------------------
# Bind TCP 631 on every interface so phones on the WiFi can reach IPP.
#
# Both address families are required. "Listen 0.0.0.0:631" alone binds IPv4
# only, yet Bonjour still advertises the printer's IPv6 address - and iOS and
# Android prefer IPv6. The phone then resolves the printer to an address
# nothing is listening on and the printer never appears (or a job fails).
Listen 0.0.0.0:__PORT__
Listen [::]:__PORT__
Listen /run/cups/cups.sock

# Publish shared queues via DNS-SD (Bonjour/mDNS). This is what makes iPhone
# "AirPrint" and Android "Mopria / Default Print Service" discover the printer.
Browsing On
BrowseLocalProtocols dnssd

DefaultAuthType Basic

# Web admin UI at http://<host>:__PORT__/
WebInterface Yes

# cupsd is started on-demand by systemd (-l). 0 = never exit when idle, so the
# Bonjour advertisement survives between print jobs.
IdleExitTimeout 0

# --- access control ---------------------------------------------------------
<Location />
  Order allow,deny
  Allow __ALLOW__
</Location>

<Location /admin>
  AuthType Default
  Require user @SYSTEM
  Order allow,deny
  Allow __ALLOW__
</Location>

<Location /admin/conf>
  AuthType Default
  Require user @SYSTEM
  Order allow,deny
  Allow __ALLOW__
</Location>

<Location /admin/log>
  AuthType Default
  Require user @SYSTEM
  Order allow,deny
  Allow __ALLOW__
</Location>

# --- policy -----------------------------------------------------------------
# Printing needs no authentication for subnet clients (phones print without a
# password). Administration still requires @SYSTEM.
<Policy default>
  JobPrivateAccess default
  JobPrivateValues default
  SubscriptionPrivateAccess default
  SubscriptionPrivateValues default

  <Limit Create-Job Print-Job Print-URI Validate-Job>
    Order deny,allow
  </Limit>

  <Limit Send-Document Send-URI Hold-Job Release-Job Restart-Job Purge-Jobs Set-Job-Attributes Create-Job-Subscription Renew-Subscription Cancel-Subscription Get-Notifications Reprocess-Job Cancel-Current-Job Suspend-Current-Job Resume-Job Cancel-My-Jobs Close-Job CUPS-Move-Job>
    Require user @OWNER @SYSTEM
    Order deny,allow
  </Limit>

  <Limit CUPS-Get-Document>
    AuthType Default
    Require user @OWNER @SYSTEM
    Order deny,allow
  </Limit>

  <Limit CUPS-Add-Modify-Printer CUPS-Delete-Printer CUPS-Add-Modify-Class CUPS-Delete-Class CUPS-Set-Default CUPS-Get-Devices>
    AuthType Default
    Require user @SYSTEM
    Order deny,allow
  </Limit>

  <Limit Pause-Printer Resume-Printer Enable-Printer Disable-Printer Pause-Printer-After-Current-Job Hold-New-Jobs Release-Held-New-Jobs Deactivate-Printer Activate-Printer Restart-Printer Shutdown-Printer Startup-Printer Promote-Job Schedule-Job-After Cancel-Jobs CUPS-Accept-Jobs CUPS-Reject-Jobs>
    AuthType Default
    Require user @SYSTEM
    Order deny,allow
  </Limit>

  <Limit Cancel-Job>
    Require user @OWNER @SYSTEM
    Order deny,allow
  </Limit>

  <Limit CUPS-Authenticate-Job>
    AuthType Default
    Require user @OWNER @SYSTEM
    Order deny,allow
  </Limit>

  <Limit All>
    Order deny,allow
  </Limit>
</Policy>
CUPSDCONF

  sed -i "s#__PORT__#${CUPS_PORT}#g; s#__ALLOW__#${ALLOW_NET}#g" "$tmp"

  # Validate before installing - never leave CUPS with a broken config.
  if command -v cupsd >/dev/null 2>&1; then
    cupsd -t -c "$tmp" >/dev/null 2>&1 || die "generated cupsd.conf is invalid"
  fi
  run install -m 644 -o root -g lp "$tmp" /etc/cups/cupsd.conf
  rm -f "$tmp"
  ok "cupsd.conf installed and validated"
}

# ---------------------------------------------------------------------------
# printer queue
# ---------------------------------------------------------------------------
detect_device_uri() {
  if [[ -n "$DEVICE_URI" ]]; then
    printf '%s' "$DEVICE_URI"
    return 0
  fi
  local uri=""
  if [[ -x /usr/lib/cups/backend/usb ]]; then
    uri="$(/usr/lib/cups/backend/usb 2>/dev/null \
           | awk -v m="$USB_MODEL_MATCH" '$1=="direct" && index($0,m) {print $2; exit}')"
  fi
  if [[ -z "$uri" ]]; then
    uri="$(lpinfo -v 2>/dev/null | awk -v m="$USB_MODEL_MATCH" '/^direct usb:/ && index($0,m) {print $2; exit}')"
  fi
  if [[ -z "$uri" ]]; then
    # Last resort: HPLIP's backend can still see the device when something else
    # holds the USB interface. It forwards raw bytes, so the foo2xqx chain works
    # through it just as well.
    uri="$(lpinfo -v 2>/dev/null | awk -v m="$USB_MODEL_MATCH" '/^direct hp:\/usb\// && index($0,m) {print $2; exit}')"
    if [[ -n "$uri" ]]; then
      warn "falling back to HPLIP's backend URI: $uri"
    fi
  fi
  if [[ -n "$uri" ]]; then
    printf '%s' "$uri"
  fi
}

install_queue() {
  if ! lpinfo -m 2>/dev/null | grep -qF "$PPD_DRIVER_ID"; then
    die "CUPS driver '$PPD_DRIVER_ID' not found. Is printer-driver-foo2zjs installed?"
  fi
  ok "driver available: $PPD_DRIVER_ID"

  local uri
  uri="$(detect_device_uri || true)"
  if [[ -z "$uri" ]]; then
    warn "printer not detected on USB."
    warn "plug it in and re-run, or pass --device-uri 'usb://HP/LaserJet%20P1007?serial=XXXX'"
    die  "cannot continue without a device URI"
  fi
  ok "device URI: $uri"

  # Remove any stale queue with the same name first, so the PPD is rebuilt from
  # scratch instead of being silently inherited from the previous driver.
  run_soft lpadmin -x "$PRINTER_NAME"

  log "Creating CUPS queue '$PRINTER_NAME'"
  run lpadmin -p "$PRINTER_NAME" \
      -E \
      -v "$uri" \
      -m "$PPD_DRIVER_ID" \
      -D "$PRINTER_DESC" \
      -L "$PRINTER_LOCATION" \
      -o printer-is-shared=true

  run_soft cupsenable "$PRINTER_NAME"
  run_soft cupsaccept "$PRINTER_NAME"

  # Make sure the queue really got the driver we asked for. The classic silent
  # failure is a stale queue that keeps its old PPD, so the driver never changes.
  local ppd="/etc/cups/ppd/$PRINTER_NAME.ppd"
  if [[ -f "$ppd" ]]; then
    if [[ "$PPD_DRIVER_ID" == *hpcups* ]]; then
      grep -q 'hpcups' "$ppd" || die "queue PPD is not the hpcups driver - selection failed"
      plugin_installed || die "hpcups queue but the HPLIP plugin is missing"
    else
      # foo2xqx must never end up on an hpcups PPD
      grep -q 'hpcups' "$ppd" && die "queue PPD still references hpcups - driver selection failed"
      true
    fi
  fi
  ok "queue created with $PPD_DRIVER_ID"
}

# ---------------------------------------------------------------------------
# mDNS / Avahi
# ---------------------------------------------------------------------------
# Docker bridges are not on the real LAN, but Avahi happily publishes the
# printer on them anyway. Worse, it can answer the mDNS query for
# "<host>.local" with the *docker* bridge address - typically 172.17.0.1 -
# which no phone can reach. Discovery then fails quietly: the printer is
# reachable at its real address, the phone simply never finds it.
#
# Excluding the bridges fixes both halves of that.
configure_avahi() {
  local conf="/etc/avahi/avahi-daemon.conf"
  if [[ ! -f "$conf" ]]; then
    warn "$conf not found - skipping mDNS interface tuning"
    return 0
  fi

  local deny="" i
  for i in $(ls /sys/class/net 2>/dev/null); do
    case "$i" in
      docker*|br-*|veth*) deny="${deny:+$deny,}$i" ;;
    esac
  done

  if [[ -z "$deny" ]]; then
    ok "no docker bridge interfaces to exclude from mDNS"
  elif grep -q '^deny-interfaces=' "$conf"; then
    ok "avahi deny-interfaces already set: $(grep '^deny-interfaces=' "$conf" | cut -d= -f2)"
  else
    log "Excluding docker bridges from mDNS: $deny"
    if [[ $DRY_RUN -eq 1 ]]; then
      printf '  [dry-run] add deny-interfaces=%s to %s\n' "$deny" "$conf"
    else
      cp -a "$conf" "$conf.bak.$(date +%Y%m%d-%H%M%S)"
      sed -i "/^\[server\]/a deny-interfaces=${deny}" "$conf"
    fi
    ok "avahi will no longer advertise on docker bridges"
  fi

  run_soft systemctl restart avahi-daemon
}

# ---------------------------------------------------------------------------
# services / boot persistence
# ---------------------------------------------------------------------------
enable_services() {
  log "Enabling services at boot"
  run_soft systemctl enable --now avahi-daemon.service
  run systemctl enable cups.socket

  # cups.service is WantedBy=printer.target, which is NOT reached on a plain
  # boot - cupsd would only start when something connects locally. Add it to
  # multi-user.target explicitly so the print server (and its Bonjour
  # advertisement) is up right after boot.
  local unit
  unit="$(systemctl show -p FragmentPath --value cups.service 2>/dev/null || true)"
  if [[ -z "$unit" || ! -f "$unit" ]]; then
    unit="/lib/systemd/system/cups.service"
  fi
  run install -d -m 755 /etc/systemd/system/multi-user.target.wants
  run ln -sf "$unit" /etc/systemd/system/multi-user.target.wants/cups.service

  run systemctl daemon-reload
  run systemctl restart cups.service
  ok "services enabled"
}

install_firmware_timer() {
  log "Installing the printer watchdog"
  local helper="/usr/lib/udev/hplj${MODEL_TAG}"
  local recover="/usr/local/sbin/printer-firmware-refresh"
  if [[ ! -x "$helper" ]]; then
    warn "$helper not found - firmware refresh will be a no-op"
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    printf '  [dry-run] write %s\n' "$recover"
    printf '  [dry-run] write /etc/systemd/system/printer-firmware-refresh.service\n'
    printf '  [dry-run] write /etc/systemd/system/printer-firmware-refresh.timer\n'
  else
    cat >"$recover" <<'RECOVEREOF'
#!/bin/sh
# Installed by usb-printer-airprint (install.sh).
#
# Keeps the host-based P1007 usable:
#   1. reap anything wedged that is holding the USB device,
#   2. reload the printer firmware if it went missing,
#   3. revive the CUPS queue after a power cycle,
#   4. when software cannot fix it, SAY SO instead of hanging forever.
#
# Every device operation below is bounded by a timeout. An unbounded write to a
# wedged printer is what turns "firmware went missing" into a total deadlock:
# the stuck process keeps the USB device claimed, so every later job and every
# later firmware upload hangs as well.
set -u

QUEUE="__QUEUE__"
BACKEND="/usr/lib/cups/backend/usb"
FW="/lib/firmware/hp/__FIRMWARE_NAME__"
HELPER="/usr/lib/udev/hplj__MODEL_TAG__"
VID="__VID__"
PID="__PID__"
TAG="printer-firmware-refresh"

FW_TIMEOUT=90        # how long one firmware upload may take
STUCK_BACKEND=300    # a print backend alive this long is wedged
STATE_DIR=/run/printer-recovery
FAIL_FILE="$STATE_DIR/consecutive-failures"
BACKOFF_FILE="$STATE_DIR/backoff-until"
MAX_TRIES=3          # failed software recoveries before backing off
BACKOFF_SECS=1800

log() { logger -t "$TAG" "$*"; }
mkdir -p "$STATE_DIR" 2>/dev/null || true

fwver_present() {
  timeout 20 "$BACKEND" 2>/dev/null | grep -q FWVER
}

# Is a firmware upload legitimately in flight right now?
#
# udev starts one the moment the printer is switched on. Interrupting that is
# exactly what used to break recovery after a power cycle, so we must never
# kill a young upload - only one that has clearly hung.
upload_running() {
  for p in $(pgrep -f "$FW" 2>/dev/null); do
    et=$(ps -o etimes= -p "$p" 2>/dev/null | tr -d '[:space:]')
    if [ -n "${et:-}" ] && [ "$et" -le "$FW_TIMEOUT" ]; then
      return 0
    fi
  done
  return 1
}

# Free the USB device from anything that has wedged while holding it.
reap_wedged() {
  # Kill firmware uploads only once they have hung, never one still working.
  for p in $(pgrep -f "$FW" 2>/dev/null); do
    et=$(ps -o etimes= -p "$p" 2>/dev/null | tr -d '[:space:]')
    if [ -n "${et:-}" ] && [ "$et" -gt "$FW_TIMEOUT" ]; then
      log "killing hung firmware upload pid $p (alive ${et}s)"
      kill -9 "$p" 2>/dev/null || true
    fi
  done

  # A print backend alive for STUCK_BACKEND seconds has wedged. CUPS stops the
  # job but does not reliably reap the process, and the orphan keeps the device
  # claimed forever - blocking every later job and every firmware upload.
  for p in $(pgrep -f "$BACKEND" 2>/dev/null); do
    et=$(ps -o etimes= -p "$p" 2>/dev/null | tr -d '[:space:]')
    if [ -n "${et:-}" ] && [ "$et" -gt "$STUCK_BACKEND" ]; then
      log "killing wedged backend pid $p (alive ${et}s) - it held the printer"
      kill -9 "$p" 2>/dev/null || true
    fi
  done
}

# Reset the USB port. This re-enumerates the device, but note that it does NOT
# un-wedge the printer itself if the printer's own state machine is stuck.
reset_port() {
  python3 - "$VID" "$PID" <<'PYEOF' 2>/dev/null || true
import fcntl, glob, sys
USBDEVFS_RESET = (ord('U') << 8) | 20
vid, pid = sys.argv[1], sys.argv[2]
for base in glob.glob('/sys/bus/usb/devices/*'):
    try:
        if open(base + '/idVendor').read().strip() != vid:
            continue
        if open(base + '/idProduct').read().strip() != pid:
            continue
        node = '/dev/bus/usb/%03d/%03d' % (
            int(open(base + '/busnum').read().strip()),
            int(open(base + '/devnum').read().strip()))
    except Exception:
        continue
    try:
        with open(node, 'rb+', buffering=0) as f:
            fcntl.ioctl(f.fileno(), USBDEVFS_RESET, 0)
    except Exception:
        pass
PYEOF
}

# ------------------------------------------------------------------- main --
if fwver_present; then
  rm -f "$FAIL_FILE" "$BACKOFF_FILE" 2>/dev/null || true
else
  # A power cycle makes udev start a firmware upload by itself. Let it finish.
  if upload_running; then
    exit 0
  fi

  # Do not hammer a dead printer: after MAX_TRIES failures, wait it out.
  if [ -f "$BACKOFF_FILE" ]; then
    until=$(cat "$BACKOFF_FILE" 2>/dev/null || echo 0)
    [ "$(date +%s)" -lt "${until:-0}" ] && exit 0
  fi

  # Free the device before judging it. A wedged print backend claims the USB
  # device, which looks identical to missing firmware from out here.
  reap_wedged
  sleep 3

  if fwver_present; then
    log "printer was fine - a wedged process had been holding the USB device"
    rm -f "$FAIL_FILE" "$BACKOFF_FILE" 2>/dev/null || true
    exit 0
  fi

  log "printer reports no FWVER - firmware missing, attempting software recovery"
  reset_port
  sleep 5
  [ -x "$HELPER" ] && SUBSYSTEM=usb ACTION=add "$HELPER" add

  i=0
  while [ "$i" -lt 12 ]; do
    fwver_present && break
    sleep 5
    i=$((i + 1))
  done

  if fwver_present; then
    log "firmware restored by software recovery"
    rm -f "$FAIL_FILE" "$BACKOFF_FILE" 2>/dev/null || true
  else
    # Never leave a hung upload holding the device hostage (but do not touch
    # one that is still making progress).
    for p in $(pgrep -f "$FW" 2>/dev/null); do
      et=$(ps -o etimes= -p "$p" 2>/dev/null | tr -d '[:space:]')
      [ -n "${et:-}" ] && [ "$et" -gt "$FW_TIMEOUT" ] && kill -9 "$p" 2>/dev/null || true
    done
    fails=$(( $(cat "$FAIL_FILE" 2>/dev/null || echo 0) + 1 ))
    echo "$fails" >"$FAIL_FILE" 2>/dev/null || true
    if [ "$fails" -ge "$MAX_TRIES" ]; then
      echo $(( $(date +%s) + BACKOFF_SECS )) >"$BACKOFF_FILE" 2>/dev/null || true
      log "SOFTWARE RECOVERY FAILED ${fails}x. The printer is wedged; only a PHYSICAL"
      log "POWER CYCLE (switch the printer off, wait 10 s, switch it on again) clears it."
      log "Backing off for $((BACKOFF_SECS / 60)) minutes."
    else
      log "software recovery attempt ${fails} failed; will retry"
    fi
    exit 0
  fi
fi

# ---- revive the queue ----------------------------------------------------
if [ -e /etc/printer-no-auto-enable ]; then
  exit 0
fi
if lpstat -p "$QUEUE" 2>/dev/null | grep -qi disabled; then
  if cupsenable "$QUEUE" 2>/dev/null; then
    log "printer is back - re-enabled queue $QUEUE"
  fi
fi
exit 0
RECOVEREOF
    sed -i "s#__QUEUE__#${PRINTER_NAME}#g; s#__FIRMWARE_NAME__#${FIRMWARE_NAME}#g; s#__MODEL_TAG__#${MODEL_TAG}#g; s#__VID__#${USB_VID}#g; s#__PID__#${USB_PID}#g" "$recover"
    chmod 755 "$recover"

    cat >/etc/systemd/system/printer-firmware-refresh.service <<UNITEOF
[Unit]
Description=Keep the HP LaserJet ${MODEL_TAG} printer reachable and its queue usable
After=network.target cups.service
Wants=cups.service

[Service]
Type=oneshot
ExecStart=${recover}
TimeoutStartSec=600
UNITEOF

    cat >/etc/systemd/system/printer-firmware-refresh.timer <<'TIMEREOF'
[Unit]
Description=Periodically check that the USB printer is ready

[Timer]
OnBootSec=45s
OnUnitActiveSec=300s
AccuracySec=10s

[Install]
WantedBy=timers.target
TIMEREOF
  fi

  run udevadm control --reload-rules
  run systemctl daemon-reload
  run systemctl enable --now printer-firmware-refresh.timer
  run_soft systemctl start printer-firmware-refresh.service
  ok "printer watchdog active"
}

# ---------------------------------------------------------------------------
# verification
# ---------------------------------------------------------------------------

# Prove the render pipeline works *without* sending anything to the printer or
# using a sheet of paper: run the real CUPS filter chain and inspect the bytes
# it produces. A correct P1007 chain emits an HP PJL job with raster payload.
verify_pipeline() {
  local ppd="/etc/cups/ppd/$PRINTER_NAME.ppd"
  [[ -f "$ppd" ]] || return 0

  local work; work="$(make_workdir)"
  cat >"$work/in.ps" <<'PSEOF'
%!PS-Adobe-3.0
/Helvetica findfont 12 scalefont setfont
72 720 moveto (print pipeline check) show
showpage
PSEOF

  local rc=0
  if [[ "$PPD_DRIVER_ID" == *hpcups* ]]; then
    # hpcups consumes CUPS raster, not PostScript, so render one with gs first.
    local filter="/usr/lib/cups/filter/hpcups"
    if [[ ! -x "$filter" ]] || ! command -v gs >/dev/null 2>&1; then
      rm -rf "$work"; return 0
    fi
    gs -q -dBATCH -dSAFER -dNOPAUSE -sDEVICE=cups -sOutputFile="$work/in.raster" \
       -r600 -g5100x6600 -dDEVICEWIDTHPOINTS=595 -dDEVICEHEIGHTPOINTS=842 \
       -dcupsBitsPerColor=1 -dcupsColorSpace=3 -dcupsRowCount=1 -dcupsRowStep=1 \
       -dcupsInteger0=0 -dcupsInteger1=0 -dcupsInteger2=0 -dcupsInteger3=0 \
       "$work/in.ps" 2>/dev/null || rc=1
    PPD="$ppd" "$filter" 1 root pipeline-check 1 "PageSize=A4" "$work/in.raster" \
        >"$work/out.prn" 2>"$work/err.txt" || rc=1
  else
    local filter="/usr/lib/cups/filter/foomatic-rip"
    if [[ ! -x "$filter" ]]; then
      rm -rf "$work"; return 0
    fi
    PPD="$ppd" "$filter" 1 root pipeline-check 1 "PageSize=A4" "$work/in.ps" \
        >"$work/out.prn" 2>"$work/err.txt" || rc=1
  fi

  local size=0 magic=""
  if [[ -f "$work/out.prn" ]]; then
    size="$(stat -c %s "$work/out.prn" 2>/dev/null || echo 0)"
    magic="$(head -c 40 "$work/out.prn" | tr -d '\0')"
  fi

  # Both drivers must emit a real HP job: the PJL banner plus raster payload.
  if [[ $rc -eq 0 ]] && [[ "$size" -gt 500 ]] && [[ "$magic" == *PJL* ]]; then
    ok "render pipeline OK - produced $size bytes of HP PJL raster (no paper used)"
  else
    warn "render pipeline check failed (rc=$rc, $size bytes)"
    [[ -s "$work/err.txt" ]] && warn "  filter said: $(head -1 "$work/err.txt")"
  fi
  rm -rf "$work"
  return $rc
}

verify_install() {
  log "Verification"
  local fail=0

  if systemctl is-active --quiet cups.service; then ok "cups.service active"
  else warn "cups.service not active"; fail=1; fi

  if ss -tln 2>/dev/null | grep -q ":${CUPS_PORT} "; then
    ok "CUPS listening on IPv4 :${CUPS_PORT}"
  else
    warn "nothing listening on IPv4 :${CUPS_PORT}"; fail=1
  fi

  # Bonjour advertises IPv6 addresses as well, and phones prefer them. Missing
  # here is invisible until a phone silently refuses to use the printer.
  if ss -tln 2>/dev/null | grep -qE "\[::\]:${CUPS_PORT}|:::${CUPS_PORT}"; then
    ok "CUPS listening on IPv6 :${CUPS_PORT}"
  else
    warn "CUPS is not listening on IPv6 - phones that prefer IPv6 will fail"
    fail=1
  fi

  if lpstat -v 2>/dev/null | grep -q "$PRINTER_NAME"; then
    ok "queue '$PRINTER_NAME' present"
  else
    warn "queue '$PRINTER_NAME' missing"; fail=1
  fi


  if [[ -f "/lib/firmware/hp/$FIRMWARE_NAME" ]]; then
    ok "firmware present: /lib/firmware/hp/$FIRMWARE_NAME"
  else
    warn "firmware missing"; fail=1
  fi

  if systemctl is-active --quiet avahi-daemon; then
    if command -v avahi-browse >/dev/null 2>&1; then
      local n
      n="$(timeout 10 avahi-browse -rtp _ipp._tcp 2>/dev/null | grep -c '^=' || true)"
      if [[ "${n:-0}" -gt 0 ]]; then
        ok "printer advertised via Bonjour ($n _ipp._tcp records)"
      else
        warn "no _ipp._tcp advertisement seen yet (may take a few seconds)"
      fi
    else
      ok "avahi-daemon active"
    fi
  else
    warn "avahi-daemon not active - phones will not auto-discover"; fail=1
  fi

  verify_pipeline || fail=1

  # A printer that resolves to a docker bridge address is undiscoverable no
  # matter how healthy everything else looks, so check it explicitly.
  if command -v avahi-resolve >/dev/null 2>&1; then
    local resolved
    resolved="$(timeout 10 avahi-resolve -n "$(hostname).local" 2>/dev/null | awk '{print $2}' | head -1)"
    if [[ -z "$resolved" ]]; then
      warn "could not resolve $(hostname).local over mDNS yet"
    elif [[ "$resolved" == 172.1[6-9].* || "$resolved" == 172.2[0-9].* || "$resolved" == 172.3[01].* ]]; then
      warn "$(hostname).local resolves to $resolved (a docker bridge) - phones will not find the printer"
      fail=1
    else
      ok "mDNS: $(hostname).local -> $resolved"
    fi
  fi

  echo
  if [[ $fail -eq 0 ]]; then
    ok "All checks passed."
  else
    warn "Some checks failed - see messages above."
  fi
  return $fail
}

test_print() {
  log "Submitting a test page"
  local f; f="$(mktemp)"
  printf 'Print server test page\n\nHost: %s\nDate: %s\n\nIf you can read this, WiFi printing works.\n' \
    "$(hostname)" "$(date '+%F %T')" >"$f"
  if ! lp -d "$PRINTER_NAME" -t "installer-test" "$f"; then
    warn "could not submit test job"
    rm -f "$f"
    return 1
  fi
  rm -f "$f"
  sleep 12
  lpstat -l -W completed -o 2>/dev/null | tail -4
}

banner() {
  cat <<EOF
=============================================================
 USB printer -> WiFi/AirPrint print server  (install.sh v$VERSION)
=============================================================
  queue      : $PRINTER_NAME
  driver     : $PPD_DRIVER_ID
  firmware   : /lib/firmware/hp/$FIRMWARE_NAME
  listen     : 0.0.0.0:$CUPS_PORT
  clients    : $ALLOW_NET (printing is unauthenticated)
=============================================================
EOF
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  require_root "$@"
  fix_path
  if [[ $DRY_RUN -eq 0 ]]; then
    require_debian
  fi
  banner

  if [[ $UNINSTALL -eq 1 ]]; then
    do_uninstall
    exit 0
  fi

  install_packages
  configure_usb_driver
  fetch_firmware
  backup_cups_config
  write_cupsd_conf
  if [[ "$PPD_DRIVER_ID" == *hpcups* ]]; then
    install_hplip_plugin
  fi
  install_queue
  enable_services
  configure_avahi
  install_firmware_timer

  echo
  verify_install || true

  if [[ $DO_TEST -eq 1 ]]; then
    echo
    test_print || true
  fi

  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

  cat <<EOF

Done. How to print from a phone (must be on the same WiFi/LAN):

  iPhone / iPad  : Share -> Print -> "$PRINTER_DESC"  (AirPrint, no app needed)
  Android        : Settings -> Connected devices -> Printing -> enable the
                   default print service; the printer appears automatically.
                   Manual fallback: ipp://${ip}:${CUPS_PORT}/printers/${PRINTER_NAME}
  Browser        : http://${ip}:${CUPS_PORT}/

Note: this printer is host-based (GDI) and needs its firmware pushed on every
power-up. udev does that automatically the moment the printer is switched on.

A watchdog re-checks every 5 minutes. It reaps any process that has wedged
while holding the USB device, reloads missing firmware, and revives the queue
after a power cycle.

If a job ever hangs at "Sending data to printer", the printer itself has wedged
and no software can clear it: switch the printer OFF and ON again. Everything
then recovers on its own within a few seconds.
EOF
}

main "$@"
