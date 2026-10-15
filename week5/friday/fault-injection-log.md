# Fault Injection Log – KijaniKiosk Payments Pipeline

Pipeline: `Lint → Build → Verify (Test ‖ Security Audit) → Archive → Publish`, running in
`node:22.22.0-bookworm-slim`. Each fault was injected in its own commit, observed, then
removed with `git revert` and the pipeline confirmed green before the next fault.

| # | Stage faulted | Fault injected | Failed build | Observed behaviour (which stages ran / skipped) | Restored green build | Why this is the correct design |
|---|---|---|---|---|---|---|
| 1 | Lint | Unused variable added to `src/payments.js` (`no-unused-vars`) | #28 | Lint red (`'injectedLintFault' is assigned a value but never used`). Build, Verify (Test and Security Audit), Archive and Publish skipped. No version was assigned (build name shows no version), so nothing could be archived or published. `post`: junit "no reports" (allowed), workspace cleaned, `failure` and `changed` notifications printed. | #29 (`1.0.0-87646c3`) | Lint is the cheapest check, so a code-quality error stops the build in seconds before any time is spent building, testing or publishing. |
| 2 | Build | `scripts/build.js` throws an error before packaging | #30 | Lint green (dependencies installed, code clean). Build red (`Error: Injected build fault` from `npm run build`). Verify (Test and Security Audit), Archive and Publish skipped. No version was assigned, because the version is only stamped after a successful build, so no artifact exists to archive or publish. `post`: workspace cleaned, `failure` and `changed` notifications printed. | #31 (`1.0.0-52f3211`) | If the application cannot be packaged there is nothing valid to test or ship, so every later stage must be skipped rather than run against missing output. |
| 3 | Verify (Test branch) | Test asserting `expect(true).toBe(false)` | #33 (`1.0.0-17dd090`) | Lint and Build green, so the build was versioned (`1.0.0-17dd090`). Inside Verify the Test branch went red (1 failed, 29 passed) while the parallel Security Audit branch still ran to completion and was green. Verify marked red; Archive and Publish skipped, so this version was never archived or published to Nexus. The Test Result page named `ci-pipeline-verification: deliberate failure` (junit in `post always`). `failure` and `changed` notifications printed. | #34 (`1.0.0-af7065b`) | Leaving `failFast` off lets the Security Audit branch finish, so the developer gets every result at once, while still blocking archive and publish of code that failed its tests. |
| 4 | Archive | `archiveArtifacts` pointed at `nonexistent-dir/**` | #36 (`1.0.0-61590d1`) | Lint, Build and both Verify branches (Test, Security Audit) green. Archive red: `archiveArtifacts` found no files matching `nonexistent-dir/**` and failed the stage. Publish skipped, so `1.0.0-61590d1` is absent from Nexus even though the code itself passed every check. `post`: test results still recorded, workspace cleaned, `failure` and `changed` notifications printed. | #37 (`1.0.0-5b4bb4e`) | An artifact that cannot be stored cannot be traced, so it must never reach the registry; Publish is skipped. |
| 5 | Publish | `credentialsId` changed to `wrong-id` | #38 (`1.0.0-1e983f9`) | Lint, Build, Verify (Test and Security Audit) and Archive green. Publish red: `withCredentials` could not find a credential with ID `wrong-id`, so no `.npmrc` was ever written and nothing was sent to Nexus. The build's archived `dist/` files remain downloadable in Jenkins with fingerprints, while `1.0.0-1e983f9` is absent from Nexus. `post`: test results recorded, workspace cleaned, `failure` and `changed` notifications printed. | #39 (`1.0.0-d7d7492`) | A registry failure must not destroy the evidence: the tested artifact is already archived in Jenkins with a fingerprint, so it can be re-published once the credential is fixed. |

## Unplanned real-world failure

| Build | Cause | Observed behaviour | Lesson |
|---|---|---|---|
| #23 | npm registry timed out (`ETIMEDOUT`) during `npm ci` | Lint failed at the first network step; Build, Verify, Archive and Publish skipped; `junit` ran with no reports (allowed); `cleanWs` ran; `changed` and `failure` notifications fired | An outage of an external dependency fails fast at the first stage and nothing partial is published. A local npm mirror would remove this dependency. |

## Unplanned observation: the same commit built twice

Builds #31 and #32 both ran at 15:50 for the same commit and both published `1.0.0-52f3211`
(one started by "Build Now", one by SCM polling). Because `disableConcurrentBuilds()` was
removed, they ran side by side without interfering. Both succeeded only because the Nexus
repository currently allows redeploy; with the production setting (disable redeploy) the second
publish would be rejected, which is exactly the immutability guarantee a release registry should give.

## Post conditions observed across all faults

- `always`: test results recorded (or "no reports" allowed), workspace cleaned – every build
- `failure`: notification line printed – every faulted build
- `changed`: fired on each green→red and red→green transition, not on repeated results
- `success`: artifact and Nexus URLs printed – every restored build
