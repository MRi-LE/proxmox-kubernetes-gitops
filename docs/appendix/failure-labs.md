# Appendix — Failure Labs

Intentional break/fix exercises. Each one walks you through breaking something
deliberately, diagnosing it using only the tools and knowledge in this book,
and fixing it — without looking at the answer until you've tried.

**Before starting any exercise:** make sure your cluster is healthy.

```bash
kubectl get nodes    # all Ready
kubectl get pods -A  # all Running or Completed
```

**Take a Proxmox snapshot before exercises that touch VMs or Kubernetes config.**
Forgejo → Actions is your "undo" button for workflows; Proxmox snapshots are
your undo button for VMs.

---

## Lab 1 — Wrong Proxmox API Token

**What you learn:** How the Proxmox API returns errors, how Terraform surfaces
them, and the difference between a 401 (unauthenticated) and a 403 (authorised
but insufficient permissions).

**Setup (break it):**

In Forgejo → Repository → Settings → Secrets, edit `PROXMOX_VE_API_TOKEN`.
Change any digit in the UUID portion, e.g. change `abc123` to `abc124`.
Save it.

**Trigger the failure:**

Open a PR (any trivial change) to trigger `terraform-plan`.

**Diagnose without looking at the answer:**

1. What does the Forgejo Actions log say?
2. What HTTP status code is returned?
3. Is it a 401 or a 403? What is the difference?
4. How does Terraform's error message differ from a network timeout?

**Fix it:**

Restore the correct token value in Forgejo Secrets. Trigger the plan again.

**Answer — what you should have seen:**

The `bpg/proxmox` provider will log something like:

```
Error: Error while fetching version - HTTP 401
```

A 401 means the token is not recognised at all (wrong UUID). A 403 would mean
the token exists but the `TerraformCI` role doesn't cover the requested
operation. 401 = wrong identity; 403 = wrong permissions.

---

## Lab 2 — Missing Proxmox SSH Key

**What you learn:** How the `bpg/proxmox` provider uses SSH separately from the
API, which operations require SSH, and what the error looks like when it fails.

**Setup (break it):**

In Forgejo Secrets, edit `PROXMOX_SSH_PRIVATE_KEY`. Replace the entire key
content with the text `not-a-real-key`.

**Trigger the failure:**

Trigger `terraform-apply` with `terraform_action = apply` against an existing
deployment (the plan should show `No changes` — the apply will still attempt
to refresh state, which uses SSH).

**Diagnose without looking at the answer:**

1. At which step does the workflow fail?
2. Does it fail during `terraform init`, `terraform plan`, or `terraform apply`?
3. What does the error say?

**Fix it:**

Restore the correct private key. Re-trigger the workflow.

**Answer — what you should have seen:**

The `bpg/proxmox` provider uses SSH for disk import and some VM operations.
The error during apply typically looks like:

```
Error: could not connect to the Proxmox host via SSH:
ssh: handshake failed: ssh: unable to authenticate, attempted methods [none publickey]
```

Note: a plan may succeed even with a bad SSH key if no SSH-requiring operations
are needed for that plan. The SSH key is only used for certain provider calls.

---

## Lab 3 — Wrong Runner Label

**What you learn:** How runner label matching works, what "Waiting" means, and
how to verify a runner's configuration from inside its LXC.

**Setup (break it):**

SSH into the runner LXC. Edit `/home/forgejo-runner/runner-config.yml` and
change the label from `proxmox-infra:host` to `proxmox-infra-typo:host`.
Restart the runner:

```bash
systemctl restart forgejo-runner
```

**Trigger the failure:**

Push a commit to any branch to trigger `validate.yml` (which runs on PR events).
Or open a PR.

**Diagnose without looking at the answer:**

1. Open the workflow run in Forgejo. What status does it show?
2. How long does it wait before failing? (Forgejo has a default pickup timeout.)
3. How do you confirm from inside the runner LXC that the label changed?

**Fix it:**

```bash
# Restore the correct label
vim /home/forgejo-runner/runner-config.yml
# Change back to: - "proxmox-infra:host"
systemctl restart forgejo-runner
```

**Answer — what you should have seen:**

The job stays in `Waiting` state indefinitely — no runner with the label
`proxmox-infra-typo` exists. After Forgejo's timeout (usually 5–10 minutes)
it fails with `No runner available`. To confirm from inside the LXC:

```bash
cat /home/forgejo-runner/runner-config.yml | grep labels -A5
journalctl -u forgejo-runner -n 20
```

The runner log shows it's connected to Forgejo, but it only picks up jobs
that match its labels.

---

## Lab 4 — Missing RustFS Bucket

**What you learn:** How Terraform's backend initialisation fails, what the S3
error looks like for a missing bucket vs wrong credentials, and why the backend
must be set up before any workflow can run.

**Setup (break it):**

Log into the RustFS console (`http://192.168.1.50:30292`). Rename the
`terraform-state` bucket to `terraform-state-backup` (or temporarily delete it
if your console allows).

**Trigger the failure:**

Trigger `terraform-plan` (open a PR).

**Diagnose without looking at the answer:**

