# Engineering Decision: `/usr/sbin/nologin` vs `/bin/false`

**Decision:** The KijaniKiosk service accounts (`kk-api`, `kk-payments`, `kk-logs`) use `/usr/sbin/nologin` as their login shell.

## How the login shell field works

The last field of each entry in `/etc/passwd` is the program that runs once a user has authenticated through `login`, `su -`, or `sshd`. Normally this is an interactive shell like `/bin/bash`. Setting it to a program that exits immediately means that even a successful authentication ends the session straight away, because there is no shell left to interact with.

Both options work this way. The difference is in what happens when they run.

## What each option does

**`/bin/false`** is a program that does nothing except exit with status 1. It prints no message and writes nothing to the logs. The session ends silently, so an administrator trying to log in cannot tell whether the connection failed, the password was wrong, or the account is blocked by design.

**`/usr/sbin/nologin`** was written specifically for accounts that must not log in. It also exits with a non-zero status (1), but first it prints a message explaining why: "This account is currently not available." The message can be customised through `/etc/nologin.txt`. Depending on the implementation installed (check with `dpkg -S /usr/sbin/nologin`), it can also record the attempt in the authentication log, which leaves a trace for security review.

Both block interactive access equally well. The choice comes down to clarity, auditability, and convention.

## Why `/usr/sbin/nologin`

1. **It states the intent.** Anyone reading `/etc/passwd` or an audit report sees at once that these accounts are meant to be non-interactive. `/bin/false` is a general-purpose utility, so a reviewer has to infer the purpose.
2. **It gives clear feedback.** An engineer who runs `su - kk-api` during troubleshooting gets an explicit message instead of a session that closes without explanation. This saves time and avoids misdiagnosing the problem as a password or PAM failure.
3. **It can support auditing.** Where the installed implementation logs attempts, a login against a service account appears in the auth log. A service account should never be the target of a login attempt, so any such entry is a useful signal.
4. **It is the platform convention.** Debian and Ubuntu use `/usr/sbin/nologin` for their own system accounts (such as `www-data`, `nobody`, and `systemd-network`), and `adduser --system` defaults to it. Following the convention keeps the server consistent and predictable for the next engineer.

The usual argument for `/bin/false` is that silence reveals less to an attacker. It doesn't hold up here. Reaching the shell stage at all requires a successful authentication, and these accounts have locked passwords and no SSH keys. The message only confirms what `/etc/passwd` already shows to any local user.

## Limits of this control

The login shell only controls what runs for an **interactive or command session**. It is not a complete access control on its own, and neither option changes that:

- **Root can bypass it.** `sudo -u kk-api <command>` and `su -s /bin/bash kk-api` run commands as the account without using its login shell. This is expected. systemd relies on the same mechanism, starting service processes directly under `User=kk-api` without a shell.
- **Some SSH features don't use the shell.** If the account could authenticate, a connection with no command (`ssh -N`) could still open port forwards, because no shell is ever started.

That is why the shell is one layer among several. These accounts also have **no password** (locked in `/etc/shadow`), **no home directory** (`/nonexistent`, so there is no place for an `~/.ssh/authorized_keys` file), and **UIDs in the system range**. Together these make interactive authentication impossible, and `nologin` makes the intent explicit and gives a clear, observable result if anyone tries.

## Verification

```bash
getent passwd kk-api kk-payments kk-logs   # shell field shows /usr/sbin/nologin
sudo passwd -S kk-api                      # "L" = password locked
sudo su - kk-api                           # "This account is currently not available."
echo $?                                    # 1 (non-zero exit)
```

## nologin vs false vs locked: they are not the same control

The submission asks about three things that are easy to conflate. They operate at different points, and the service accounts use two of them together rather than choosing one.

- **`/usr/sbin/nologin` and `/bin/false` are login *shells*.** They decide what runs *after* a successful authentication. Both end the session immediately; the difference is the explanatory message and auditing, as argued above. This is the choice the task is really about, and the answer is `nologin`.
- **A locked password is an *authentication* control.** `passwd -l` (or the `!` a system account gets by default) puts an invalid hash in `/etc/shadow`, so no password can ever match. This stops authentication from succeeding in the first place, before the shell is ever reached.

They are complementary, not alternatives. The locked password means an attacker cannot authenticate as the account by password at all. The `nologin` shell is the backstop: if authentication ever did succeed by some other means (a mistakenly added SSH key, a misconfiguration), the session would still end at once with a clear message. Defence in depth means using both, which is why every service account here has **a locked password *and* a `nologin` shell *and* no home directory** for an `authorized_keys` file to live in.

`/bin/false` would satisfy the shell requirement equally in terms of blocking access, but it loses the clarity, feedback and auditability described above, so `nologin` is the better of the two shell options. The decision, per account, is identical: locked password + `/usr/sbin/nologin`, because all three are non-interactive service identities with the same requirements.
