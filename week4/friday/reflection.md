# Week 4 Friday – Reflection

Path used: **Multipass (primary path)**, with a community MinIO build as the remote state backend.

---

## 1. When did two requirements conflict?

**Challenge D: hardening versus configuration.** `ProtectSystem=strict` (Requirement 5) makes almost the whole filesystem read-only for `kk-payments`, while Requirement 2 has Ansible deploying the service's environment file. If that file had landed under `/etc`, the hardening could have stopped the service reading its own configuration. My Week 3 design already kept configuration under `/opt/kijanikiosk/config`, so I preserved that in the `service.env.j2` template: owned `root:kijanikiosk`, mode `0640`, readable by the service through group membership. Instead of testing it once by hand, I made the playbook prove it on every run: a verification task runs `test -r` as the `kk-payments` user.

**The conflict I actually hit was a close relative of D.** The first pipeline log contained `[Errno 13] Permission denied: '/nonexistent'`. It came from that same verification task. To act as `kk-payments`, Ansible tries to create a temporary directory in the user's home. My Week 3 hardening deliberately gave every service account no home (`/nonexistent`) and no login shell. The two requirements collided: the security baseline removed something the automation tool silently assumed would exist. The task still passed because Ansible fell back to another location, which is exactly why it was easy to miss. I resolved it by giving that one task `ansible_remote_tmp: /tmp`, rather than weakening the account by giving it a home directory.

**A third conflict came from splitting one server into three.** In Week 3, `kk-payments` declared `After=kk-api.service` and `Wants=kk-api.service`, because both ran on one machine. With `kk-api` on a different server, systemd cannot express that dependency. I replaced it with `network-online.target` and documented why in `group_vars`.

**What I learned:** hardening and automation are both written by people who assume the other side will cooperate. Each conflict only appeared when the two were run together, which is why the brief insists on composing the requirements rather than meeting each in isolation. I also learned to read "passing" logs, not just failing ones: the most important problem I found had `ok` next to it.

---

## 2. One sentence rewritten for Tendo

**For Nia (from hardening-decisions.md):**

> Before configuring anything, the pipeline obtains each server's identity fingerprint through a separate trusted channel and refuses to connect if the server presents a different one, so an impostor machine cannot receive our configuration.

**For Tendo:**

> Before Ansible runs, `pipeline.sh` reads each VM's `/etc/ssh/ssh_host_ed25519_key.pub` via `multipass exec` and writes it to `ansible/.known_hosts`; `ansible.cfg` sets `UserKnownHostsFile=.known_hosts` and `StrictHostKeyChecking=yes`, so a recreated VM's new host key is verified out-of-band instead of being trust-on-first-use accepted, and any mismatch fails the SSH handshake.

**What is gained:** precision and verifiability. Tendo can check every claim: which key type, which file, which SSH options, and exactly what failure looks like. He can also spot the limitation immediately: the "trusted channel" is only trustworthy because Multipass runs on the same laptop, and the cloud path in `pipeline.sh` falls back to `ssh-keyscan`, which is trust-on-first-use.

**What is lost:** the reason it matters. "An impostor machine cannot receive our configuration" is the business consequence, and it disappears behind mechanism in the technical version. The plain version is also more honest in one way: it states the *intent*, which survives if the mechanism changes. The cost is that "a separate trusted channel" asks Nia to take its trustworthiness on faith. The two versions are not a better and a worse sentence; each is incomplete without the other, which is why the document has a reader and the code has a reviewer.

---

## 3. The single most fragile handoff

**The IP address handoff, from Terraform output into Ansible's firewall rules.**

Terraform reads each VM's IP from Multipass. `pipeline.sh` writes those IPs into `inventory.ini`. Ansible then does more than *connect* to those addresses: it **bakes peer addresses into firewall rules**. The payments server accepts port 3001 only from the API server's current IP, and the logs server accepts port 3002 only from the API and payments IPs.

In my test setup this works because the pipeline always converges all three servers together. In a production environment that differs slightly, it breaks quietly:

- **If only one server is recreated** (say the API server after a failure), it gets a new address from DHCP. The next run *adds* a rule for the new IP on payments and logs, but nothing *removes* the old one. The old address stays allowed and could later belong to a different machine. My playbook declares rules to be present; it never removes rules it no longer wants.
- **If someone runs Ansible with `--limit` on one host**, peers are not updated at all, and the API server is silently cut off from payments. The playbook would report success.
- **Addresses are assumed to be stable between the Terraform step and the Ansible step.** `pipeline.sh` cross-checks Terraform's IPs against `multipass info`, but on a cloud path there is no equivalent check, and a recycled public IP could point at someone else's machine.

**What I would need to know about the target environment to make it robust:**

1. **How addresses are assigned.** Static or reserved IPs? DHCP with leases? Internal DNS names I could use instead of IPs?
2. **Whether the network supports identity-based rules.** For example, cloud security groups can reference *another security group* instead of an IP. Payments would accept traffic from "anything in the API group", which survives recreation without touching any rules.
3. **Who else changes firewall rules.** If other teams or tools manage the same hosts, an exclusive "replace all rules" approach is unsafe; if Ansible owns them, it could reset to an exact list on each run.
4. **Whether there is a trusted channel to fetch host keys.** On a cloud provider, that might be the instance's console output or keys published through instance metadata, replacing my Multipass-specific step.

The most likely fix in production would be to stop expressing trust as IP addresses at all: use security-group references or service identity (mutual TLS between services), so that recreating a server changes nothing about who is allowed to talk to whom.
