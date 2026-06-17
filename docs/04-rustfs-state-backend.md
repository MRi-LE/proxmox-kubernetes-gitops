# Chapter 04 — RustFS State Backend

**Goal:** Have the `terraform-state` S3 bucket created and verified so that
`terraform init` succeeds when the first workflow runs.

**You will learn:** Why Terraform needs remote state, how S3-compatible storage
works, and which flags are required for non-AWS S3 backends — and why they are
passed via `-backend-config` rather than hardcoded in `backend.tf`.

**Prerequisites:** [Chapter 03 — Proxmox Prep](03-proxmox-prep.md). RustFS must
be running on TrueNAS and reachable at `http://192.168.1.50:30293`.

**Where to run commands:**

| Step | Run on | How |
|---|---|---|
| Create bucket (web) | Browser | `http://192.168.1.50:30292/rustfs/console/` |
| Create bucket (`mc`) | Any machine on LAN | Install `mc`, configure alias |
| Smoke-test from runner | Runner LXC | SSH into LXC, run `curl` / `mc` |

---

This document covers creating and verifying the `terraform-state` bucket that
Terraform's S3 backend writes to. It must exist before `terraform init` can
succeed.

**Your RustFS instance**

| | Value |
|---|---|
| API endpoint | `http://192.168.1.50:30293` |
| Console URL | `http://192.168.1.50:30292` (port 9001 equivalent — check TrueNAS) |
| Required bucket | `terraform-state` |
| State key inside bucket | `k8s-infra/homelab/terraform.tfstate` |

> **Port note:** RustFS exposes the S3 API and the web console on separate
> ports. If your TrueNAS deployment used the defaults, the console is at
> `:9001` (or the equivalent mapped NodePort). Adjust if your setup differs.

---

## Option A — Web Console (quickest)

1. Open `http://192.168.1.50:30292/rustfs/console/` (or your console port)
   in a browser.

2. Log in with your `RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY` credentials
   (the same values stored in Forgejo Secrets).

3. Click **Create Bucket** in the top-left corner.

4. Enter the bucket name: `terraform-state`

5. Leave versioning off — Terraform manages its own state locking.

6. Click **Create**.

7. Verify: the bucket appears in the bucket list. Done.

---

## Option B — `mc` (MinIO Client)

`mc` is the recommended CLI for day-to-day RustFS management. It is
S3-compatible and works against RustFS without any changes.

### Install `mc`

```bash
curl -LO https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc
sudo mv mc /usr/local/bin/mc
mc --version
```

### Configure an alias for your RustFS instance

```bash
mc alias set rustfs \
  http://192.168.1.50:30293 \
  <RUSTFS_ACCESS_KEY> \
  <RUSTFS_SECRET_KEY>
```

Replace `<RUSTFS_ACCESS_KEY>` and `<RUSTFS_SECRET_KEY>` with the actual
values (these are the same values stored in Forgejo Secrets).

### Create the bucket

```bash
mc mb rustfs/terraform-state
```

Expected output:

```
Bucket created successfully `rustfs/terraform-state`.
```

### Verify

```bash
mc ls rustfs
```

You should see `terraform-state` in the list.

### Smoke-test: write and read an object

```bash
echo "ok" | mc pipe rustfs/terraform-state/probe.txt
mc cat rustfs/terraform-state/probe.txt
mc rm rustfs/terraform-state/probe.txt
```

All three should succeed cleanly. If they do, Terraform's backend will work.

---

## Option C — AWS CLI

Use this if you already have the AWS CLI installed and prefer it for scripting.

```bash
export AWS_ACCESS_KEY_ID=<RUSTFS_ACCESS_KEY>
export AWS_SECRET_ACCESS_KEY=<RUSTFS_SECRET_KEY>
export AWS_DEFAULT_REGION=us-east-1

aws s3 mb s3://terraform-state \
  --endpoint-url http://192.168.1.50:30293

aws s3 ls \
  --endpoint-url http://192.168.1.50:30293
```

