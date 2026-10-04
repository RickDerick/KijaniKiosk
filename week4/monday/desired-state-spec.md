# KijaniKiosk API Server - Desired State Specification

## Identity
- Name: kijanikiosk-api-staging
- Environment tag: staging
- Owner tag: amina

## Compute
- Provider: [your provider]
- Region: [your region]
- Instance type: [your instance type]
- Operating system: ubuntu-22.04-lts (exact image ID: [fill in])
# Note: this becomes a Terraform data source on Tuesday — you will look this up dynamically

## Networking
- VPC: [VPC ID or CIDR]
- Subnet: [subnet ID]
- Assign public IP: [yes/no]

## Access Control
- SSH access: port 22, source [your IP]/32 only
- HTTP access: port 80, source 0.0.0.0/0
- All other inbound: deny
- All outbound: allow

## Storage
- Root volume: [size]GB, type [gp2/ssd/etc]

## Authentication
- SSH key pair name: [name]

## What must NOT exist on this server after provisioning
- No default password authentication
- No services listening other than sshd
- No world-writable directories outside /tmp

## Open questions (things that will need decisions before Terraform can encode this)
- [list anything you were unsure about when making the manual decision]
