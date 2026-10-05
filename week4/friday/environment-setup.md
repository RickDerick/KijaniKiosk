# Environment Setup

Lab path: **Multipass (primary path)** with MinIO as the Terraform remote backend.

## Host machine
| Component | Version |
|---|---|
| Operating system | Ubuntu 26.04.1 LTS (resolute) |
| Terraform | 1.16.2 (linux_amd64) |
| Multipass | 1.16.4 (multipassd 1.16.4) |
| Ansible | core 2.21.2 (Python 3.14.4, Jinja 3.1.6) |
| Docker | 29.8.0 (Docker Engine) |
| MinIO | RELEASE.2026-08-04T00-00-00Z (pgsty/minio community build) |

## Target servers
| Server | Image | Created by |
|---|---|---|
| kijanikiosk-api | Ubuntu 22.04 LTS | Terraform (app_server module) |
| kijanikiosk-payments | Ubuntu 22.04 LTS | Terraform (app_server module) |
| kijanikiosk-logs | Ubuntu 22.04 LTS | Terraform (app_server module) |

## Supporting services
- MinIO runs in Docker at http://localhost:9000 (console on :9001), with its
  data directory mounted from ~/minio-data so Terraform state survives restarts.
- Image: pgsty/minio (community build of MinIO). The official minio/minio image
  was removed from Docker Hub in October 2025 and the quay.io mirror is no
  longer accessible. Production would need a maintained, verified source or a
  self-built image.
- State bucket: kijanikiosk-tfstate
- SSH key used by both Terraform and Ansible: ~/.ssh/kijanikiosk
- MinIO credentials are supplied via AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
  environment variables, never stored in the repository.
