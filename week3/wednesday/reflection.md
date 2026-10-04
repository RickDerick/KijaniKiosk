# Week 3 Wednesday — Reflection

## Question 1: The Idempotency Boundary

The patterns from today are idempotent because each one either checks state before acting (`getent` guards) or overwrites to an absolute end state (`cat >`, `chown`, `setfacl`). Three operations resist this because their correct end state depends on more than the presence or content of a resource.

**Changing a running service's config and reloading it.** Writing the config file is idempotent, but the *reload* is an action with side effects on a live process. Re-running should reload only if the file actually changed, otherwise every run needlessly bounces the service. The file's existence doesn't tell you whether a reload is owed. Approach: compare a hash of the rendered config against the running one, and trigger the reload only on a difference (the "notify/handler" pattern).

**Rotating credentials already in use.** A password or key is consumed by other systems. Generating a new one is easy; the hard part is that the old value is still referenced elsewhere, so a naive re-run either rotates every time (breaking consumers) or can't tell if rotation already happened. Approach: make rotation explicit and versioned, gate it on an age or expiry check, and update all consumers atomically before retiring the old secret.

**Rolling back to an older package version.** `apt` installs forward easily but "downgrade to 1.24 when 1.26 is installed" isn't a converge-to-state operation; it may require removing the newer version, dependency conflicts, and the old version still being available. Approach: pin the exact version in apt preferences and let the tool resolve, accepting it may fail and need manual intervention.

## Question 2: Version Pinning vs Security Updates

The concern is legitimate: a hold does block automatic patching, and a CVE against the pinned nginx would sit unaddressed until someone acts. But the alternative — unpinned auto-upgrades — trades a *managed* risk for an *unmanaged* one. An unattended upgrade can pull a version with a breaking change or regression and take the service down with no human in the loop. Pinning exists to make version changes deliberate and tested rather than surprising.

The correct process is not "pin and forget." It is: pin for stability, then run a monitoring loop that watches for CVEs and new releases against the pinned packages, test the candidate upgrade in staging, and promote it through a controlled change. The hold is released, the new version installed and validated, and the hold re-applied at the new version. Patching still happens; it happens on purpose.

The scale changes the *process*, not the principle. Two engineers rely on manual vigilance: subscribe to nginx security advisories, and when one lands, test and bump within an agreed window. That window is necessarily wider, so they may accept slightly slower patching in exchange for not breaking production unattended. A company with a security team automates the detection (CVE scanners feeding a ticket queue), defines SLAs for patch turnaround by severity, and has staging plus rollback infrastructure so a pinned-version bump is routine and fast. Same idea, more machinery.

## Question 3: systemd Hardening Trade-offs

The failure is caused by `ProtectSystem=strict`. That directive remounts the *entire* filesystem hierarchy read-only inside the service's own mount namespace — including `/var`, `/etc`, `/usr` and everything else — leaving only `/dev`, `/proc` and `/sys` accessible, and even those governed by other directives. The service process sees a private view of the filesystem where writes are rejected. So when the app tries to create a PID file in `/var/run/kijanikiosk/` or cache files in `/var/cache/kijanikiosk/`, the write fails with a read-only-filesystem or permission error, even though those paths look normal from a root shell outside the sandbox. Nothing is wrong with the app logic; the namespace simply forbids the write.

The fix is not to weaken `ProtectSystem`. It is to carve out the specific writable paths the service legitimately needs, the same way `ReadWritePaths=/opt/kijanikiosk/shared/logs` already does for logs. For runtime and cache data, systemd provides purpose-built directives that both create the directories and mark them writable: `RuntimeDirectory=kijanikiosk` (creates and manages `/run/kijanikiosk`, the modern `/var/run`) and `CacheDirectory=kijanikiosk` (creates `/var/cache/kijanikiosk`). These are preferable to adding raw `ReadWritePaths` entries because systemd owns the directory lifecycle — creating them with correct ownership on start and cleaning up as configured — while the rest of the filesystem stays strictly read-only. The hardening is preserved; only the exact needed paths become writable.

## Question 4: The Gap Between Shell Scripts and IaC Tools

**State and drift detection.** My script asserts a desired state on each run but has no memory of prior state. If someone manually deletes a directory or changes a mode between runs, the script may or may not notice depending on which guard covers it, and it cannot report "these three things drifted." Terraform keeps a state file and Ansible re-checks every resource, so both detect and correct drift by design. My bash guards only cover the cases I remembered to write.

**Partial failure and rollback.** With `set -e`, a failure midway leaves the server half-provisioned — packages installed, users created, but no firewall — and re-running may or may not recover cleanly depending on where it died. Terraform plans the full change set and can roll back; Ansible reports per-task success/failure across the whole play. My script has no transactional boundary and no automatic rollback.

**Dependency ordering and cross-host coordination.** My phases run in a hand-written linear order; I encode dependencies by remembering to call functions in sequence. IaC tools build a dependency graph and can parallelise safely, and Terraform can coordinate across many hosts and cloud resources at once. Bash handles one machine, one sequence.

This tells me shell provisioning is appropriate for small, single-host, well-understood setups — bootstrapping, labs, a one-off box — where the simplicity is worth more than state tracking. Once you have multiple hosts, need drift detection, or require safe rollback and team collaboration, a real IaC tool earns its complexity.
