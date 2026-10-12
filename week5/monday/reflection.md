# Week 5 Monday – Reflection

Setup: Jenkins LTS on the `kijanikiosk-api` Multipass VM (Java 21), building the
`kijanikiosk-payments` repository, triggered by SCM polling (`H/5 * * * *`).

---

## Question 1: What Today's Pipeline Does Not Do

Today's pipeline runs `node --version` and `npm --version`. That proves the build agent has a runtime, not that our code works. Against the three CI properties, it is missing:

**1. An automated build.** Nothing is installed or assembled. I would add a `Build` stage running `npm ci`, which installs exactly what `package-lock.json` pins and fails if the lock file and `package.json` disagree.

**2. A self-testing build.** No test runs, so a broken payment rule still shows green. I would add a `Test` stage running `npm test` (Jest, 29 tests), and `npm test -- --ci --coverage` with the `junit` step publishing results, so a failing test turns the build red and shows which test failed.

**3. Fast feedback on every integration to main.** Polling only covers `main` after the fact. I would add `post { failure { ... } }` to notify the author, keep the pipeline under ten minutes, and later run the same stages on pull requests so broken code is caught before it merges, not after.

---

## Question 2: The Broken-Build Contract in Practice

Two days before the board review, Wanjiru pushes a change that fixes how payment amounts display on receipts. One Jest test fails: a phone-number validation test she didn't touch. She argues: "My change is urgent for the demo, the failure isn't mine, I'll fix it after the review."

The exception costs more than it looks. While `main` is red, the other three developers can't tell whether their pushes broke anything, because the build was already failing. Brian merges a real bug in amount rounding; it is hidden behind the existing red build. Each person either stops and waits, or keeps merging blind.

Over a two-week sprint, "just this once" compounds. Once one red build is tolerated, the next one is too. After a few days nobody trusts the signal, failures pile up, and fixing `main` means untangling three or four overlapping breakages instead of one. The fix that would have taken Wanjiru twenty minutes on Tuesday becomes a day of the whole team's time the week before the board review: exactly the risk the exception was meant to avoid.

---

## Question 3: The Jenkinsfile in the Repository

**Problem 1: Jenkins is rebuilt and the pipeline is gone.** I hit a version of this today. My laptop was reinstalled and Jenkins had to be installed fresh, and a pipeline defined only in the UI lives in `/var/lib/jenkins/jobs/<job>/config.xml` on that one server. If the VM is recreated by `pipeline.sh`, that file is lost and someone must rebuild the job from memory, clicking through forms and hoping the settings match. With a `Jenkinsfile` in `kijanikiosk-payments`, the new Jenkins only needs the repository URL; the pipeline comes back exactly as it was.

**Problem 2: Pipeline changes bypass review and history.** A UI edit (say, someone deleting the `Test` stage to get a release out) takes effect immediately. There is no pull request, no reviewer, and no `git log` or `git blame` to show who removed it or why. A developer trying to understand why the pipeline behaves a certain way has nowhere to look. With a `Jenkinsfile`, that same change is a diff in a PR that Tendo can reject, and the history explains every stage. The pipeline also versions with the code: an old commit carries the pipeline that built it.

---

## Question 4: Webhooks vs Polling

I chose **SCM polling** with `H/5 * * * *`. Every five minutes, at an offset Jenkins derives from the job name (the `H`), Jenkins runs the equivalent of `git ls-remote` against GitHub and compares the latest commit on `main` with the one it last built. A new commit triggers a build; otherwise nothing happens. The job's **Git Polling Log** shows each check.

Polling was the only option that works here: Jenkins sits on a private Multipass network (`10.4.110.0/24`) that GitHub cannot reach, so a **webhook**, where GitHub sends an HTTP POST to `http://<jenkins>/github-webhook/` on every push, would never arrive. Polling reverses the direction: Jenkins calls out.

Webhooks win once Jenkins is reachable and pushes are frequent. Polling adds up to 5 minutes of delay. For one developer pushing a few times a day, that is noise. For KijaniKiosk's four developers pushing roughly every 15–20 minutes during a busy day, several pushes land in the same polling window and get built together, so a failure can't be pinned to one commit. Once the wait to start is comparable to the build itself (our tests take seconds), the delay dominates the feedback loop, and that is the point to switch to webhooks.
