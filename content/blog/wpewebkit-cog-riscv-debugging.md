+++
title = "Debugging WPE WebKit & Cog Startup Hangs on RISC-V"
date = "2026-06-21"
description = "A forensic analysis of threading and synchronization loops in WPE WebKit on the Allwinner D1 RISC-V SoC."
tags = ["risc-v", "webkit", "debugging", "linux", "embedded"]
categories = ["debugging"]
+++

## The Symptom

When building a lightweight Home Assistant touchscreen kiosk using a **Mango Pi MQ Pro** (Allwinner D1 RISC-V SoC), I opted to bypass a heavy desktop environment. Instead, I ran a bare-metal Wayland compositor (**Cage**) and the lightweight WPE WebKit browser engine launcher (**Cog**). 

However, during boot initialization, the browser would launch a blank window and hang indefinitely, never attempting to resolve or load the target Home Assistant URL.

---

## Initial Investigation & Forensics

To locate the bottleneck, I logged into the board via serial console and inspected resource utilization with `htop` and `ps`.

The CPU was spinning constantly. Taking a thread trace of the `cog` process revealed the following state:

```
    PID     TID COMMAND         %CPU WCHAN
    9166    9166 cog              1.0 -
    9166    9363 ebsiteDataStore  0.0 -
    9166    9364 olveDirectories 37.9 -
    9166    9366 gmain            0.0 -
```

A dedicated worker thread, `ResolveDirectories` (`TID 9364`), was permanently spinning at **~38% CPU** (consuming nearly all CPU time allocated to it on this single-core board), while the main thread (`PID 9166`) remained blocked in a `futex_wait` queue.

---

## Isolating the Variables

To rule out disk I/O, cache size corruption, and user configurations, I tested several configurations:

1. **JIT compilation bug?** Bypassed the JavaScript JIT compiler by launching with `JavaScriptCoreUseJIT=0`. The hang persisted.
2. **WebKit Sandboxing issues?** Disabled the internal web process sandbox (`WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1`). The hang persisted.
3. **Huge cache lookup bottlenecks?** Under `/home/fin/.cache/yay/`, there were over 228,000 intermediate compiler files from AUR packages. Since WebKit scans home directories on startup, I redirected the directories:
   ```bash
   export XDG_CACHE_HOME=/tmp
   export XDG_DATA_HOME=/tmp
   export HOME=/tmp
   ```
   The thread still spun at the exact same instruction.
4. **Wayland connection contention?** Ran Cog in headless mode (`cog --platform=headless`). The thread trace was identical.

---

## The Root Cause

By attaching `gdb` to the spinning thread, I traced the execution back to low-level assembly instruction loops. 

The spinning occurs inside WebKit's platform-specific directory resolution library. In the Debian Sid RISC-V compilation of WPE WebKit, directory resolution uses atomic thread synchronization operations. 

On the **T-Head C906 RISC-V core**, atomic operations are supported, but certain compiler toolchains emit atomic lock sequences that loop indefinitely when there is no hardware atomic bus locking between memory banks, or when non-lock-free structures fail to synchronize correctly under specific thread scheduling.

This causes `ResolveDirectories` to enter an infinite loop trying to acquire a lock that was already set by another thread, while the main thread waits indefinitely for the directory manifest.

---

## Current Workarounds

To bypass this build-specific bug while the WebKit package is being patched for RISC-V:
1. **ZRAM & Swap**: We verified that 4.5GB swap is active to prevent OOM when the browser runs, as memory constraints worsen threading collisions.
2. **Package pinning**: Downgraded to a stable Debian Ports release of WPE WebKit which compiles atomic locks using alternative libatomic routines, bypassing the T-Head compiler bug and successfully loading the kiosk dashboard.
