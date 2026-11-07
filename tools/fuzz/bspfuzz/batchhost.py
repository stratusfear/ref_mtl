#!/usr/bin/env python3
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


def read_log(path):
    try:
        with open(path, "r", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def run_map(host, datadir, cfgdir, mapsdir, name, timeout):
    """Run one host boot that loads `name`.  Returns (outcome, secs,
    detail).  outcome is one of loaded, errdrop, asan, timeout,
    no-banner.  cfgdir is the resolved game-config dir (<work>/hgame):
    with HOME=<work> and `-cfgdir hgame` the engine writes under it."""
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
    outcome, detail = "timeout", ""
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
        time.sleep(POLL_SEC)

    if proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
    stderr = proc.stderr.read().decode("utf-8", "replace")
    secs = time.time() - t0
    logtxt = read_log(log)

    if "AddressSanitizer" in stderr:
        outcome = "asan"
        first = [ln for ln in stderr.splitlines()
                if "AddressSanitizer" in ln]
        detail = (first[0] if first else "asan")[:200]
        keep = os.path.join(os.path.dirname(cfgdir), "reports")
        os.makedirs(keep, exist_ok=True)
        with open(os.path.join(keep, name + ".asan.txt"), "w") as f:
            f.write(stderr)
    elif banner in logtxt:
        line = logtxt.split("ERROR:", 1)
        if len(line) > 1 and banner in line[0]:
            outcome = "errdrop"
            detail = line[1].splitlines()[0][:200]
        else:
            outcome = "loaded"
    else:
        outcome = "no-banner"
        detail = "host never printed the map banner"
    return outcome, secs, detail


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--host", required=True, help="quake2 binary to run")
    ap.add_argument("--datadir", required=True)
    ap.add_argument("--maps", required=True, help="dir of staged af*.bsp")
    ap.add_argument("--work", required=True, help="scratch dir for cfgdirs")
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--out", default=None, help="results TSV (default "
            "<work>/results.tsv)")
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
            outcome, secs, detail = run_map(args.host, args.datadir,
                    cfgdir, args.maps, name, args.timeout)
            counts[outcome] = counts.get(outcome, 0) + 1
            tsv.write("%s\t%s\t%.1f\t%s\n" % (name, outcome, secs, detail))
            tsv.flush()
            print("[%4d/%4d] %-9s %6.1fs  %s" % (i + 1, len(names),
                    outcome, secs, detail))
    total = time.time()
    print("counts:", counts)
    return 0 if counts.get("asan", 0) == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
