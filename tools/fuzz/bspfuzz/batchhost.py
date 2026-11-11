#!/usr/bin/env python3
# Copyright (C) 2026 ref_mtl port
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or (at
# your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
#
# See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301, USA.

"""AE3: batched host driver for the BSP fallback.

The fallback exists because Mod_LoadBrushModel did not link into the
AE1 libFuzzer harness (mtl_model.m drags in the renderer/Metal
context).  The AE3 brief's batching idea was measured before being
used, on this tree:

- queued `+map a +map b ...` does NOT survive an ERR_DROP: the
  first Host_Error clears the command buffer, the remaining maps
  never load, the game subsystem shuts down and the client sits in
  the attract loop (measured with b_zeroedges.bsp, 2026-11-06);
- console input via stdin is dedicated-only
  (src/backends/unix/system.c: `if (!dedicated || !dedicated->value)
  return NULL;` before the stdin read), so an external process
  cannot type the next `map` into a running non-dedicated client.

So the outer loop restarts the host per map.  The host is launched
with `+map <name>`, the run is watched through qconsole.log plus the
captured stderr, and the process is terminated once the outcome is
known.  With the ASan host an ASan report is itself a finding: the
stack is kept per map.  Reports are one TSV row per map.

Throughput on this machine (measured by the driver itself, recorded
per row): process start + map load + settle, roughly 8-10 s/map
with the ASan host, i.e. several hundred maps per hour.

Round 23 (AF4.1) classification rules, all measured on the nb2 rerun
of the 86 old no-banner rows before being coded:

- the exit status separates hung / signal-death / clean exit (see
  sigtxt below);
- an "ERROR:" console line without the "Map: <name>" banner is an
  ERR_DROP during entity spawning - a rejection - and the host then
  parks in nextDrawable and never exits by itself (measured on
  af0016: sampled in the park, and a plain SIGTERM ends it within
  20 s); the driver takes the error line and stops it: outcome
  errdrop-nb;
- a host that printed neither banner nor error and is still alive at
  the deadline is quit-uncertain: the console gives no load verdict,
  and one relaunch is taken before the row is written;
- --keep-tail N archives the last N console lines of every
  not-loaded attempt under <work>/logs/ for the report.
"""

import argparse
import datetime
import os
import shutil
import signal
import subprocess
import sys
import time

SETTLE_SEC = 4.0          # after the "Map: <name>" banner before SIGTERM
POLL_SEC = 0.2
KILL_WAIT_SEC = 20.0      # SIGTERM patience; AF4.1 measured parked
                          # hosts end within 20 s of SIGTERM
BENIGN_ERRORS = {
    "ERROR: OpenAL failed to initialize.",
}


def read_log(path):
    try:
        with open(path, "r", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def run_map_once(host, datadir, cfgdir, mapsdir, name, timeout):
    """One host attempt.  Returns (outcome, secs, detail, logtxt,
    rc, we_killed).  outcome from the poll/watch rules only:
    asan, errdrop, errdrop-nb, loaded, post-crash, no-banner,
    quit-uncertain.  cfgdir is the resolved game-config dir
    (<work>/hgame): with HOME=<work> and `-cfgdir hgame` the engine
    writes under it."""
    log = os.path.join(cfgdir, "baseq2", "qconsole.log")
    try:
        os.remove(log)
    except OSError:
        pass
    # Keep the staged maps visible: they live under the cfgdir's game
    # dir, which the engine scans before the paks.
    dstmaps = os.path.join(cfgdir, "baseq2", "maps")
    os.makedirs(dstmaps, exist_ok=True)
    src = os.path.join(mapsdir, name + ".bsp")
    dst = os.path.join(dstmaps, name + ".bsp")
    if os.path.abspath(src) != os.path.abspath(dst):
        shutil.copyfile(src, dst)

    # HOME is the config root; the -cfgdir name is looked up under it.
    env = dict(os.environ, HOME=os.path.dirname(cfgdir))
    cmd = [host, "-datadir", datadir, "-cfgdir", os.path.basename(cfgdir),
            "+set", "game", "baseq2", "+set", "vid_renderer", "mtl",
            "+set", "vid_fullscreen", "0", "+set", "logfile", "2",
            "+map", name]
    t0 = time.time()
    proc = subprocess.Popen(cmd, cwd=os.path.dirname(cfgdir), env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    banner = "Map: %s" % name
    pre_err = None
    detail = ""
    deadline = t0 + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            break
        logtxt = read_log(log)
        if banner in logtxt:
            # Gave the load its settle window, then judge and stop it.
            end = time.time() + SETTLE_SEC
            while time.time() < end and proc.poll() is None:
                time.sleep(POLL_SEC)
            break
        # AF4.1: an ERR_DROP during SpawnEntities never reaches the
        # "Map:" banner (the banner lands after a successful spawn).
        # Measured on af0016: the host prints ERROR: ..., runs the
        # shutdown banners, and then sits in RE_BeginFrame ->
        # [CAMetalLayer nextDrawable] forever (sampled: 215/215
        # main-thread samples in _dispatch_semaphore_wait_slow), so
        # waiting the full timeout buys nothing: take the error line
        # and stop the host.
        # BENIGN: the OpenAL line this machine prints at EVERY boot
        # (no sound device); the fix_verify gate greps the same line
        # as benign.  Without the skip, every still-loading map dies
        # at 0.8 s on it (measured in the smoke run).
        if "ERROR:" in logtxt:
            errs = [ln for ln in logtxt.splitlines()
                    if ln.startswith("ERROR:")
                    and ln not in BENIGN_ERRORS]
            if errs:
                pre_err = errs[0]
                break
        time.sleep(POLL_SEC)

    if proc.poll() is None:
        we_killed = True
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=KILL_WAIT_SEC)
        except subprocess.TimeoutExpired:
            # AF4.1 measured: a host parked in nextDrawable does not
            # even die on SIGTERM within the wait; SIGKILL it.
            proc.kill()
            proc.wait()
    else:
        we_killed = False
    stderr = proc.stderr.read().decode("utf-8", "replace")
    secs = time.time() - t0
    logtxt = read_log(log)
    rc = proc.returncode
    if we_killed:
        sigtxt = ("hung-killed" if rc in (None, -signal.SIGTERM,
                  -signal.SIGKILL) else "exited-%s-after-TERM" % rc)
    elif rc is not None and rc < 0:
        sigtxt = "died-signal-%d" % -rc
    elif rc == 0:
        sigtxt = "exit-0"
    else:
        sigtxt = "exit-%d" % rc

    if "AddressSanitizer" in stderr:
        outcome = "asan"
        first = [ln for ln in stderr.splitlines()
                if "AddressSanitizer" in ln]
        detail = (first[0] if first else "asan")[:200]
        keep = os.path.join(os.path.dirname(cfgdir), "reports")
        os.makedirs(keep, exist_ok=True)
        with open(os.path.join(keep, name + ".asan.txt"), "w") as f:
            f.write(stderr)
    elif pre_err is not None:
        # AF4.1: ERR_DROP that never reached the Map: banner.  The
        # engine REJECTED the map; sigtxt says whether it then exited
        # or had to be killed out of the post-error redraw park.
        outcome = "errdrop-nb"
        detail = ("%s | console-err: %s" % (sigtxt, pre_err[:200]))[:400]
    elif banner in logtxt:
        # AF4.1/AG4: banner printed first, ERROR: after it.  The split
        # must skip the BENIGN OpenAL line the way the watch loop does:
        # AG4 measured that splitting on the FIRST "ERROR:" (always the
        # OpenAL boot line, before the banner) put every post-banner
        # rejection into the "loaded" bucket - af0176's AG1 reject line
        # ("node 0 at surface 65535 ... exceeds the 8055 surfaces")
        # sat in a run logged exactly like that, labelled loaded.
        errs = [ln for ln in logtxt.splitlines()
                if ln.startswith("ERROR:") and ln not in BENIGN_ERRORS]
        if errs:
            outcome = "errdrop"
            detail = errs[0][:200]
        elif (rc is not None) and (rc < 0) and not we_killed:
            # AF4: banner printed, then the host died by a signal
            # without the driver touching it: a post-load crash.
            # On a release host (no ASan reports) this is the only
            # way to see it; calling it "loaded" would hide it.
            outcome = "post-crash"
            detail = "%s | log-tail: %s" % (sigtxt,
                (logtxt.splitlines()[-1][:200] if logtxt else ""))
        else:
            # A loaded run is ended by the driver's own SIGTERM, so
            # we_killed is expected here and must not fall through
            # to the quit-uncertain rule.
            outcome = "loaded"
    elif we_killed:
        # AF4.1: the host never reported the map load, never printed
        # ERROR:, and was still alive at the deadline.  The console
        # gives no load verdict; calling it loaded or rejected would
        # be a guess.
        outcome = "quit-uncertain"
        tail = [ln for ln in logtxt.splitlines() if ln.strip()]
        detail = ("%s | log-tail: %s | killed after banner-less hang; "
                  "engine quit not observable" % (sigtxt,
                  (tail[-1][:120] if tail else "<empty log>")))[:400]
    else:
        # AF4.1: crash by signal, or clean exit, without ever
        # printing the banner and without an ERROR: line.  For the
        # clean ones, the last log line and the first stderr line
        # say why the engine stopped (missing map, ERR_DROP text
        # that never reached the log, driver abort...).
        outcome = "no-banner"
        tail = [ln for ln in logtxt.splitlines() if ln.strip()]
        errl = [ln for ln in stderr.splitlines() if ln.strip()]
        detail = ("%s | log-tail: %s | stderr-first: %s" % (
            sigtxt,
            (tail[-1][:120] if tail else "<empty log>"),
            (errl[0][:120] if errl else "<empty stderr>")))[:400]
    return outcome, secs, detail, logtxt, rc, we_killed


def run_map(host, datadir, cfgdir, mapsdir, name, timeout):
    """run_map_once plus the AF4.1 relaunch rule: if the first
    attempt had to be killed without the console ever showing this
    map's load outcome, try once more; only if that one is killed
    too does the map get the quit-uncertain row.  A map whose first
    quit was just an ignored SIGTERM (SIGKILL followed) is not
    re-judged as if it were clean - the second attempt is what the
    row is based on."""
    outcome, secs, detail, logtxt, rc, we_killed = run_map_once(
            host, datadir, cfgdir, mapsdir, name, timeout)
    if outcome == "quit-uncertain":
        outcome, secs2, detail, logtxt, rc, we_killed = run_map_once(
                host, datadir, cfgdir, mapsdir, name, timeout)
        secs += secs2
    return outcome, secs, detail, logtxt, rc, we_killed


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--host", required=True, help="quake2 binary to run")
    ap.add_argument("--datadir", required=True)
    ap.add_argument("--maps", required=True, help="dir of staged af*.bsp")
    ap.add_argument("--work", required=True, help="scratch dir for cfgdirs")
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--out", default=None, help="results TSV (default "
            "<work>/results.tsv)")
    ap.add_argument("--keep-tail", type=int, default=0, metavar="N",
            help="keep the last N console log lines of every attempt "
            "that is not 'loaded' under <work>/logs/ (AF4.1 evidence)")
    args = ap.parse_args()

    os.makedirs(args.work, exist_ok=True)
    cfgdir = os.path.join(args.work, "hgame")
    os.makedirs(cfgdir, exist_ok=True)
    out = args.out or os.path.join(args.work, "results.tsv")

    names = sorted(fn[:-4] for fn in os.listdir(args.maps)
            if fn.endswith(".bsp"))
    counts = {}
    with open(out, "w") as tsv:
        tsv.write("map\toutcome\tsecs\tdetail\n")
        for i, name in enumerate(names):
            outcome, secs, detail, logtxt, rc, we_killed = run_map(
                    args.host, args.datadir, cfgdir, args.maps, name,
                    args.timeout)
            counts[outcome] = counts.get(outcome, 0) + 1
            tsv.write("%s\t%s\t%.1f\t%s\n" % (name, outcome, secs, detail))
            tsv.flush()
            if args.keep_tail and outcome != "loaded":
                keep = os.path.join(args.work, "logs")
                os.makedirs(keep, exist_ok=True)
                tail = [ln for ln in logtxt.splitlines() if ln.strip()]
                with open(os.path.join(keep, name + ".tail.txt"), "w") as f:
                    f.write("rc=%s killed=%s\n" % (rc, we_killed))
                    f.write("\n".join(tail[-args.keep_tail:]) + "\n")
            print("[%4d/%4d] %-13s %6.1fs  %s" % (i + 1, len(names),
                    outcome, secs, detail))
    total = time.time()
    print("counts:", counts)
    return 0 if counts.get("asan", 0) == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
