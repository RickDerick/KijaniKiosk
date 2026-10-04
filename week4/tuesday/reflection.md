# Week 4 Tuesday – Reflection and Engineering Thinking

Lab path: Multipass (`kijanikiosk-api`, 10.156.170.218) using the `null` and `local` providers.
Where a question assumes AWS resources (instance ID, security group), I answer the concept and relate it to what I actually built.

---

## Question 1: The State File as a System

**How Terraform knows attributes I never declared**

My configuration only describes the *desired* state: the arguments I chose to set. When Terraform creates a resource, the provider performs the real action and then returns the *complete* object as it exists after creation, including every computed attribute. Terraform records that full object in `terraform.tfstate`. On every later `plan`, Terraform refreshes the state by asking the provider to read each resource again, so the state reflects reality, not just my code.

I saw this directly in my lab. I never declared an `id` for either resource, yet the state held:

- `null_resource.kijanikiosk_api` → `id = 4059058632800744573`, a random ID the null provider generated at creation.
- `local_file.inventory` → `id = b3a77ff181eaccbdd1db34626d3b91d12875a576` plus `content_md5`, `content_sha256` and other hashes, all computed by the local provider after it wrote the file.

On AWS the same mechanism fills in the instance ID, private IP, launch time and so on, because the EC2 API returns them after launch.

**What happens on `terraform destroy`**

Terraform destroys each resource through the provider, then removes it from state. The state file itself is not deleted: it remains with an empty `resources` list and an incremented `serial`, and the previous version is kept in `terraform.tfstate.backup`. My `terraform state list` returned empty output after destroy, which confirms this.

**If I deleted the state file without destroying the infrastructure**

Terraform would have no memory of what it manages. The next `terraform plan` would show every resource as `+ create`, because as far as Terraform knows, nothing exists. Applying that plan would create duplicates (a second VM on AWS, with charges for both) or fail on resources that need unique names. The original infrastructure would become orphaned: still running and still costing money, but invisible to Terraform.

In my Multipass lab the impact would be small: `local_file` would overwrite the inventory file and `null_resource` would re-run a harmless SSH command. On a real cloud account it would be a costly mistake.

**Correct recovery procedure**

1. Do **not** run `terraform apply`. A plan showing everything as new is a warning sign, not an instruction.
2. Restore the state if a copy exists: `terraform.tfstate.backup`, or a previous version from a versioned remote backend such as an S3 bucket with versioning.
3. If no copy exists, re-attach each real resource with `terraform import` (or `import` blocks in Terraform 1.5+), using its real ID, such as the AWS instance ID.
4. Run `terraform plan` and confirm it shows **no changes**. That is the proof that state and reality agree again.
5. Prevent a repeat by moving state to a remote backend with versioning and locking, instead of a local file on one laptop.

---

## Question 2: The (known after apply) Values

A value is `(known after apply)` when it does not exist until the provider actually performs the action. At plan time Terraform only knows my configuration and the current state, so it cannot predict values that the provider or the real system generates during creation.

**Two examples from my plan:**

1. **`null_resource.kijanikiosk_api.id`**: the null provider generates this as a random number at the moment of creation. There is nothing to calculate it from in advance, so it can only exist after apply. It came out as `4059058632800744573`.
2. **`local_file.inventory.content_sha256`** (and the other hashes, plus `id`): these are checksums of the file as written to disk. The provider treats them as computed results of the write, so they are reported only after the file exists.

The AWS equivalents are an instance's `id` and `public_ip`: AWS assigns them when the instance launches, not when Terraform plans.

**Outputs that depend on unknown values**

If an output references a `(known after apply)` attribute, `terraform plan` also shows that output as `(known after apply)` under "Changes to Outputs". The unknown value propagates to anything built from it. For example, an `ssh_command` output built from `aws_instance.kk_api.public_ip` would be unknown at plan time.

In my lab, all three outputs (`api_server_ip`, `inventory_file`, `ssh_command`) showed real values during plan, because they were built from input variables and the configured filename, which are known before apply. That shows the rule from the other direction: an output is only unknown if something it depends on is unknown.

---

## Question 3: Hardcoded vs Variable

**Why a hardcoded IP is a problem for a team**

An SSH ingress rule with one engineer's IP (for example `41.90.x.x/32`) works only for that engineer, from that network. For a shared configuration this causes several problems:

