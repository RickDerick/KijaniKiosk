# Week 3 Tuesday — Reflection

## Question 1: The SUID Paradox

The colleague is right about one fact and wrong about the conclusion. Yes, modern Linux kernels ignore the SUID bit on shell scripts, so `chmod 4777 deploy.sh` does not make the script itself run as root. But the finding is not about the SUID bit doing its job. It is about the world-write bit, and that bit works perfectly.

**Why the kernel ignores SUID on scripts.** When you execute a binary, the kernel loads it directly and can apply the file owner's privileges cleanly. A script is different: the kernel reads the `#!/bin/bash` line and actually runs the *interpreter* (`/bin/bash`) with the script as an argument. That indirection opens two holes that make SUID scripts unsafe. First, there is a race between the kernel checking the script's permissions and the interpreter opening the file by name — an attacker can swap the file in that window (a time-of-check-to-time-of-use bug), so the privileges get applied to a different file than the one that was checked. Second, interpreters honour environment variables and startup files (`PATH`, `BASH_ENV`, `ENV`, `IFS`) that an attacker controls, so even the "right" script can be redirected to run attacker code. Rather than try to plug every one of these, the kernel refuses to honour SUID on scripts at all. This is a deliberate, defensive design decision.

**Why SUID + world-write is dangerous anyway.** The vulnerability does not depend on the SUID bit being functional. It depends on *who runs the script* and *who can edit it*. A deploy script is, by definition, run by a privileged actor: root, a CI/CD runner, or a scheduled job with elevated rights. World-write (`777`) means any unprivileged user on the box can modify its contents. So the attack is:

1. An unprivileged user appends a line to `deploy.sh`, e.g. `cp /bin/bash /tmp/rootbash && chmod u+s /tmp/rootbash`.
2. They wait. The next scheduled or manual deployment runs the script *as root*.
3. That injected line now executes with root's privileges, planting a SUID-root shell the attacker can use whenever they like.

The attacker never needed the script's own SUID bit. They borrowed the privileges of whoever legitimately runs the file. This is a real, exploitable privilege-escalation path, and it exists purely because of world-write on a file that a privileged process executes.

**So why still remove the SUID bit?** For two reasons beyond raw exploitability. It signals *intent* — someone deliberately tried to give this file root privileges, which is exactly the kind of thing a security review needs to understand and undo. And it is what automated scanners and auditors flag; leaving an inert-but-alarming bit in place wastes reviewer time and can fail compliance checks. Removing `u-s` and removing world-write are two separate fixes for two separate problems, and Amina was correct to require both. "It has no effect" confuses the mechanism with the risk. The bit is inert; the misconfiguration is not.

---

## Question 2: Sudoers Policy Completeness

The proposed policy looks tidier, but the wildcard changes what it grants in a way that is far broader — and more dangerous — than it appears.

```
amina ALL=(root) NOPASSWD: /bin/systemctl restart *
amina ALL=(root) NOPASSWD: /bin/systemctl status *
```

**What it actually grants.** In sudoers, `*` matches any string, including spaces and additional arguments. So `restart *` does not mean "restart any KijaniKiosk service." It means "run `systemctl restart` followed by anything at all," as root, with no password. The wildcard also does nothing to stop extra flags or extra units being appended. Combined with `NOPASSWD`, it removes the one friction point (re-authentication) that might slow an attacker or a careless command. The rule is effectively "restart or status *any unit on the system* as root, silently." Compared to my restricted policy, which pins each rule to one of exactly three named units, this hands Amina control over every service on the host.

**Abuse scenario 1 — denial of service against a critical service.** The wildcard puts no limit on *which* unit is targeted:

```bash
sudo systemctl restart ssh.service
sudo systemctl restart nginx.service
sudo systemctl restart auditd.service
```

Amina (or anyone who compromises her account) can restart `sshd`, the web server, the firewall, or the audit daemon. Restarting `ssh` can drop active admin sessions; repeatedly restarting a critical service is a simple, low-effort denial of service. A restart of `auditd` around the time of other activity can create gaps in the audit trail. My restricted policy denies all of these because `ssh.service`, `nginx.service` and `auditd.service` are not in the allowed list — only the three KijaniKiosk units are.

