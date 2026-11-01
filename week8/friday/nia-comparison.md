# What Week 8 Gives KijaniKiosk That Week 7 Did Not

**Prepared for:** Nia, for the Monday board presentation
**Covers:** the payments service, from a finished change to a running service that repairs itself

## The short answer

In Week 7 we built a reliable way to release the payments service onto one particular server. It worked, but only because that server had been prepared exactly right: the correct runtime installed, the correct folders in place, the correct accounts created. A second server prepared slightly differently would behave differently.

Week 8 removes that dependency. The payments service now travels as a sealed package that carries everything it needs to run. The same labelled package behaves identically wherever it runs. Once running, it is watched by a system that keeps two copies alive at all times and replaces a failed copy on its own, without anyone being called.

## What we proved, end to end

On 1 November we started from an empty environment and rebuilt everything from the source files alone, with nothing left over from earlier in the week. The package was built from scratch, given a label that ties it to one exact change (release 1.0.0, change a59f2c1), and stored in our private registry. We then deleted our local copy and downloaded it again, proving the registry is the single source of truth. Two copies of the service were running within 12 seconds, including that download, and answered requests from outside the cluster. Each copy reports the exact label it was built from, so there is no doubt about what is running.

## Two numbers from this week's evidence

**Self-repair in under one second.** We deliberately deleted one of the two running copies. A replacement was running and ready 0.9 seconds later, while the other copy carried on serving throughout. In Week 7, a crashed service could be restarted on the same server, but if the server itself failed, the service stayed down until an engineer built a replacement.

**A shipped package about one third smaller than the build environment.** The environment used to build and test the service, with all its development and testing tools, is 355 megabytes. The package we actually ship is 233 megabytes on disk and 57 megabytes when sent over the network. None of the testing tools reach production, so they cannot be attacked there. To be precise about where the saving came from: Monday's first version already left the development tools out, so Monday's package and Tuesday's are the same size. What Tuesday added was a strict separation between building and running, and running the service without administrator rights.

## Week 7 compared with Week 8

| Concern | Week 7 (one VM, blue/green) | Week 8 (container image + Kubernetes) |
|---|---|---|
| Deployment mechanism | Deploy script fetches a versioned tarball, copies it into the blue or green directory on one VM and restarts that systemd unit; nginx switches traffic. Node.js, npm, users and directories must already be provisioned by Ansible. | Multi-stage image (Node 22 runtime included, non-root `kijani` user) pushed to a private Docker Hub repository as `1.0.0-a59f2c1`. A Deployment declares the image and `replicas: 2`; nodes pull it using the `kijani-registry-credentials` ImagePullSecret. The host needs only a container runtime. |
| Rollback mechanism | Script switches nginx back to the previous colour, which must still be installed on the same VM. | Re-apply the Deployment with the previous immutable semver-SHA tag, or `kubectl rollout undo`; the previous ReplicaSet is retained and any node can pull the old image by tag. |
| Failure recovery | systemd `Restart=on-failure` restarts the process on the same VM; a VM failure is an outage until someone provisions a replacement. | The Deployment controller replaces a deleted or crashed Pod automatically: measured 0.9 s from deletion to 2/2 Ready (12 s for a cold start including the image pull). On a multi-node cluster, Pods are rescheduled away from a failed node. |
| Scaling | Provision another VM, re-run Ansible, add it to the nginx upstream: hours of work, with drift risk between servers. | Change `replicas` or run `kubectl scale`; new Pods start from the identical image in seconds, limited only by cluster capacity. |

## What Week 8 does not yet solve

This is not yet production-ready, and the board should hear that plainly. Everything ran on a single machine standing in for a cluster, so if that machine fails, every copy fails with it; moving work to a healthy machine only applies once we run on several. The system also treats a copy as ready the moment it starts, not when it has confirmed it can process payments, so a slow-starting copy could briefly receive requests it cannot handle. Settings are written directly into the deployment description instead of being managed per environment, the access route used for testing is a laboratory shortcut rather than a secure public entrance, and the package is still built and released by hand rather than by the automated pipeline. Week 9 closes the readiness gap with health checks the cluster acts on, moves settings and credentials into managed configuration, and adds a controlled public entrance. Running across several machines and automating releases follow after that.
