+++
title = "Chasing a Ghost Subnet: AdGuard Home, DHCP, and a Bad /22 Experiment"
date = "2026-07-01"
description = "A late-night debugging session that started with intermittent WiFi drops and ended with a Python revert script patching four OpenTofu files at once."
tags = ["networking", "dns", "adguard", "homelab", "kubernetes", "debugging", "python"]
categories = ["debugging"]
+++

## The Symptom

It started with the PlayStation. My partner came downstairs to let me know PSN was throwing
connection errors even though everything else on the network seemed fine. Browsers loaded pages,
Home Assistant was responding, music was streaming — but the console insisted it had no internet.

I pulled up AdGuard Home's query log and saw a pattern immediately: DNS queries from the PS5's
IP were resolving fine, but `us-prof.np.community.playstation.net` and
`status.playstation.com` were returning `SERVFAIL` on roughly every third attempt. Not
consistently failing — intermittently, which is the worst kind.

My homelab runs [AdGuard Home](https://github.com/AdguardTeam/AdGuardHome) as the network-wide
DNS server and DHCP authority, deployed in my Kubernetes cluster on
[Mimisbrunnr](/projects/mimisbrunnr-home-server/). It runs with host networking pinned to a
specific node. I'd been planning to expand the DHCP range anyway, so I figured I'd kill two birds
with one stone and investigate while tuning the config.

---

## The Investigation

My first suspicion was rate limiting. AdGuard Home has a `ratelimit` setting in the DNS block,
and I'd read that some upstream resolvers could throttle burst queries from a single IP. I wrote a
quick diagnostic script to probe both DNS servers and characterize what was actually happening:

```python
GATEWAY = "192.168.1.254"
DNS_SERVERS = ["192.168.1.81", "192.168.1.43"]
DOMAINS = [
    "google.com",
    "captive.apple.com",        # iOS internet check
    "connectivity-check.ubuntu.com",
    "us-prof.np.community.playstation.net",  # PSN
    "status.playstation.com"
]
```

The script sent raw DNS queries (hand-built UDP packets, bypassing the system resolver) and
measured response times and RCODEs. It also hit 100 rapid queries against synthetic subdomains
to test rate limiting, and probed the web console ports to confirm which node was actually
handling DNS at any given moment.

The results were interesting. Both DNS servers — the AdGuard instance at `.81` and a fallback
at `.43` — were responding to most queries fine. Average latency was 20–40ms for common domains.
But the PSN domains showed something weird: they'd return `NOERROR` with valid records, then
`SERVFAIL` on the next query, then `NOERROR` again. The pattern was inconsistent enough that
I initially suspected the upstream resolvers (Cloudflare DoH and Google DoH in load-balance mode)
were having a bad day.

I checked AdGuard's logs more carefully and noticed the SERVFAIL responses were originating
*locally* — AdGuard was generating them, not returning them from upstream. That pointed to the
DNSSEC validation path. I confirmed `enable_dnssec: false` in the config, so that wasn't it.

Then I noticed something in the DHCP section of the config.

---

## The Real Problem (And Where I Made Things Worse)

The DHCP range was set tightly: `192.168.1.100` to `192.168.1.199`, subnet mask `255.255.255.0`.
My cluster nodes sat at `.42`–`.44`, AdGuard at `.81`, the gateway at `.254` — all fine. But
some devices were landing outside the DHCP range and getting stale ARP entries when they
switched between WiFi access points. The PS5 had apparently grabbed a lease that conflicted with
a static assignment on a different device.

The immediate fix was easy: extend the DHCP range to `.253` and shorten the lease duration from
86400 seconds (24 hours) to 21600 (6 hours) so stale leases cleared faster. While I was in
there, I also added `edns_buffer_size: 4096` to the DNS block — I'd seen recommendations that
smaller buffer sizes caused fragmented UDP responses on some networks.

I wrote a quick Python script to apply these changes to the working copy of `AdGuardHome.yaml`:

```python
# edit_config.py
config_path = "./tmp/AdGuardHome.yaml"

content_new = re.sub(
    r"range_end:\s*192\.168\.1\.199",
    "range_end: 192.168.1.253",
    content
)
content_new = re.sub(
    r"lease_duration:\s*86400",
    "lease_duration: 21600",
    content_new
)
if "edns_buffer_size" not in content_new:
    content_new = re.sub(
        r"dns:\n",
        "dns:\n  edns_buffer_size: 4096\n",
        content_new,
        count=1
    )
```

Fine. Applied, deployed, problem resolved. The PSN errors went away — probably just the stale
lease clearing. I should have stopped there.

Instead, I started wondering if the network would be better on a `/22` supernet. The cluster
currently sat on `192.168.1.0/24`, but I had IoT devices on a separate VLAN at `192.168.2.x`
and was routing between them. If I collapsed everything into one `/22` (`192.168.0.0/22`,
covering `.0` through `.3.255`), inter-VLAN traffic would be local and I'd avoid the hairpin
through the gateway.

This seemed like a good idea at midnight. I wrote a second script:

```python
# edit_config_v2.py — "the mistake"
content_new = re.sub(
    r"subnet_mask:\s*[\"']?255\.255\.255\.0[\"']?",
    'subnet_mask: "255.255.252.0"',
    content
)
content_new = re.sub(
    r"range_start:\s*[\"']?192\.168\.1\.100[\"']?",
    'range_start: "192.168.2.10"',
    content_new
)
content_new = re.sub(
    r"range_end:\s*[\"']?192\.168\.1\.(?:199|253)[\"']?",
    'range_end: "192.168.2.250"',
    content_new
)
```

I also updated the OpenTofu infrastructure configs to match: four `.tf` files had the `/24`
subnet hardcoded — `main.tf` (node address blocks), `home_assistant.tf` (allowed networks),
`media_stack.tf` (environment variable), and `adguard.tf` (the DHCP config template).

```
addresses = ["${var.control_plane_ips[count.index]}/22"]   # main.tf
- 192.168.0.0/22                                            # home_assistant.tf
value = "192.168.0.0/22"                                    # media_stack.tf
```

Applied the AdGuard config. Waited for the DHCP daemon to restart inside the pod.

Everything broke immediately.

---

## The Rollback

The cluster nodes couldn't reach AdGuard's DNS anymore — they were still configured with
`/24` routes and the new DHCP range was handing out `/22` leases in the `.2.x` space, which
my router didn't know how to route to the cluster. Half the pods went into crashloop because
they couldn't resolve internal service names. Home Assistant lost its database connection.

I still had SSH-equivalent access via `talosctl` and could reach the node at its static IP
directly. The AdGuard pod was in a bad state but the node itself was fine. I reverted the
AdGuard config first — manually, by editing the mounted configmap — which got DNS back for
the cluster.

Then I realized I'd already committed the `/22` changes to four `.tf` files and the next
`tofu apply` would push them back. So I wrote `edit_config_revert.py` (which reverted the
AdGuard YAML back to `/24`) and `revert_tf_files.py` to walk all four OpenTofu files and
patch the strings back:

```python
# revert_tf_files.py
# Revert main.tf
main_tf = main_tf.replace(
    'addresses = ["${var.control_plane_ips[count.index]}/22"]',
    'addresses = ["${var.control_plane_ips[count.index]}/24"]'
)

# Revert home_assistant.tf
ha_tf = ha_tf.replace("- 192.168.0.0/22", "- 192.168.1.0/24")

# Revert media_stack.tf
media_tf = media_tf.replace('value = "192.168.0.0/22"', 'value = "192.168.1.0/24"')

# Revert adguard.tf
adguard_tf = adguard_tf.replace('subnet_mask: "255.255.252.0"', 'subnet_mask: "255.255.255.0"')
adguard_tf = adguard_tf.replace('range_start: "192.168.2.10"', 'range_start: "192.168.1.100"')
adguard_tf = adguard_tf.replace('range_end: "192.168.2.250"', 'range_end: "192.168.1.253"')

print("OpenTofu configurations reverted to /24 successfully.")
```

Everything came back. Total downtime was about 25 minutes.

---

## What Actually Fixed the PS5

The original problem — intermittent `SERVFAIL` on PSN domains — turned out not to be related
to the DHCP range at all. After the revert, I noticed the errors had stopped entirely. Going
back through the AdGuard logs, the SERVFAILs had been happening on queries that hit a specific
upstream in the load-balance pool right around when Cloudflare had a brief DoH hiccup. The
lease-duration change did help clear the stale ARP entry faster, which masked the real cause
(the upstream resolver flapping) by reducing how long devices held onto broken state.

The `edns_buffer_size: 4096` change I'd made in `edit_config.py` was the only edit that stuck
and was actually worth keeping. The `/22` experiment was premature — that kind of subnet
rearchitecture needs to go through the router config, static routes, and VLAN configurations
first, not just AdGuard and the cluster.

---

## Lessons

**Write the revert script before you apply the change.** I had to write `revert_tf_files.py`
under pressure at 1am while services were down. If I'd written it alongside the change scripts,
the recovery would have taken five minutes instead of twenty-five.

**Don't chain changes.** The DHCP fix was valid. The `/22` refactor was a separate project
that I bolted on opportunistically because I already had the config file open. Mixing a targeted
fix with an architectural change made the rollback much harder.

**Midnight is not a good time to rearchitect your network.** This one I already knew.

The cluster is still on `192.168.1.0/24`. The IoT subnet question is on the backlog. The PS5
works fine.