- **It doesn't work for teammates.** Tendo or anyone else on a different network is locked out, so they must edit source code to do their job.
- **It changes constantly.** Home and mobile IPs in Nairobi are often dynamic, so the rule silently breaks when the IP changes.
- **Edits to source code cause conflicts and drift.** Each engineer commits their own IP, overwriting each other's, and the repository's history fills with noise.
- **It leaks information.** A personal IP address ends up in a shared, possibly public, repository.
- **It tempts people to use 0.0.0.0/0** "just to make it work", which opens SSH to the whole internet.

In my Multipass lab there was no security group, but the skeleton had the same kind of problem: `user = "ubuntu"` and `private_key = file("~/.ssh/id_rsa")` were hardcoded. I replaced them with `var.ssh_user` and `var.ssh_key_path` so that each engineer supplies their own values without touching `main.tf`.

**How I would solve it**

Declare the allowed IPs as a variable and supply them per engineer or environment in `terraform.tfvars`, which is not committed:

```hcl
variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed to SSH into KijaniKiosk servers"
  type        = list(string)
  # No default: must be supplied explicitly, so nobody falls back to 0.0.0.0/0

  validation {
    condition     = alltrue([for c in var.allowed_ssh_cidrs : can(cidrhost(c, 0))])
    error_message = "Every entry must be a valid CIDR block, e.g. 41.90.10.20/32."
  }

  validation {
    condition     = !contains(var.allowed_ssh_cidrs, "0.0.0.0/0")
    error_message = "SSH must not be open to the whole internet."
  }
}
```

```hcl
ingress {
  description = "SSH from approved addresses"
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = var.allowed_ssh_cidrs
}
```

```hcl
# terraform.tfvars (not committed)
allowed_ssh_cidrs = ["41.90.10.20/32", "102.68.5.11/32"]
```

**Type:** `list(string)`, a list of CIDR strings. That matches what the AWS `cidr_blocks` argument expects. `set(string)` would also work if order doesn't matter and I want to prevent duplicates.

---

## Question 4: What Tuesday's Configuration Cannot Do

**Values that would differ between staging and production**

| Value | Where it lives | Staging (today) | Production |
|---|---|---|---|
| `environment` | `terraform.tfvars` | `staging` | `production` |
| `vm_name` | `terraform.tfvars` | `kijanikiosk-api` | e.g. `kijanikiosk-api-prod` |
| `vm_ip` | `terraform.tfvars` | `10.156.170.218` | the production server's IP |
| `ssh_key_path` | `variables.tf` default | `~/.ssh/kijanikiosk` | a separate production key |
| `ssh_user` | `variables.tf` default | `ubuntu` | possibly a dedicated deploy user |
| Inventory filename | derived from `environment` | `inventory-staging.ini` | `inventory-production.ini` (already automatic) |
| On AWS: region, instance type, key pair, VPC/subnet, allowed SSH CIDRs | variables | free-tier/test values | production values |

Most of these are already variables, which is good. The deeper problem is not the values, it is **the structure around them**.

**What happens if production needs a larger instance, a different VPC and more VMs?**

With today's approach I have one directory, one `terraform.tfvars` and one local state file. To deploy production I would have to:

1. **Edit `terraform.tfvars` and swap the values back and forth.** This is manual and error-prone. One forgotten value and production runs with a staging setting, or the reverse. This is exactly the kind of mistake I made today with the stale `kk-api` name.
2. **Share one state file between environments.** This is what really breaks. The state currently records the staging resources. If I change the values to production and run `terraform plan`, Terraform does not create production *alongside* staging. It plans to **modify or replace the staging resources** to match the production values. With my `null_resource`, changing `vm_ip` changes the trigger, so the plan would show `-/+`: destroy the staging record and recreate it pointing at production. On AWS, changing the instance type or VPC would modify or replace the staging instance itself.
3. **Copy the directory per environment as a workaround.** This gives separate state, but now there are two copies of `main.tf` that drift apart as soon as someone fixes a bug in only one of them.
4. **Fail to express "a different number of VMs".** My configuration declares exactly one `null_resource` (one `aws_instance` on AWS). Running three production servers would mean copy-pasting resource blocks, because nothing in the code accepts a count.

**What the solution needs**

To meet Tendo's goal, that nothing in the source code changes between environments and only the variable values do, the configuration needs:

- **Separate variable files per environment** (`staging.tfvars`, `production.tfvars`) selected with `-var-file`, instead of editing one file.
- **Separate state per environment** (workspaces, or separate backend keys/directories), so applying production can never touch staging.
- **Variables for scale**, such as an `instance_count` used with `count` or `for_each`, so the number of servers is a value, not copy-pasted code.
- **Reusable modules**, so staging and production call the same code with different inputs, and a fix made once applies everywhere.

That is the problem Wednesday solves.
