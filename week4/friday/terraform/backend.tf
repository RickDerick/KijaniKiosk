# Remote state in MinIO (S3-compatible), running locally in Docker.
# Credentials are NOT stored here: export AWS_ACCESS_KEY_ID and
# AWS_SECRET_ACCESS_KEY before running terraform (pipeline.sh checks this).
terraform {
  backend "s3" {
    bucket = "kijanikiosk-tfstate"
    key    = "week4/friday/terraform.tfstate"
    region = "us-east-1" # required by the S3 backend; MinIO ignores it

    endpoints = {
      s3 = "http://localhost:9000"
    }

    use_path_style              = true # MinIO uses http://host/bucket, not bucket.host
    skip_credentials_validation = true # no AWS STS behind MinIO
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_s3_checksum            = true # avoids checksum headers some MinIO builds reject

    # Lock file stored next to the state (S3-native locking, Terraform >= 1.10).
    # Relies on conditional writes; see hardening-decisions.md for the
    # MinIO locking limitation and how production handles it.
    use_lockfile = true
  }
}
