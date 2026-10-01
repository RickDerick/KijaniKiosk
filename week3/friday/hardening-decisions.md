# KijaniKiosk Payments Node — Security Posture

**Prepared for:** Nia
**Purpose:** Explain, in plain terms, how the new payments server is secured and
what that protects the business from.

## Summary

The payments server has been built to a deliberate security standard from the
first command, rather than assembled and patched afterwards. The guiding idea is
simple: every part of the system is given the least access it needs to do its
job, and nothing more. If any single component is ever compromised, that
principle limits how far an attacker can reach. This document explains the major
decisions in business terms and states, for each, the risk it reduces.

## The core decisions

**Separate identities for each part of the system.** The payments function, the
main application, and the logging function each run under their own dedicated
identity with no ability to log in as a person. If one is breached, the attacker
inherits only that one identity's narrow access, not the run of the whole
machine. This is the difference between losing one room and the whole building.

**The payments function is locked down more tightly than the others.** Because it
handles money and cardholder-adjacent data, it is confined more strictly than
the general application: it can see only its own activity, holds no special
system powers, and keeps its secrets in an isolated store. It carries the
highest level of restriction of the three components, by design.

**Each component can only touch the files it needs.** The system as a whole
treats almost the entire server as read-only from each service's point of view.
A service can write only to the one place it legitimately needs — its log area —
and nowhere else. An attacker who takes over a service cannot tamper with system
files, other services' data, or the operating system itself.

**Sensitive configuration is readable only by the right identity.** The files
holding database and payment credentials are restricted so that only the
specific service that needs them, and trusted administrators, can read them. No
ordinary account on the machine can view them.

**The network door is closed by default.** The server refuses all incoming
connections except the few explicitly required: administrator access, public web
traffic, and a health-check channel that is only reachable from our own
monitoring network. The internal payments channel is blocked from the outside
world entirely and reachable only from the server itself.

**Every firewall rule states its purpose.** Each network rule carries a written
explanation of why it exists. This means the security posture can be read and
understood at a glance, rather than being a pile of historical changes nobody
can explain — which is exactly what a board or auditor asks about.

**The server records its own activity durably.** System logs are kept on disk
and capped at a fixed size, so we retain a meaningful history for investigation
without the logs ever filling the disk and causing an outage.

**Logs remain intact and correctly controlled as they rotate.** Log files are
automatically archived on a schedule, and the access controls are preserved
across that process, so the services keep writing and the monitoring system
keeps reading without any manual fix. This keeps our audit trail unbroken.

**The whole build repeats identically every time.** The server is defined by a
single script that produces the same secure result no matter how many times it
is run, and regardless of what state the machine was in beforehand. There is no
reliance on someone remembering a manual step. This makes the security posture
reproducible and verifiable.

## Controls at a glance

| Control | What it does | Risk mitigated |
|---|---|---|
| Separate service identities | Each function runs as its own restricted, non-login account | A breach of one function cannot take over the others or the machine |
| Payments-specific lockdown | The payments function is confined more strictly than the rest | Limits damage if the money-handling component is attacked |
| Read-only system | Services can write only to their own log area | Prevents tampering with system files or other services' data |
| Restricted configuration access | Credential files are readable only by the right identity | Stops other accounts from reading database or payment secrets |
| Default-deny firewall | All incoming connections blocked except a named few | Reduces the ways an outsider can reach the server |
| Internal-only payments channel | The payments port is blocked externally, open only internally | Prevents direct external access to the payments service |
| Documented firewall rules | Every rule carries a written purpose | Makes the security posture auditable and board-explainable |
| Durable, capped logging | Activity is retained on disk within a fixed size limit | Preserves an investigation trail without risking an outage |
| Rotation-safe log access | Access controls survive automatic log archiving | Keeps the audit trail unbroken and monitoring functional |
| Reproducible build | One script yields the same secure result every run | Removes human error and makes the posture verifiable |

## What this does not protect against

This foundation secures how the server is built and confined, but it is not the
whole story, and it is worth being clear about the gaps. It does not protect
against a flaw in the payment application's own code — if the software itself
mishandles data, these controls limit the blast radius but do not prevent the
mistake. It does not by itself defend against a stolen valid credential used
correctly, nor against an attacker who compromises the payment provider or
database we connect to. It does not encrypt data travelling between this server
and other systems; that is handled separately and must be confirmed. And it
assumes the underlying operating system and hardware are trustworthy and kept
patched. Honest visibility of these gaps is deliberate: a security posture that
overclaims is less trustworthy than one that names its own limits and plans for
them.
