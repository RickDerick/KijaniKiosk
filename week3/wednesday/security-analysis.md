# systemd Security Analysis — kk-api.service

## `systemd-analyze security` result

Command:

```bash
systemd-analyze security kk-api.service
```

Final verdict:

```
→ Overall exposure level for kk-api.service: 8.3 EXPOSED
```

The full per-directive table is saved alongside this file in
`systemd-security-full.txt`.

## Reading the score honestly

`systemd-analyze security` rates a unit from 0 (fully locked down) to 10 (no
isolation) by checking a long list of sandboxing directives — several dozen of
them — and adding an exposure weight for each one that is not set. The score is
therefore measured against *every* protection systemd offers, not against a
reasonable baseline.

An 8.3 "EXPOSED" result does **not** mean the service is misconfigured or
dangerous. It means most of the many available directives are unset. This unit
deliberately sets a focused set of protections rather than every option, so a
high score is expected. The checkmarks in the table confirm the protections
that *are* in place are recognised and working:

- `NoNewPrivileges=` ✓ — no privilege escalation via SUID
- `User=` ✓ — runs as the static non-root `kk-api` account (not root, not DynamicUser)
- `AmbientCapabilities=` ✓ — no ambient capabilities granted

On top of those, `PrivateTmp`, `ProtectSystem=strict`, `ProtectHome` and
`ReadWritePaths` are set (they appear in the table too). Together these remove
the largest real-world exposure categories: escalation, root identity, a
writable filesystem, a shared `/tmp`, and read access to home directories.

## The three required directives

- **`NoNewPrivileges=true`** stops the process and its children from gaining new
  privileges, e.g. through a SUID binary. Escalation via a SUID file in the tree
  is impossible.
- **`PrivateTmp=true`** gives the service a private `/tmp` and `/var/tmp`, so it
  cannot see or tamper with other processes' temporary files.
- **`ProtectSystem=strict`** mounts the whole filesystem read-only for the
  service except `/dev`, `/proc`, `/sys`. The service cannot modify any system
  file.

## The two additional directives I added

### 1. `ReadWritePaths=/opt/kijanikiosk/shared/logs`

**Why it was necessary.** `ProtectSystem=strict` makes *everything* read-only,
including the app's own log directory, so the service would fail the moment it
tried to write a log. `ReadWritePaths` opens exactly one path back up for
writing and nothing else.

**What it buys.** It keeps the strict read-only posture everywhere except the
single directory the service legitimately needs. The writable surface shrinks
from "the whole system" to one logs directory — least privilege applied to the
filesystem. It also mirrors Tuesday's access model, where `shared/logs` was the
one place the API account had write access. The systemd directive and the ACL
now enforce the same boundary at two layers (process sandbox and file
permissions): defence in depth.

### 2. `ProtectHome=true`

**Why I added it.** The API service has no reason to touch `/home` or `/root`.
`ProtectHome=true` makes those directories appear empty and inaccessible to the
service. If the process were compromised, it could not read users' home
directories, SSH keys, or shell history.

**What it buys.** It closes an information-disclosure path the required three do
not cover. `ProtectSystem=strict` makes the system read-only but still lets a
process *read* `/home`; `ProtectHome=true` removes even read access. For a
service whose account has no home of its own (`/nonexistent`), the functional
cost is zero and the security gain is real.

## Why the score is not lower (and why that is acceptable here)

The remaining exposure comes from directives this unit does not set. Some could
be added safely; others would break a Node.js runtime and were deliberately left
out:

- **`RestrictAddressFamilies=`** — the API must serve HTTP, so it needs
  `AF_INET`/`AF_INET6` sockets. It can be *restricted* to those families but not
  fully removed, so it only ever earns partial credit.
- **`MemoryDenyWriteExecute=`** — Node's V8 engine JIT-compiles JavaScript,
  which requires writable-then-executable memory. Enabling this would likely
  crash the runtime, so it cannot be set for a Node service.
- **`SystemCallFilter=`** — would meaningfully lower the score, but needs careful
  testing against the exact syscalls the Node runtime uses; too aggressive a
  filter silently kills the process. Appropriate as a follow-up with proper
  testing, not a blind addition.
- **`RestrictNamespaces=`, `LockPersonality=`, `ProtectKernelModules=`,
  `ProtectControlGroups=`** — several of these are safe, low-risk additions that
  would each shave a little exposure. They are reasonable next steps if the goal
  were to minimise the score.

**Conclusion.** 8.3 reflects a unit that sets a focused, correct set of
protections rather than exhausting systemd's full catalogue. The required trio
plus the two additions remove the highest-impact exposures and encode the same
least-privilege principle as the account and ACL design from Tuesday. Driving
the number lower is possible with the safe directives listed above, but several
of the biggest remaining items (`MemoryDenyWriteExecute`, full
`RestrictAddressFamilies`) are constrained by the Node runtime itself, so a
mid-to-high score is inherent to hardening a Node service this way.