**Abuse scenario 2 — argument injection to reach a different subcommand or option.** Because `*` swallows anything after the matched text, the command line is not really constrained to a bare restart. For example:

```bash
sudo systemctl status --no-pager=false nginx    # forces the pager back on
```

With the pager active and the command running as root, `less` accepts `!bash`, which spawns a **root shell** — a full escalation from a "read-only" status command. More generally, a permissive wildcard rule is exactly the pattern that lets a user smuggle in extra options the policy author never intended. My restricted policy pins the *exact* argument string, including `--no-pager` on every status and journal rule, so there is no room to append a pager-enabling option or any other flag. The command must match one of the listed forms character-for-character or it is denied.

**The underlying lesson.** A wildcard in a sudoers command is almost always a mistake, because it pins the binary but not the arguments, and for a tool like `systemctl` the arguments *are* the security boundary. Listing services individually is more verbose, but the verbosity is the control. `NOPASSWD` compounds the problem by removing the audit-friendly re-authentication step. The restricted policy trades a few extra lines for a boundary that actually holds.

---

## Question 3: nologin vs Locked Account

### Part A — operational difference

The two controls act at *different stages* of getting into an account, and they are not interchangeable.

- **`passwd -l kk-api`** locks the **password**. It prepends a `!` to the hash in `/etc/shadow`, so no password can ever match. This blocks *password authentication* — the stage where the system decides whether you are allowed in at all.
- **`/usr/sbin/nologin` as the shell** controls what runs **after** a successful authentication. Even if some method authenticates the account, the session ends immediately with "This account is currently not available."

**The scenario where they differ** is any authentication path that does not use a password:

- With a **non-locked** account and a `nologin` shell, if someone adds an SSH *public key* to the account (or the account has one), an SSH login *authenticates successfully* — the key satisfies auth without a password — and then the `nologin` shell ends the interactive session. But the authentication itself succeeded, which means non-shell SSH features still work: `ssh -N` port forwarding, or `ssh kk-api@host <command>` where the forced command path is available. The `nologin` shell blocks the *interactive shell*, not the *authenticated connection*.
- With a **locked** account and a `nologin` shell, the password path is also closed, so a stray password can never work. (Note that `passwd -l` alone does **not** stop key-based SSH — that is governed by the key files and sshd config — which is why locking is not a complete answer on its own either.)

**When to use each in production.** Use **`nologin` shell** on every non-interactive service account, always — it declares intent, gives a clear message, and blocks interactive shells. Add a **locked password** on top for defence in depth, so no password can ever authenticate the account. The two are complementary, not either/or. Use **`passwd -l` on a normal human account** when you want to *temporarily suspend* a real user (someone on leave, an offboarding in progress) without deleting them, while leaving their shell intact so they can be re-enabled with `passwd -u`. The key distinction: `nologin` says "this identity is not a person and should never get a shell"; `passwd -l` says "block this password," which suits both hardening a service account and pausing a human one.

### Part B — the outage

Locking `kk-api` with `passwd -l` on a server whose deploy pipeline runs `sudo -u kk-api /opt/kijanikiosk/api/start.sh` is a subtle trap, and here is exactly how it plays out.

