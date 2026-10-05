# KijaniKiosk Staging Environment: Security Decisions

**Prepared for:** Nia
**Purpose:** Explain how the staging environment is built and secured, in terms that can be repeated to the board.

## Summary

The staging environment, three servers in total, is now built by two automated tools in sequence: one creates the servers, the other configures them to our security standard. A single command runs both, and running it a second time changes nothing, proving the environment is a repeatable specification rather than a one-off setup. Every decision below is written as code, reviewed, and applied identically every time.

## Building the servers

**Three servers, each with one job.** The public-facing application, the payments function and the logging function now run on separate servers. Last week they shared one machine; separating them means a breach of one no longer exposes the others.

**Only approved keys can log in.** Administrators log in with one specific digital key, installed when each server is created. There are no passwords to guess or leak.

**The pipeline confirms each server's identity before trusting it.** Before configuring anything, the pipeline obtains each server's identity fingerprint through a separate trusted channel and refuses to connect if the server presents a different one, so an impostor machine cannot receive our configuration.

**The record of what we built is stored centrally.** The tools' record of every server they manage lives in a central storage service, not on one laptop, so it survives a lost computer. Its access credentials are never written into our code.

**Simultaneous changes are blocked, with one caveat.** A lock stops two people changing the environment at the same moment. Our local storage service supports this, but it is a community-maintained stand-in for cloud storage, and its locking has not been tested under real team use. In production, locking would come from the cloud provider's own locking service or a dedicated, vendor-neutral coordination service.

## Configuring the servers

**Network doors closed by default.** Each server refuses all incoming connections except a short, named list. Only the application server accepts public web traffic. Payments accepts business traffic from the application server alone, plus monitoring health checks. Logging accepts records only from the other two servers. Every rule carries a written purpose.

**Separate identities, no login.** Each function runs under its own restricted identity that cannot be used to log in as a person, exactly as last week.

**Payments is locked down hardest.** The payments service runs inside the tightest confinement we can apply without breaking it. The operating system's own assessment scores it 1.5, where 0 is fully confined and 10 is unrestricted. Our target was below 2.5. The score matches last week's, now produced automatically, and the pipeline fails if it ever rises above target.

**The application cannot rewrite itself.** Each service can read its own program but cannot change it, and can write only to one designated logging area.

**Software versions are fixed.** Key software is held at approved versions so that routine updates cannot silently change how the servers behave. Security fixes still arrive through the operating system vendor's supported channel.

**Activity is recorded durably.** System logs survive restarts within a size cap, and application logs are archived on a schedule.

## Controls at a glance

| Control | What it does | Risk mitigated |
|---|---|---|
| One function per server | Application, payments and logging run on separate servers | A breach of one function does not hand over the others |
| Key-only administrator access | Logins require a specific digital key; no passwords | Password guessing and leaked passwords |
| Verified server identity | Pipeline confirms each server's fingerprint before connecting | An impostor server receiving our configuration |
| Central infrastructure record | Record of managed servers kept in shared storage, credentials outside code | Losing track of infrastructure if a laptop fails; leaked credentials |
| Change locking | Blocks two people changing the environment at once | Conflicting changes corrupting the environment record |
| Default-deny firewall per server | Only named connections allowed, each documented | Outsiders reaching services they should not |
| Payments reachable only from the application | Payments accepts business traffic from one server | Direct attacks on the money-handling service |
| Separate non-login identities | Each service runs as its own restricted account | One compromised service taking over the machine |
| Payments confinement (score 1.5) | Strictest operating-system restrictions, checked every run | Limits damage if payments is attacked; prevents quiet weakening |
| Read-only programs | Services cannot alter their own code | Attackers planting persistent changes |
| Fixed software versions | Approved versions held in place | Untested updates changing behaviour |
| Durable, capped logging | Logs kept across restarts within a size limit | Lost investigation trail; disks filling up |

## What this does not protect against

This foundation has limits worth stating plainly. Traffic between our three servers is not yet encrypted, so anyone able to observe the internal network could read it. The secrets the services use are placeholders; real payment and database credentials will need a dedicated secret store before go-live. Change locking relies on a community substitute for cloud storage and needs a production-grade replacement. That storage software no longer receives official updates from its maker, a supply-chain risk to resolve. Administrator access accepts any computer holding the key, rather than only our office network. The monitoring network named in the firewall rules does not exist yet. Nothing here protects against flaws in the application code itself, a stolen administrator key, or a compromised payment provider. Naming these gaps is deliberate: they are our next priorities, not surprises waiting to be found.

## Evidence

Payments confinement score, read automatically on every pipeline run (from the second run's log):

```
ok: [kijanikiosk-payments] => {
    "msg": "kk-payments exposure 1.5 (target below 2.5)"
}
```

Screenshot: `screenshots/kk-payments-security-score.png`