1. At which exact step does the workflow fail?
2. What error does `terraform init` print?
3. Is the error different from what you'd get with wrong credentials?

**Fix it:**

Recreate the bucket with the exact name `terraform-state`. Trigger the plan again.

**Answer — what you should have seen:**

`terraform init` fails with something like:

```
Error: Failed to get existing workspaces: S3 bucket does not exist.
```

With wrong credentials the error is instead about access denied:

```
Error: error using credentials to get account ID:
operation error STS: GetCallerIdentity: ... InvalidClientTokenId
```

Missing bucket = `NoSuchBucket`. Wrong credentials = auth error. These are
distinct and lead to different fixes.

---

## Lab 5 — Old Kubeconfig After Rebuild

**What you learn:** Why cluster certificates are tied to the cluster lifecycle,
what the error looks like when a cert no longer matches, and where to get the
new kubeconfig.

**Setup (break it):**

You don't need to break anything deliberately. This lab simulates what happens
after a cluster rebuild.

Rename your working kubeconfig:
```bash
# On LXC-Rocky10
mv ~/.kube/homelab.yaml ~/.kube/homelab.yaml.old
```

Then create a fake one that has a wrong certificate embedded:
```bash
cp ~/.kube/homelab.yaml.old ~/.kube/homelab.yaml
# Edit the server to point somewhere that won't respond correctly
sed -i 's|https://192.168.1.201:6443|https://192.168.1.201:9999|' ~/.kube/homelab.yaml
```

**Trigger the failure:**

```bash
kubectl get nodes
```

**Diagnose without looking at the answer:**

1. What error do you see?
2. How is `Connection refused` different from `certificate signed by unknown authority`?
3. Where do you get a fresh, correct kubeconfig?

**Fix it:**

```bash
# Option A: download the latest artifact from ansible-deploy workflow run
# Then:
mv ~/Downloads/homelab.yaml ~/.kube/homelab.yaml

# Option B: restore the backup
mv ~/.kube/homelab.yaml.old ~/.kube/homelab.yaml
```

**Answer — what you should have seen:**

Port 9999 gives `Connection refused` immediately — nothing is listening.
After a real cluster rebuild you'd instead see `x509: certificate signed by
unknown authority` (or `certificate has expired or is not yet valid`) — the
cluster issued new certs the old kubeconfig doesn't know about. The fix is
always to download the fresh kubeconfig artifact from the latest
`ansible-deploy` run.

---

## Lab 6 — Node NotReady (simulated kubelet stop)

**What you learn:** How to diagnose a NotReady node using kubectl and SSH, the
difference between a crashed kubelet and a network partition, and how to recover.

**Setup (break it):**

SSH into `k8s-worker-01`:

```bash
ssh -i ~/.ssh/k8s_ansible ubuntu@192.168.1.202
sudo systemctl stop kubelet
```

Wait 60 seconds.

**Diagnose without looking at the answer:**

1. What does `kubectl get nodes` show?
2. What does `kubectl describe node k8s-worker-01` show in the Conditions section?
3. Are pods on `k8s-worker-01` still running or evicted?
4. How long does Kubernetes wait before evicting pods from a NotReady node?

**Fix it:**

```bash
# On k8s-worker-01:
sudo systemctl start kubelet
sudo systemctl status kubelet
```

```bash
# On LXC-Rocky10, watch until Ready:
kubectl get nodes -w
```

**Answer — what you should have seen:**

After ~60 seconds, `kubectl get nodes` shows `k8s-worker-01` as `NotReady`.
`kubectl describe node k8s-worker-01` shows `Ready: False` with the reason
`KubeletStopped: kubelet stopped posting node status`. Pods on the node are
not immediately evicted — by default Kubernetes waits 5 minutes
(`pod-eviction-timeout`) before evicting pods from a NotReady node.
Restarting kubelet brings the node back to Ready within ~30 seconds, and
no pods need rescheduling.

---

## Lab 7 — Stale Kubeconfig Server IP

**What you learn:** How to manually patch a kubeconfig file, and why `post-k8s.yml`
does this automatically.

**Setup (break it):**

```bash
# On LXC-Rocky10
cp ~/.kube/homelab.yaml ~/.kube/homelab.yaml.backup
sed -i 's|https://192.168.1.201:6443|https://127.0.0.1:6443|' ~/.kube/homelab.yaml
```

**Trigger the failure:**

```bash
kubectl get nodes
```

**Diagnose:**

1. What error do you see?
2. Why would `127.0.0.1:6443` appear in a real kubeconfig (hint: where does Kubespray initially configure it)?

**Fix it:**

```bash
sed -i 's|https://127.0.0.1:6443|https://192.168.1.201:6443|' ~/.kube/homelab.yaml
kubectl get nodes
```

**Answer — what you should have seen:**

`Connection refused` — nothing listens on port 6443 of localhost (LXC-Rocky10).
The raw `admin.conf` on the control plane has `server: https://127.0.0.1:6443`
because from the control plane's perspective, the API server is on localhost.
`post-k8s.yml` patches it to the LAN IP so external clients can reach it.

---

*Back to: [Lab Overview](../00-lab-overview.md)*
