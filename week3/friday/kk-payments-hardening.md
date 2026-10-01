# kk-payments Hardening Log

Target: `systemd-analyze security kk-payments.service` below **2.5**.
Final achieved: **1.5 OK**. The service handles financial transaction data, so
it is deliberately the most hardened of the three units (kk-api and kk-logs sit
at 3.4, under their 3.5 target).

## Method

`systemd-analyze security` scores 0 (locked down) to 10 (no isolation) by
checking which sandboxing directives are set. I started from the required
baseline (NoNewPrivileges, PrivateTmp, ProtectSystem=strict) and added
directives incrementally, checking the score and unit validity
(`systemd-analyze verify`) after each group. Because no application code is
deployed yet, "does it start" is proxied by `systemd-analyze verify` reporting
the unit valid and the absence of "Unknown key" warnings.

## Iteration log

| Stage | Directives added | Approx. score |
|---|---|---|
| Baseline | NoNewPrivileges, PrivateTmp, ProtectSystem=strict, ProtectHome, ReadWritePaths | ~6.7 (weak) |
| + kernel/proc protections | ProtectKernelTunables, ProtectKernelModules, ProtectKernelLogs, ProtectControlGroups, ProtectClock, ProtectHostname | lower |
| + restrictions | RestrictSUIDSGID, RestrictRealtime, RestrictNamespaces, LockPersonality, RemoveIPC, UMask=0077 | lower |
| + syscall & capability lockdown | SystemCallFilter=@system-service, SystemCallErrorNumber=EPERM, SystemCallArchitectures=native, CapabilityBoundingSet= (empty), AmbientCapabilities= | large drop |
| + payments-only extras | PrivateDevices, ProtectProc=invisible, ProcSubset=pid, RestrictAddressFamilies, KeyringMode=private | **1.5 OK (final)** |

The largest single improvement came from `SystemCallFilter=@system-service`
combined with the empty `CapabilityBoundingSet=`, which together remove the two
biggest exposure categories: arbitrary system calls and retained Linux
capabilities.

## The payments-only directives (why these three make it stricter than api/logs)

kk-api and kk-logs deliberately omit these, which is why they score 3.4 and
payments scores 1.5:

- **`ProtectProc=invisible` + `ProcSubset=pid`** — the service can see only its
  own processes in `/proc`, and only process information, not system-wide
  kernel tunables. This limits reconnaissance if the payments process is ever
  compromised.
- **`CapabilityBoundingSet=` (empty)** — the process can hold no Linux
  capabilities at all. A Node HTTP service binding a high port (3001) needs
  none, so this is safe and removes an entire escalation surface.
- **`KeyringMode=private`** — the service gets its own kernel keyring, isolating
  any secrets it holds from other services.

## Directives investigated but NOT applied (with reasons)

- **`MemoryDenyWriteExecute=true`** — rejected. Node's V8 engine JIT-compiles
  JavaScript, which requires memory that is both writable and executable.
  Enabling this would crash the runtime on startup. A payments service that
  scores lower but does not run is worthless, so this was set to `false`
  explicitly. This is the clearest case where judgment beats the number.
- **`RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6` narrowed to only AF_INET6**
  — rejected. The service must serve HTTP over IPv4 and may use a local unix
  socket to reach nginx. Removing AF_INET or AF_UNIX would break connectivity.
  The families are restricted to exactly what is needed, not removed.
- **`IPAddressDeny=any` with a narrow allow-list** — investigated, not applied.
  It would further lower the score but requires knowing the exact peer
  addresses the payments service talks to (database, payment gateway), which are
  not finalised. Applying it now with wrong addresses would silently break the
  service in production. Deferred until the network topology is fixed.

## Final unit file

The complete `kk-payments.service` is written inline in Phase 4 of
`kijanikiosk-provision.sh`. Key properties: runs as kk-payments, depends on
kk-api (`After=` + `Wants=`), reads `/opt/kijanikiosk/config/payments-api.env`
(readable by the account, confirmed before testing), and carries the full
directive set above.

## Evidence

Screenshot: `systemd-analyze security kk-payments.service` showing **1.5 OK**,
alongside kk-api and kk-logs at 3.4, in the submission screenshots folder.
