+++
title = "The MicroPython Boot Loop: Chasing an OTA Bug Across Three ESP32 Devices"
date = "2026-07-08"
description = "How a missing write to a version field turned every firmware update into an infinite reboot cycle, and why sys.path ordering on MicroPython can silently shadow your entire codebase."
tags = ["micropython", "esp32", "embedded", "debugging", "ota", "homelab"]
categories = ["debugging"]
+++

## The Symptom

It started as a minor annoyance: the e-paper frames in my
[PicFrames](/projects/picframes-epaper-controller/) fleet had stopped cycling photos. The
displays were showing images — the same images they'd been showing for days — but the server
dashboard showed none of the devices had phoned home recently. No `last_seen` timestamps, no
firmware version reported, just stale check-ins from before I'd pushed the latest firmware
release.

I figured a device had dropped off wifi or the server had a bug. I checked the server logs.
The server was fine. I pulled up the ESP32's serial output over USB to see what was happening.

The device was booting. Then downloading something. Then rebooting. Then booting. Then
downloading. Over and over, every fifteen seconds or so.

All three devices were doing it.

---

## Background: The Update Flow

The [PicFrames server](https://github.com/finn-e/picframes-server) is a Flask backend running
in Kubernetes that manages a fleet of ESP32-S3 e-paper picture frames. Each device runs
MicroPython firmware. On boot, the device calls `/api/update` with its current firmware
version; if the server has a newer release, it returns a ZIP URL. The device downloads the ZIP,
extracts the `.py` files to a staging directory, and reboots. On the next boot, the new files
run.

The version comparison looked like this: the server takes the device-reported version string,
parses it as a tuple, and compares it against the latest release on GitHub. If the device
version is lower, update. Simple enough.

---

## Finding the Root Cause

I added some logging to the boot sequence and stared at the output:

```
Checking for updates...
Current version: ''
Server latest: 0.9.0
Downloading update zip...
Applying update...
Reboot.
```

The current version was always `''`. Empty string. Every single boot.

The firmware was supposed to write its version string into a field in the on-device config
after a successful update. But searching the codebase, I found that nothing ever actually
wrote `sd_cfg['update_version']`. The field was read on startup, compared against the server's
latest, and then... the update was applied, the device rebooted, and on the next boot the
field was still empty. The server saw `''`, parsed it as version `(0, 0, 0)`, saw that
`0.0.0 < 0.9.0`, and sent down the update URL again.

Every boot triggered a full firmware download. The device spent its entire uptime stuck in
the update cycle, never reaching the code that called `/api/daily-config`, which is what
registers the `last_seen` timestamp and reports the firmware version to the dashboard. From
the server's perspective, the devices had simply disappeared.

This bug had apparently been latent for a while. In older firmware versions, `update.py`
was version-gated in a way that caused it to return `False` on a re-apply (same version
already installed), which made the device fall through to the daily-config call. The v0.4.0
rewrite removed that guard, and suddenly the missing `update_version` write became fatal.
The devices that "worked" before v0.4.0 had just been getting lucky.

---

## Why the Fix Didn't Work (The sys.path Problem)

Once I understood the root cause, I pushed a corrected version of the firmware — the one that
actually writes `update_version` after a successful update. I waited. The devices kept
boot-looping.

I copied the new files directly to the device over USB using `mpremote`. Still boot-looping.

This didn't make sense. I could see the corrected files on the device's flash filesystem. But
the serial output was still showing the old behavior.

I added a print statement at the very top of the entry-point file — before any imports — and
confirmed it was running. Then I added one to the update module itself. That print statement
*never appeared*. The device was somehow importing a different `update.py`.

MicroPython resolves imports via `sys.path`. I looked at the `main.py` startup sequence:

```python
# From XIAO-EE04-7in3/main.py, line 104 (approximately)
sys.path.insert(0, '/images')
```

The `/images` directory was the OTA staging area — the place where downloaded firmware ZIPs
got extracted before reboot. And it was being inserted at the *front* of `sys.path`, before
the flash root.

Old firmware versions had staged their `.py` files into `/images` and left them there. So
even though I'd copied fresh files to the flash root, Python was finding and importing the
stale copies in `/images` first. My `mpremote cp` command had been updating `/api.py` on
flash, but the device was importing `/images/api.py` — a version from several releases back
that didn't accept the `fw_version` keyword argument I'd added.

The error in the logs (which I hadn't initially spotted because it was buried in the boot-loop
noise):

```
/api/update failed: unexpected keyword argument 'fw_version'
```

The device hit an exception in the update call, fell into the offline fallback loop, slept
900 seconds, and woke up to try again. Catch-22: the OTA system was broken because of stale
files left by the OTA system.

---

## The Recovery

For the XIAO device, the fix had to be manual. The device woke up every 900 seconds with a
short countdown before entering MicroPython's boot sequence — just long enough to attach
`mpremote` and issue a raw exec command:

```python
import os
[os.remove('/images/' + f) for f in os.listdir('/images') if f.endswith('.py')]
```

Clear the stale `.py` files from the staging directory, reset the device. On the next boot,
the flash-root files (already updated) ran cleanly, the OTA completed successfully, and
`update_version` got written. The device phoned home, reported firmware version `0.9.0`, and
started cycling photos.

The PhotoPainter device was in better shape — its staging directory happened to have been
cleared at some point during a prior release cycle, so it wasn't shadowed. It healed
automatically once the server-side fix was deployed.

For the fleet fix, the `main.py` for all three board variants needed two changes:
1. Remove the staging directory from the front of `sys.path` (or append it rather than prepend).
2. Add a startup migration step that deletes any stale `.py` files from the staging directory,
   so devices already in a bad state can heal via OTA without manual intervention.

---

## What I Should Have Caught Earlier

The missing `update_version` write was in a code path I'd added but never had a device
actually exercise successfully during testing — I'd been testing OTA with devices that already
had the version field populated from a prior manual write. The field appeared in the config,
the reads worked, and I didn't notice nothing was writing to it post-update.

The `sys.path` issue is a general MicroPython footgun. Unlike CPython, there's no packaging
system keeping staging directories and installed packages separate. If you're extracting OTA
ZIPs into a directory on device and that directory is on `sys.path` — especially if it's
first on `sys.path` — old files from previous extractions will silently shadow your current
code until you clean them up. The fix is to either always clean the staging directory before
extraction, or not put it on `sys.path` at all until you're ready to import from it.

The longer-term fix is better test coverage for the update path itself. There are now tests
for the server's queue logic and refresh behavior, but the firmware update cycle was only
tested manually on hardware. That made this class of bug nearly invisible until it hit
production.

---

## Current Status

All three frames are running `0.9.0`, cycling photos, and reporting in regularly. The open
bug — slideshow advancement not triggering on timer-wake polls, only on button presses — is
tracked separately. That one's a protocol disagreement between the server and firmware about
when to advance the index, not an OTA issue.

You can follow the project at [github.com/finn-e/picframes-server](https://github.com/finn-e/picframes-server).
