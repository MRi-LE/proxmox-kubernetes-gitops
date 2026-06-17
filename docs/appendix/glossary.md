# Appendix — Glossary

Definitions for every term used in this lab. If you encounter something
not listed here, it probably belongs in this glossary — open a PR.

---

## A

**Ansible**
A configuration management and automation tool. It connects to machines via SSH
and runs tasks described in YAML files called *playbooks*. In this lab, Ansible
runs after Terraform to install Kubernetes on the VMs.

**Artifact (CI/CD)**
A file saved at the end of a CI workflow run so it can be downloaded later.
In Forgejo, artifacts appear at the bottom of a workflow run page. This lab
uses one artifact: `kubeconfig-homelab`, containing the cluster's admin
kubeconfig.

**Authorized_keys**
A file at `~/.ssh/authorized_keys` on a Linux machine. Each line is a public
SSH key. Anyone who holds the matching private key can SSH in as that user.

---

## B

**Backend (Terraform)**
Where Terraform stores its state file. In this lab the backend is S3-compatible
storage on RustFS (`http://192.168.1.50:30293`, bucket `terraform-state`).
Without a backend, state lives only on the machine that ran `terraform apply`,
which breaks CI.

**bpg/proxmox** (Terraform provider)
The community Terraform provider for Proxmox VE, maintained by BPG Labs.
It exposes Proxmox objects — VMs, templates, cloud images, disks, network
interfaces — as Terraform resources. The provider uses two access methods: the
Proxmox API (for normal operations) and SSH to the Proxmox host (for disk
import and template conversion). This is why both an API token and a dedicated
SSH keypair are required.

