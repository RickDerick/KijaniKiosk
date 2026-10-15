# How KijaniKiosk Checks Every Change Before It Can Be Released

**Prepared for:** Nia, for the board review
**Covers:** the payments service, from a developer saving a change to an approved version being stored

## Why this matters

KijaniKiosk handles customers' money. One faulty change to the payments service could reject valid payments or accept invalid ones. Until recently, the only protection was a careful developer. Now every change passes through the same automated set of checks, in the same order, every time, before it can become a version we are allowed to release. Nobody can skip a check.

## What happens after a developer saves a change

Within three minutes of a developer saving a change, an automated checker picks it up and works through five steps. Each must pass before the next begins.

| Step | What it confirms | If it fails |
|---|---|---|
| 1. Quality check | The code is written to our agreed standards and contains no obvious mistakes, such as values that are set but never used | Stops within seconds; nothing else runs |
| 2. Assembly | The service can be packaged into a complete, self-contained bundle, and the bundle is stamped with a unique version label | Stops; no version is created |
| 3. Verification (two checks at once) | 29 automated tests prove the payment rules behave correctly, and a security scan confirms none of the outside components we rely on has a serious known weakness | Stops; both results are still reported, so the developer sees everything that needs fixing |
| 4. Record keeping | A copy of the approved bundle is kept alongside the check results, with a digital fingerprint that proves it has not been altered | Stops; nothing is released |
| 5. Release to the registry | The approved version is stored in our private software registry, ready for a future release to customers | The approved copy from step 4 is kept safely and can be re-sent |

The whole sequence takes under two minutes. Every version label combines a release number with a short code that points to the exact change it came from, for example 1.0.0-d7d7492. Any stored version can be traced back to exactly what was written, by whom, and when.

## Why versioning matters for a financial service

When a payment problem is reported, the first question is "which version was running?" Because every version is labelled with one exact change, we can answer with certainty. If a release causes trouble, we can return to the previous known-good version within minutes, knowing it is byte-for-byte the same one that passed every check. Auditors and regulators expect exactly this evidence.

## What Happens When Something Goes Wrong

We deliberately broke each of the five steps, one at a time, to prove the checks behave as intended. In every case the process stopped at the faulty step, nothing after it ran, and nothing faulty reached the registry. For example, when we added a test designed to fail, the security scan still finished so the developer had a complete picture, but the version was never released. The registry now holds every version that passed and none of the three that failed late in the process.

When the checks fail, the developer who made the change is notified immediately with a direct link to what went wrong. The team has agreed a simple rule: fixing a failure is the developer's top priority, ahead of any new work. Nobody adds changes on top of a failed one, because that would hide which change caused the problem and leave the whole team building on uncertain ground. A separate message is sent only when the overall status changes, from passing to failing or back again, so people are alerted to what is new rather than flooded with repeats.

Passwords used to reach the registry are held in a locked store and never written into the code or the records. We audited every change made this week, and every record, and found none exposed.

## What this does not yet do

This system checks and stores approved versions; it does not yet deliver them to customers, which is planned for a later phase. It currently runs on a single test machine rather than resilient production servers, notifications appear in the system's records rather than in team chat or email, and the registry still permits a version to be replaced, which must be switched off before live use. The tests cover the payment rules but not every part of the service, and the security scan only detects weaknesses that are already publicly known. These gaps are understood and scheduled, not overlooked.
