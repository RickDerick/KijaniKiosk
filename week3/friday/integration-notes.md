# Integration Challenge Resolutions

Each challenge below states the conflict, the options considered, the choice
made, and why.

## Challenge A: ProtectSystem=strict and the EnvironmentFile

**Conflict.** `ProtectSystem=strict` makes `/etc`, `/usr` and `/boot` read-only
for the service. If the units' `EnvironmentFile` lived under `/etc`, the service
could fail to read its own config, or the read-only mount could interact badly
with it.

**Options considered.** (1) Move config to a writable path and add a
ReadWritePaths exception. (2) Add `/etc/kijanikiosk` to ReadWritePaths. (3)
Confirm where config actually lives and leave it if already safe.

**What I chose and why.** The pre-provisioning audit showed config lives at
`/opt/kijanikiosk/config/` (db.env, payments-api.env), with nothing under
`/etc/kijanikiosk`. `ProtectSystem=strict` leaves `/opt` readable — it only
locks `/etc`, `/usr`, `/boot`. And the EnvironmentFile is only *read* at start,
never written. So no move and no exception are needed; the configuration was
already compatible. I verified readability per account before testing:
`sudo -u kk-payments cat .../payments-api.env` succeeded. Documenting *why it is
already safe* is the resolution, rather than adding an unnecessary exception.

## Challenge B: the monitoring user and ACL defaults

**Conflict.** Phase 8 writes `health/last-provision.json` while running as root,
so the file would be root-owned and unreadable to monitoring and to Amina
without sudo. The `health/` directory was not in Tuesday's model.

**Options considered.** (1) root:root 644 — readable but world-readable, leaks
to every user. (2) Per-reader ACLs like shared/logs. (3) A single group all
readers already share.

**What I chose and why.** Owner `kk-logs:kijanikiosk`, dir 750, file 640. The
kk-logs account is the natural writer of health/monitoring data, and every
legitimate reader (monitoring, Amina, the services) is already in the
`kijanikiosk` group, so group-read at 640 covers them all while `other` gets
nothing. Because all readers need the *same* access level, a single group is
sufficient and ACLs would be over-engineering. This is the inverse of
shared/logs, where readers needed *different* levels and ACLs were required.
The directory is added to `access-model-final.md`.

## Challenge C: logrotate postrotate and PrivateTmp / reload support

**Conflict.** logrotate should signal kk-logs to re-open its log handles after
rotation. The standard `systemctl reload kk-logs` fails if the unit has no
`ExecReload=`. The audit confirmed the original kk-api unit had **no
ExecReload**, so a naive reload would fail.

**Options considered.** (1) Use `copytruncate` in logrotate and signal nothing.
(2) Add `ExecReload=/bin/kill -HUP $MAINPID` to the unit so reload works. (3)
Use `systemctl kill -s HUP` from postrotate.

**What I chose and why.** Two-part: I gave kk-logs an explicit
`ExecReload=/bin/kill -HUP $MAINPID` so it *does* support reload, and I used
`copytruncate` in the logrotate config as the actual rotation mechanism.
`copytruncate` copies then truncates the live file in place, so the service does
not even need to re-open handles — it keeps writing to the same inode. This
sidesteps the PrivateTmp concern entirely (no cross-namespace signal is
required) and is robust whether or not the app implements reload. The
ExecReload is there for correctness and future use; copytruncate is what makes
rotation safe today. Verified: forced rotation produced a new file and
`kk-api can write after logrotate` PASSED.

## Challenge D: the dirty VM and package holds

**Conflict.** On the dirty VM packages are already installed and held. An
install command could attempt a downgrade if a version drifted, and an injected
hold on curl polluted the managed set.

**Options considered.** (1) Blindly reinstall the pinned version (risks silent
downgrade). (2) Check installed vs pinned; skip if equal, fail loudly if
different. (3) Auto-downgrade on mismatch.

**What I chose and why.** Phase 1 compares the installed nginx version against
the pin. If they match (they do: 1.30.4-5), it skips the install and just
re-asserts the hold. If they differ, it **fails loudly** and asks for manual
review rather than silently downgrading — an unexpected version change on a
production node is a decision a human should make, not something a script should
paper over. Separately, the phase detects any hold it does not own (the injected
curl hold) and removes it, logging `curl hold removed`, so the managed hold set
stays exactly {nginx, nodejs}. I chose fail-loud over auto-downgrade because
silent downgrades hide drift, and hidden drift is how production surprises
happen.