Official documentation:
[Terraform Registry](https://registry.terraform.io/providers/bpg/proxmox/latest/docs) ·
[GitHub source](https://github.com/bpg/terraform-provider-proxmox) ·
[bpg.github.io/terraform-provider-proxmox](https://bpg.github.io/terraform-provider-proxmox/)

---

## C

**Calico**
The Container Network Interface (CNI) plugin used in this cluster. Calico
assigns IP addresses to pods and routes traffic between them across nodes using
BGP or IPIP tunnelling. This lab uses IPIP Always mode.

**Cloud-init**
A standard mechanism for configuring a Linux VM on first boot. The VM reads
configuration from a virtual data source (in Proxmox's case, an ISO attached
at boot time). Cloud-init can set hostnames, create users, inject SSH keys,
configure networks, and run arbitrary commands. In this lab it sets the static
IP, injects the `ANSIBLE_SSH_PUBLIC_KEY`, and creates the `ubuntu` user.

**CNI (Container Network Interface)**
A specification for how Kubernetes networking plugins should work. CNI plugins
are responsible for: giving each pod an IP address, ensuring pods on different
nodes can reach each other, and implementing NetworkPolicy rules. See: Calico.

**containerd**
The container runtime used in this cluster. It is responsible for pulling
container images and running containers. Kubernetes talks to containerd via the
CRI (Container Runtime Interface). Since Kubernetes 1.24, Docker is no longer
required or used.

**Control Plane**
The set of Kubernetes components that make cluster-wide decisions — scheduling,
replication, etc. In this lab, all control plane components (API server,
etcd, controller manager, scheduler) run on `k8s-cp-01` (VM 201).

**CRI (Container Runtime Interface)**
The interface Kubernetes uses to talk to a container runtime (like containerd).
You rarely interact with this directly.

---

## E

**etcd**
The distributed key-value store where Kubernetes keeps all of its state —
every Pod, Deployment, ConfigMap, Secret, and so on. In this lab etcd is
co-located with the control plane on `k8s-cp-01`. In an HA setup, etcd would
run across multiple nodes.

---

## F

**Forgejo**
A self-hosted Git forge (similar to GitHub or GitLab). Forgejo hosts the
`k8s-infra` repository and runs the CI/CD workflows via Forgejo Actions.
In this lab it runs on TrueNAS.

**Forgejo Actions**
The CI/CD system built into Forgejo. Workflow files live in
`.forgejo/workflows/` and use the same syntax as GitHub Actions.

**Forgejo Runner**
The agent that picks up and executes workflow jobs. In this lab the runner is
a Rocky Linux LXC (`forgejo-runner-infra`) with the label `proxmox-infra:host`.
The `:host` suffix means jobs run directly on the LXC, not in a container.

---

## G

**GitOps**
A practice where infrastructure state is defined in a git repository and
changes are made by updating that repository, not by running ad-hoc commands.
In this lab, all VM changes go through Terraform via Forgejo CI, and all
Kubernetes changes go through Ansible via Forgejo CI.

---

## H

**HCL (HashiCorp Configuration Language)**
The human-readable configuration language used by Terraform. All `.tf` files
in this project are written in HCL and describe the desired Proxmox
infrastructure: providers, variables, modules, VMs, and outputs.

**Helm**
A package manager for Kubernetes. It packages Kubernetes manifests as
*charts* that can be installed, upgraded, and uninstalled as a unit.
Enabled in this cluster (`helm_enabled: true`) for future use.

**Heredoc**
A shell syntax for writing multi-line strings inline. `<<EOT` starts a heredoc;
the next line starting with exactly `EOT` ends it. `<<-EOT` (with hyphen) strips
leading tabs — which causes problems if the private key content is indented.
In this lab all heredocs use `<<EOT` without the hyphen.

---

## I

**IPIP (IP-in-IP)**
A tunnelling mode used by Calico. When `calico_ipip_mode: Always`, all pod-to-pod
traffic across nodes is encapsulated inside IP packets. Required on flat L2
networks (like this homelab's `192.168.1.x` segment) where BGP routing is
not configured between nodes.

---

## K

**kubeadm**
The tool Kubernetes uses to bootstrap a cluster: initialising the control plane,
generating certificates, and joining worker nodes. Kubespray uses kubeadm
internally — you don't call it directly.

**kubectl**
The command-line tool for talking to a Kubernetes cluster. It sends API requests
to the cluster's API server. In this lab kubectl is installed on LXC-Rocky10.

**kubelet**
A daemon that runs on every Kubernetes node. It watches the API server for pods
that should run on its node and manages their lifecycle. If kubelet stops, the
node becomes NotReady.

**kubeconfig**
A YAML file that tells kubectl where the cluster is, how to authenticate, and
which cluster context to use by default. In this lab the kubeconfig for the
homelab cluster lives at `~/.kube/homelab.yaml` on LXC-Rocky10 after setup.

**Kubespray**
A collection of Ansible playbooks that install Kubernetes using kubeadm.
It handles the entire installation: containerd, kubeadm, etcd, CNI, and addons.
This lab uses Kubespray v2.26.0, cloned at runtime during the deploy workflow.

---

## L

**LXC (Linux Container)**
A lightweight OS-level virtualisation technology. Unlike a VM, an LXC container
shares the host kernel. In this lab two LXCs run on the Proxmox host:
`forgejo-runner-infra` (the CI runner) and `LXC-Rocky10` (the kubectl admin host).

---

## M

**Metrics Server**
A Kubernetes addon that collects resource usage (CPU, memory) from kubelets and
exposes them via the Metrics API. Enables `kubectl top nodes` and
`kubectl top pods`. Enabled in this cluster (`metrics_server_enabled: true`).

---

## P

**Proxmox VE**
The bare-metal hypervisor running on the homelab server. It manages VMs and LXC
containers. Terraform talks to the Proxmox API to create and configure VMs.

**PersistentVolumeClaim (PVC)**
A Kubernetes object that requests a piece of storage. When a PVC is created,
Kubernetes finds or creates a matching PersistentVolume (PV) — a real piece of
storage, such as an NFS directory. This lab has no storage class yet (Chapter 12).

---

## R

**RustFS**
An S3-compatible object storage server, similar to MinIO. In this lab it runs
on TrueNAS Scale and hosts the `terraform-state` bucket. The Terraform backend
talks to it using the S3 API.

**Runner label**
A tag attached to a Forgejo runner that workflow jobs use to select which runner
picks them up. This lab uses `proxmox-infra:host`. A workflow with
`runs-on: [proxmox-infra]` will only run on runners that have that label.

---

## S

**S3 (Simple Storage Service)**
Amazon's object storage API. Because S3 became the de facto standard for object
storage, many tools (including Terraform's backend) support S3-compatible APIs.
RustFS implements the S3 API, so Terraform can use it as if it were AWS S3.

**SSH keypair**
A pair of cryptographic keys: a private key (kept secret, never shared) and a
public key (safe to distribute). Anyone with the public key can verify that
the private key holder signed something; anyone who accepts the public key
grants access to the private key holder. This lab uses two keypairs:
`k8s_proxmox` (for the Proxmox host) and `k8s_ansible` (for the K8s VMs).

**State (Terraform)**
A JSON file (`terraform.tfstate`) that records every resource Terraform has
created and their current configuration. Terraform uses this to calculate what
changes an `apply` would make. Without state, Terraform cannot determine
whether a resource already exists.

---

## T

**Terraform**
An infrastructure-as-code tool that provisions and manages cloud and on-premises
resources. You describe what you want in HCL files; Terraform figures out how to
create or update resources to match. In this lab Terraform creates the Proxmox
VMs.

**Terraform provider**
A plugin that teaches Terraform how to talk to a specific platform or API.
Providers are downloaded automatically by `terraform init` and expose
platform-specific objects as Terraform *resources* and *data sources*. This
lab uses the `bpg/proxmox` provider to manage Proxmox VE. Without a provider,
Terraform has no way to create or manage infrastructure on any platform.

**template VM (VM 9000)**
A Proxmox VM used as a source for cloning. The template is created from the
Ubuntu 24.04 cloud image and configured with cloud-init support. VMs 201, 202,
and 203 are full clones of VM 9000.

**tfvars (terraform.tfvars)**
A file that supplies concrete values for Terraform's declared variables. Never
committed to git in this lab — it would contain secrets. Values are instead
passed via Forgejo Variables (non-sensitive) and Forgejo Secrets (sensitive).

---

## V

**VM (Virtual Machine)**
A software emulation of a physical computer, running inside a hypervisor
(Proxmox in this lab). Unlike an LXC, a VM has its own kernel. The three
Kubernetes nodes in this lab are VMs (201, 202, 203).

---

## W

**workflow_dispatch**
A Forgejo/GitHub Actions trigger that requires a human to manually start the
workflow from the UI. Used in this lab for `terraform-apply` and
`ansible-deploy` to prevent accidental infrastructure changes.

---

*Back to: [Lab Overview](../00-lab-overview.md)*
