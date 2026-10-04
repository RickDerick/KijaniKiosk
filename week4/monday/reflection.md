Question 1: The Idempotency Gap

Your bash guard (id kk-api || useradd kk-api) checks reality right before acting. Terraform moves that check out of your code and into a three-way comparison it does on every run: your configuration (desired state), the state file (what Terraform last recorded), and the real infrastructure (read live through the provider's API).

The state file (terraform.tfstate) is JSON. For every resource address, like aws_instance.api, it maps that address to the real object's ID, such as i-0abc123.... It also stores all of that object's attributes as last seen: AMI, instance type, subnet, tags, volume size, public IP, and so on. On top of that, it records dependencies between resources, the provider used, outputs, and metadata (serial and lineage) used to detect conflicting copies. The ID mapping is the key piece. Without it, Terraform has no way to know that the instance in your account is "the one it manages".

When you run terraform plan, Terraform first refreshes: it uses the stored IDs to ask AWS what each resource currently looks like. Then it compares that with your configuration and decides per resource:

Create: the resource is in the config but not in state.
Destroy: the resource is in state but no longer in the config.
Update in place: an attribute differs and can be changed live, like tags or a security group rule.
Destroy and recreate: the changed attribute can't be modified on a live resource. Changing the AMI is the classic example.
Do nothing: everything matches.

So the "guard condition" still exists. It's just built into the engine and driven by the state file, instead of hand-written for every operation.

When state says "nothing to do" but reality has drifted. Terraform can only detect drift in attributes it tracks, on resources it knows about. Drift slips through in a few ways:

Changes inside the VM. Someone SSHs in, deletes the kk-api user, and edits the nginx config. AWS still reports the same instance type, AMI, and tags, so Terraform reports no changes even though the server is broken.
Out-of-band resources. Someone adds an extra inbound rule (say, port 3306 from anywhere) in the console. If your rules are defined as separate rule resources, Terraform doesn't know that new rule exists and will never flag it. That's a security hole Terraform is blind to.
Ignored or skipped checks. Attributes listed under lifecycle { ignore_changes = [...] } aren't compared. Running with -refresh=false, or with a stale local copy of state that someone else has since applied over, means Terraform compares against outdated information.

The correct response has three parts. First, detect it: run terraform plan -refresh-only regularly (even on a schedule) to see what changed outside Terraform. Second, decide which side is right. If the manual change was wrong, run terraform apply to put things back. If it was a legitimate fix, write it into the configuration, and use terraform import (or an import block) to bring out-of-band resources under management. Never edit the state file by hand to make the drift "go away". Third, prevent it next time: store state remotely with locking (S3 plus DynamoDB, or Terraform Cloud), limit console write access, and give in-VM configuration to a tool built to enforce it, like Ansible.

Question 2: Declarative Specification Quality

Measured against the "different engineer, different cloud, no questions" test, a spec built from our decisions table falls short in several places. Pick two or more that match your document.

Gap 1: the operating system is described as an AWS artifact, not a requirement. Writing "Ubuntu 24.04 LTS, ami-0abc..." doesn't carry over to another provider: AMI IDs only exist in one region of one cloud. It also leaves open whether the image should be pinned or simply "the latest 24.04", and whether it's x86 or ARM. If Terraform filled this gap with a data source looking up the most recent Ubuntu image, a run next month could pick a newer image. Because the AMI can't be changed on a running instance, Terraform would plan to destroy and recreate the server. A run in another region or cloud would simply fail, because the ID doesn't exist there.

Gap 2: the instance size is AWS vocabulary. "t3.micro" means nothing on GCP or Azure. The real requirement is something like "2 vCPU, 1 GiB RAM, burstable is acceptable, x86_64." Another engineer would have to guess: GCP's e2-micro has the same memory but only a fraction of a shared CPU most of the time, so the "same" server would behave differently under load.

Gap 3: the network is described by AWS defaults. "Default VPC" and "default subnet" leave out the IP address range (CIDR), whether the subnet is public, and which availability zone to use. Every provider's default network is set up differently. In Terraform, if you leave out subnet_id, AWS places the instance in a default subnet in whichever zone it chooses. If you leave out the security group list, the instance gets the VPC's default security group, whose rules are probably not what you intended.

Gap 4: rules that can't be reproduced. "SSH from My IP" depends on whoever is clicking the console at that moment. The spec needs an actual address range (CIDR) or a named policy, like "SSH only from the office VPN range."

Gap 5: unstated storage details. "20 GiB gp3" doesn't say whether the disk is encrypted, what performance it needs, or whether it should survive the instance being terminated. If you leave out root_block_device entirely, you get whatever size the image defines (8 GiB for Ubuntu). Encryption stays off unless the account has default encryption turned on.

What this tells you. Terraform never complains about a gap. It fills each one with a provider default, and the plan succeeds. Automation doesn't make a vague spec safer. It reproduces the vague spec's assumptions consistently, quickly, and silently, so a missing requirement becomes a reliable bug instead of a visible error. A good spec separates the portable intent (2 vCPU, 1 GiB, Ubuntu 24.04 x86, port 22 from a specific range, 20 GiB encrypted disk) from the provider-specific translation (t3.micro, ami-xxx, gp3). Explicit values in the configuration are what turn "it worked when I did it" into "it works every time".

Question 3: Tool Boundary

Task 1: firewall rule allowing port 80 from anywhere → Terraform. A security group is a cloud resource: an object in AWS with its own ID and lifecycle, attached to the instance from outside. It needs to exist before the VM is reachable, and you want Terraform to track it in state and detect drift. If you used bash with the AWS CLI, the second run would fail with a duplicate-rule error, and nothing would record that the rule exists. Deleting it later would mean remembering it was there, and manual changes would go unnoticed. If you used Ansible's AWS modules, it could technically work, but now two tools manage the same resource and will overwrite each other's changes.

The defensible twist: if "firewall rule" means the host firewall inside the VM (ufw or iptables), that is operating system configuration and belongs to Ansible. A strong answer says use both: Terraform for the cloud security group, Ansible for ufw, as two layers of defense.

Task 2: installing nginx 1.24.0 on a running VM → Ansible. Package installation happens inside the operating system. Ansible's apt module, with a pinned version and state: present, is idempotent and re-enforces the version on every run. Note that Ubuntu's package version string looks like 1.24.0-2ubuntu7, so the pin has to match exactly, and you should hold the package so apt upgrade doesn't drift it.

If you used Terraform instead, the options are user_data (runs only on first boot, so nothing re-checks it afterward) or remote-exec provisioners. HashiCorp calls provisioners a last resort: they aren't tracked in state, they don't detect drift, and a failure marks the whole instance for replacement. Bash works, but you're back to hand-writing guards and version checks.

The defensible alternative: bake nginx into a custom machine image with Packer, then have Terraform launch from that image. Installing software then becomes a provisioning concern instead of a configuration one. That's the immutable-infrastructure approach, and it's a legitimate answer if you defend it.

Task 3: verifying nginx responds → Ansible (the uri module) or bash (curl); both are defensible. Verification is a read-only observation, not a state you manage, so the main argument for declarative tools (convergence and idempotency) doesn't apply. Running a check twice is naturally harmless. Putting a uri task at the end of the playbook means a failed check fails the deployment run. A bash curl -fsS --retry 5 http://localhost/ is simple and portable, and the same check can be reused in a CI pipeline.

Terraform is the wrong tool here. Terraform does have check blocks with an http data source, but they run from the machine running Terraform, during plan or apply, which is before Ansible has installed nginx. The check would fail or warn for the wrong reason, and checks only produce warnings, not failures. One more nuance worth including: curl localhost proves nginx works, while curling the public IP from outside also proves the security group allows the traffic. Those are different claims.

Question 4: From Script to Spec

Use your actual eight phases here. A typical Week 3 script looks something like this: (1) preflight checks, (2) update and install packages, (3) create the kk-api user, (4) create directories and set permissions, (5) deploy config and app files, (6) set up the systemd service, (7) configure the firewall, (8) verify.

Phases that translated cleanly are the ones describing a thing with properties. "User kk-api exists with shell /usr/sbin/nologin." "Directory /opt/kijanikiosk exists, owned by kk-api, mode 0750." "Package nginx is installed at version X." "Service kk-api is enabled and running." "Port 80 is allowed." Each is a noun with attributes, and the tool can check whether it matches. Your script's guard conditions already hinted at this: wherever you wrote a guard, you were really testing whether a state was true.

Phases that were difficult or impossible are the ones that are events, conditions, or observations rather than states:

Preflight checks ("am I root?", "is this Ubuntu?") are preconditions on running the script, not properties of the server.
"apt update && apt upgrade" has no fixed end state. "Latest" changes daily, so you can't describe it as a state without pinning versions.
Ordering and reactions ("restart the service only if the config file changed") are time-based. Ansible needs a special construct, handlers, precisely because this isn't a pure state.
One-time actions, like running database migrations or generating an application secret, must happen exactly once, in order. The only way to make them "declarative" is to keep a record of what already ran, which is essentially reinventing a state file.
Verification (phase 8) is an observation. As in Question 3, it doesn't describe a desired state at all.

What the difficulty tells you. Infrastructure provisioning deals with cloud API objects that have a clean ID, a fixed set of attributes, and a cheap way to read their current values. That's why it fits declarative tools and a state file so well. Configuration management deals with the inside of a long-lived, mutable machine, where state is spread across files, package databases, running processes, and data, and where many important operations are transitions rather than end states. So config management tools are convergent with imperative escape hatches: Ansible checks the live machine on every run instead of keeping a state file, and still needs handlers, ordering, and command tasks for things that can't be expressed as a state.
