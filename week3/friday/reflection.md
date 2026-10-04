# Week 3 Friday — Reflection

## 1. When did two requirements conflict, and what did resolving it teach me?

The clearest conflict surfaced between the hardening requirement and the units
actually loading. I first wrote `StartLimitIntervalSec` and `StartLimitBurst` in
the `[Service]` section of each unit, alongside the restart policy where they
felt like they belonged. systemd silently ignored them ("Unknown key ... in
section [Service]") because those two keys must live in `[Unit]`, not
`[Service]`. On its own that was minor, but it exposed a deeper conflict: kk-api
and kk-logs were scoring 6.7 — the score of an almost-unhardened unit — even
though the hardening directives were present in the file. The requirement to
harden and the requirement for a valid, loadable unit were in tension: a unit
with a single misplaced or unknown key still loads, but any real parse problem
makes systemd fall back to weak defaults, and the score reflects that. What I
learned is that in systemd, "the directive is in the file" and "the directive is
in effect" are two different facts, and only `systemd-analyze verify` plus the
security score confirm the second. I stopped trusting the file contents and
started trusting the analyzer's read of them. That habit — verify the effect,
not the intent — is the same lesson as idempotency: assert the outcome, then
prove it.

## 2. Rewrite one sentence from the Nia document in technical language for Tendo.

**Nia version:** "The payments function is locked down more tightly than the
others: it can see only its own activity, holds no special system powers, and
keeps its secrets in an isolated store."

**Tendo version:** "kk-payments.service sets `ProtectProc=invisible` with
`ProcSubset=pid` so the process sees only its own PID subtree in /proc, an empty
`CapabilityBoundingSet=` so it retains no Linux capabilities, and
`KeyringMode=private` so it gets an isolated kernel keyring — together bringing
its `systemd-analyze security` score to 1.5 versus 3.4 for kk-api and kk-logs."

**What is gained:** precision and reproducibility. Tendo can read the exact
directives, verify the score himself, and check each one against the unit file.
There is no ambiguity about *how* the lockdown is achieved. **What is lost:**
accessibility and the "so what." The Nia version connects the control to a
business consequence (money-handling code is the highest risk, so it gets the
most confinement) in language a board can repeat. The technical version assumes
the reader knows what a capability or a keyring is and why an attacker would
care. Each version is correct for its audience; using the wrong one for the
wrong reader either loses the board or frustrates the engineer.

## 3. The single most fragile part, and what I would need to make it robust.

The most fragile part is Phase 1's dependency on the network to fetch the
NodeSource signing key and refresh the package index. During development the
script hung for minutes when the VM briefly lost connectivity, because `curl`
had no timeout and simply waited. I added `--connect-timeout` and `--max-time`
so it now fails fast, and made the phase continue when the pinned packages are
already installed and held — but the fragility is structural, not just a missing
flag. The script assumes a reachable NodeSource endpoint, working DNS, a
valid TLS chain, and a package index it can update. A production node behind a
strict proxy, in an air-gapped environment, or during a NodeSource outage would
still hit trouble even with timeouts: it would proceed only because the packages
happened to be present already. To make this genuinely robust I would need to
know the target environment's network model: is there an internal package mirror
and key server we should point at instead of the public internet? Is egress
proxied or blocked? Are the pinned `.deb` files and the signing key pre-staged on
the image so provisioning never reaches out at all? The most reliable answer for
a payments node is usually the last one — bake the exact package versions and
key into a base image and have the script install from local files — so that
provisioning has no runtime dependency on any external service it does not
control. Fragility here is really a hidden external dependency, and the fix is to
remove the dependency, not just time it out.
