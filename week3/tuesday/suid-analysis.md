# Task 3 — SUID Remediation: Deep Understanding

> The three questions below are the standard "deep understanding" set for this
> task. Confirm they match the exact wording on your lab page before submitting.

## Q1. Why does Linux ignore the SUID bit on a shell script?

SUID tells the kernel to run a program with the file owner's privileges instead of the caller's. On Linux, this only applies to **binary executables the kernel loads directly**. A shell script is not run directly by the kernel; when you execute `deploy.sh`, the kernel sees the `#!/bin/bash` line, then actually runs the interpreter `/bin/bash` with the script passed as an argument. The privileged file is the script, but the program the kernel elevates would be the interpreter, and `/bin/bash` is a normal, non-SUID binary.

Linux deliberately drops the SUID bit in this interpreter step because SUID scripts are notoriously unsafe. There is an unavoidable race between the kernel checking the script's permissions and the interpreter opening it, during which an attacker can swap the file (a time-of-check-to-time-of-use bug). Interpreters also expose environment variables and options (`PS1`, `PATH`, `ENV`, `BASH_ENV`) that an attacker could use to redirect what the "privileged" script actually executes. To avoid this whole class of exploit, the kernel does not honour SUID on scripts at all.

So `chmod 4777 deploy.sh` does **not** make the script run as root. The `s` bit is present and visible, but functionally inert on this file.

## Q2. If the SUID bit is inert on a script, why was this still a serious vulnerability?

Because the real danger was the **world-writable** bit, not the SUID bit. `4777` gives write permission to every user on the system (`-rwsrwxrwx`), and a deploy script is exactly the kind of file that a privileged actor runs. Deploy scripts are typically executed by root, by a CI/CD runner, or through a scheduled job with elevated rights.

That combination creates a privilege-escalation path even though SUID is ignored:

1. Any unprivileged user opens `deploy.sh` and appends a malicious line, for example `cp /bin/bash /tmp/rootbash && chmod u+s /tmp/rootbash`.
2. They wait. The next time root (or the deploy pipeline) runs the script, that injected line executes **with root's privileges**.
3. The attacker now has a SUID root shell they planted, and full control of the host.

The attacker never needed the SUID bit on the script to work. They borrowed the privileges of whoever legitimately runs it. The SUID bit is still a real problem for a different reason: it signals that the file was *intended* to carry root privileges, and it is precisely what a security scanner flags, so leaving it there both misleads reviewers and trips audits. That is why the task required removing both: `chmod u-s` for the bit, and removing world-write to close the injection path.

## Q3. Why did fixing the file's permissions require fixing the directory too?

Setting `deploy.sh` to `750 root:root` protects the file's **contents** but not its **name**. In Unix, the power to create, rename or delete a file inside a directory is controlled by the write and execute permission on the **directory**, not by the permissions on the file itself.

The setup script left `/opt/kijanikiosk/scripts/` at `777`, world-writable. While that is true, any user can:

- delete `deploy.sh` outright and drop in a replacement file with the same name, whatever mode the original had, or
- rename the hardened script aside and create a fresh malicious `deploy.sh`.

The file's own `750` mode is irrelevant to both, because the user is not editing the file, they are editing the directory that holds it. So the pipeline that runs `/opt/kijanikiosk/scripts/deploy.sh` would happily execute the attacker's substitute.

Locking the file without locking the directory is a false fix. Setting the directory to `750 root:root` as well removes write access from ordinary users, so the hardened `deploy.sh` cannot be swapped out. The lesson is that file hardening and directory hardening are two separate controls, and a script is only as safe as the directory it lives in.