---

## Verify Terraform can reach the backend

Run this from the runner LXC (or locally with the correct env vars) before
triggering any CI workflow. This confirms the bucket is reachable with the
credentials Terraform will use in CI.

```bash
export AWS_ACCESS_KEY_ID=<RUSTFS_ACCESS_KEY>
export AWS_SECRET_ACCESS_KEY=<RUSTFS_SECRET_KEY>

# Quick health check — should return HTTP 200 or 403 (not connection refused)
curl -I http://192.168.1.50:30293

# List bucket contents via AWS CLI (empty is fine, error is not)
aws s3 ls s3://terraform-state \
  --endpoint-url http://192.168.1.50:30293 \
  --region us-east-1
```

An empty listing (`(nothing returned)`) is correct for a fresh bucket.
A `NoSuchBucket` error means the bucket was not created. A connection error
means RustFS is unreachable from wherever you are running the command.

---

## Pre-flight checklist

- [ ] Console accessible at `http://192.168.1.50:<console-port>/rustfs/console/`
- [ ] `terraform-state` bucket exists (visible in console or `mc ls rustfs`)
- [ ] Smoke-test write/read/delete succeeds via `mc` or AWS CLI
- [ ] Runner LXC can reach `http://192.168.1.50:30293` (run the `curl -I`
      check from inside the LXC, not just from your workstation)
- [ ] Forgejo Secrets `RUSTFS_ACCESS_KEY` and `RUSTFS_SECRET_KEY` are set with
      the same credentials used above

---

## Troubleshooting

**`curl -I` returns connection refused**
RustFS is not listening on port 30293, or the TrueNAS NodePort mapping has
changed. Check the RustFS service in TrueNAS → Apps or `kubectl get svc -n
rustfs` if it runs in a K8s namespace.

**`mc alias set` succeeds but `mc mb` returns `Access Denied`**
The credentials you passed to `mc alias set` do not have write permission.
Confirm they match `RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY` exactly —
no trailing whitespace, no extra newline.

**`terraform init` still hits IAM/STS after fixing the backend config**
Confirm the updated `-backend-config` flags are being passed (workflows do this
automatically). For local runs, confirm `backend.hcl` exists and you are
running `terraform init -backend-config=backend.hcl`. Run with `-reconfigure`
to force re-initialisation: `terraform init -reconfigure -backend-config=backend.hcl`.

**`NoSuchBucket` from Terraform (not from `mc`)**
The bucket name passed via `-backend-config` must match exactly: `terraform-state`
(all lowercase, hyphen, no underscores). Check `backend.hcl` (local) or the
`-backend-config` flags in the workflow. RustFS enforces DNS-compliant bucket
naming.

---

## Checkpoint questions

1. What is stored in `terraform.tfstate`? What is NOT stored there?
2. Why does `backend.tf` need `skip_requesting_account_id = true`?
3. What does `use_path_style = true` change about how URLs are formed?
4. The smoke-test write succeeds but `terraform init` still fails with a checksum error. Which flag is missing?
5. You get `NoSuchBucket` from Terraform but `mc ls rustfs` shows the bucket. What is the most likely cause?

## Common mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| Bucket named `terraform_state` (underscore) | `NoSuchBucket` | Rename to `terraform-state` (hyphen) — RustFS enforces DNS-compliant naming |
| `skip_s3_checksum` omitted | Checksum validation error on `terraform init` | Add to `backend.tf` |
| Smoke-test run from workstation only, not runner LXC | CI fails even though local test passed | Re-run `curl -I http://192.168.1.50:30293` from inside the runner LXC |
| Console port wrong | Browser can't load RustFS UI | Check TrueNAS → Apps for the mapped NodePort |

---

*Previous: [Chapter 03 — Proxmox Prep](03-proxmox-prep.md) · Next: [Chapter 05 — Forgejo Runner](05-forgejo-runner.md)*