**Does it break?** It depends on the PAM configuration, which is what makes this a nasty bug. `sudo -u kk-api` does not check a password for the *target* user — it switches to that user's identity. On most default setups, this still works with a locked password, because `sudo` is authorised by *Amina's* (or root's) credentials and the switch itself does not consult `kk-api`'s password. **But** many hardened production images enable `pam_unix`'s account checks (or `pam_securetty`/`pam_access` rules) that reject a login for an account whose password is locked or expired. Under that configuration, PAM's *account* phase returns failure for the locked user, and `sudo -u kk-api ...` is refused. So on a hardened host, locking `kk-api` breaks the deployment.

**What the failure looks like at runtime.** The deploy pipeline step that runs `sudo -u kk-api ...` exits non-zero. The application never starts. To users, the API is simply down — connection refused or 502 from the proxy — starting immediately after the deploy that locked the account, even though "nothing in the app changed."

**How it appears in logs.** Not as an application error, which is what makes it confusing. It shows up in the *auth* layer:

```
sudo: PAM account management error: Authentication failure
pam_unix(sudo:account): account kk-api has expired (failure)
```

in `/var/log/auth.log` (or `journalctl _COMM=sudo`), and a generic non-zero exit in the CI/CD job log with no application stack trace. The app log is empty because the app never ran.

**What a junior engineer misdiagnoses it as.** The symptom — "API down right after a deploy, connection refused" — screams *application* problem, so the first guesses are usually: a bad code deploy, a failed database connection, a crash on startup, a bad config value, or a port already in use. They will likely restart the service a few times, re-check the app config, and inspect the app logs (which are empty, deepening the confusion). Because the real cause is in `auth.log` and not the app log, and because `sudo -u` "usually just works," the account lock is one of the last things checked. The real fix is `passwd -u kk-api` (unlock) — or better, never lock a service account that a pipeline runs as, and rely on the `nologin` shell plus no SSH keys for hardening instead. This is precisely why the login-shell vs password-lock distinction matters operationally: they defend different doors, and locking the wrong one silently breaks the automation that depends on `sudo -u`.

---

## Question 4: ACLs vs Group Redesign

Both approaches make the shared log directory reachable by `kk-api` (write), `kk-payments` (read) and `amina` (read). They differ in *how precisely* they express access, and that difference shows up across three dimensions.

**Security isolation.** ACLs win here. The requirement has three *different* access levels: kk-api writes, the other two only read. A single shared group cannot express that — group membership is one permission set, so a `kk-shared-logs` group set to group-writeable grants **write to everyone in it**, including kk-payments and amina, who should only read. To claw the write back you would need extra tricks (making the read-only members not group members and using "other," which then leaks to the whole world, or further ACLs anyway). ACLs let each identity carry its own permission (`kk-api:rwx`, `kk-payments:r-x`, `amina:r-x`) with no over-granting. The group approach forces you to flatten three access levels into one, which breaks least privilege.

**Auditability.** This one cuts both ways depending on the audience. The group approach is easier to see at a glance with everyday tools: `getent group kk-shared-logs` and `ls -l` tell most of the story, and many reviewers are more fluent in "who is in this group" than in reading ACL masks. ACLs are invisible to a plain `ls -l` (they show only a `+`), so an auditor has to know to run `getfacl`, and the interaction between the ACL `mask` and the effective permissions can be genuinely confusing. So: group membership is more *discoverable*; ACLs are more *precise*. If your audit process reliably uses `getfacl`, ACLs give a truer picture of real access; if it relies on group listings, ACLs can hide access from a casual reviewer.

**Operational complexity.** The group approach is simpler to *operate* at scale: adding a fourth reader is `usermod -aG kk-shared-logs newuser`, a command every engineer knows, and it composes well with configuration management. ACLs require `setfacl` per identity, need matching *default* ACLs so new files inherit correctly (a step that is easy to forget and a common source of "why can't they read the new files" bugs), and are more fragile — a later `chmod` can silently alter the ACL mask and quietly reduce access. Against that, the group approach carries its own operational cost: it needs a *new group per distinct access pattern*, and on a system with many overlapping sharing requirements you end up with a sprawl of single-purpose groups that itself becomes hard to reason about.

**When to choose each.**

- **Choose ACLs** when the access levels genuinely differ per identity (as here — one writer, two readers), when the sharing pattern is specific to one directory and does not recur, and when you have a small, fixed set of identities. ACLs express "these exact people, these exact rights" without inventing a group or over-granting.
- **Choose a shared group** when everyone who needs access needs the *same* level (all read-write, or all read), when the same set of people needs access to *many* resources (a group is defined once and reused), and when the team's tooling and audit habits are group-centric. Groups scale better and are more discoverable when the access pattern is uniform and recurring.

For this specific task the requirement has mixed access levels on a single directory, so ACLs are the correct choice: they preserve least privilege where a single group would be forced to over-grant write access to the read-only members. If the requirement were "three services all read-write the same logs, and we'll add more services later," I would switch to a shared group.
