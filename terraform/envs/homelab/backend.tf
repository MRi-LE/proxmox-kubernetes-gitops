# terraform/envs/homelab/backend.tf
# Remote state stored in RustFS (S3-compatible) on TrueNAS.
#
# ── Why the S3 endpoint is not a Terraform variable ───────────────────────────
# Terraform resolves the backend block BEFORE input variables, so `var.x`
# inside a backend block is a hard error. The standard solution is
# -backend-config, which passes key=value pairs at `terraform init` time
# without hardcoding them here.
#
# The endpoint and bucket are passed via backend.hcl (local runs) or
# -backend-config flags (CI). See backend.hcl.example for the template.
#
# ── Credentials ───────────────────────────────────────────────────────────────
# Passed via environment variables — never hardcoded here:
#   AWS_ACCESS_KEY_ID     → RUSTFS_ACCESS_KEY Forgejo secret
#   AWS_SECRET_ACCESS_KEY → RUSTFS_SECRET_KEY Forgejo secret

terraform {
  backend "s3" {
    # bucket, key, region, and endpoints.s3 are supplied at init time via
    # -backend-config=backend.hcl (local) or -backend-config flags (CI).
    # See backend.hcl.example for the values to fill in.

    # Required for S3-compatible non-AWS backends (RustFS has no IAM/STS/metadata APIs)
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_s3_checksum            = true

    use_path_style = true
  }
}
