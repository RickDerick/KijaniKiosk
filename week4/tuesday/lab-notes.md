# Week 4 Tuesday – HCL and Terraform Workflow Lab Notes

## Environment
- Path: Multipass (primary lab path)
- VM: kijanikiosk-api, 10.156.170.218
- Providers: hashicorp/local ~> 2.4, hashicorp/null ~> 3.2

## Verification (outputs, state, SSH)
- terraform output: api_server_ip, inventory_file, ssh_command all correct
- uname -a: Linux kijanikiosk-api 7.0.0-34-generic x86_64
- lsb_release: Ubuntu 26.04.1 LTS (resolute)
- Discrepancies vs desired-state-spec.md: <fill in, e.g. OS version if spec said 24.04>

## Phase 3: State investigation
- Resource types: null_resource, local_file
- Resource IDs:
  - null_resource.kijanikiosk_api: 4059058632800744573
  - local_file.inventory: b3a77ff181eaccbdd1db34626d3b91d12875a576
- Attributes only known after apply (shown as "known after apply" in plan):
  1. null_resource.kijanikiosk_api.id = 4059058632800744573
  2. local_file.inventory.content_sha256 = <paste from terraform state show>

## Observations
- First plan showed a stale "kk-api" vm_name from terraform.tfvars; caught by
  reading the plan before applying.
- I accidentally saved variable values as terraform.tf instead of
  terraform.tfvars. Terraform rejected it, and .gitignore would not have
  excluded it, so it could have been committed. Renamed to terraform.tfvars.
- remote-exec reported "Checking Host Key: false": the VM's SSH host key was
  not verified. Acceptable on a private Multipass network; in production,
  set host_key in the connection block.
- Destroying null_resource does not delete the Multipass VM, because Terraform
  did not create it. Terraform only removes its own record of it.
