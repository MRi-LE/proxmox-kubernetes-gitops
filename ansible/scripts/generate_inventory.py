#!/usr/bin/env python3
"""
generate_inventory.py
Converts `terraform output -json` into a Kubespray-compatible hosts.yaml.

Usage:
    terraform -chdir=terraform/envs/homelab output -json \
        > ansible/inventory/generated/terraform-output.json

    python3 ansible/scripts/generate_inventory.py \
        --tf-output  ansible/inventory/generated/terraform-output.json \
        --out        ansible/inventory/generated/hosts.yaml

Expected Terraform output keys (see terraform/envs/homelab/outputs.tf):
    vm_ips         = { "k8s-cp-01" = "192.168.1.201", ... }   [map]
    control_planes = [ "k8s-cp-01" ]                           [list]
    workers        = [ "k8s-worker-01", "k8s-worker-02" ]     [list]
    ansible_ssh_user = "ubuntu"                                [string]

Generated file is .gitignored — never commit it.
"""

import argparse
import json
import sys
from pathlib import Path

import yaml


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="TF output → Kubespray hosts.yaml")
    p.add_argument("--tf-output", required=True, type=Path,
                   help="Path to terraform output -json file")
    p.add_argument("--out", required=True, type=Path,
                   help="Destination hosts.yaml path")
    return p.parse_args()


def load_tf_output(path: Path) -> dict:
    with path.open() as fh:
        raw = json.load(fh)
    return {k: v["value"] for k, v in raw.items()}


def build_inventory(tf: dict) -> dict:
    vm_ips: dict         = tf.get("vm_ips", {})
    control_planes: list = tf.get("control_planes", [])
    workers: list        = tf.get("workers", [])
    ssh_user: str        = tf.get("ansible_ssh_user", "ubuntu")

    if not vm_ips:
        print("ERROR: 'vm_ips' missing or empty in Terraform output.", file=sys.stderr)
        sys.exit(1)

    if not control_planes:
        print("ERROR: 'control_planes' missing or empty in Terraform output.", file=sys.stderr)
        sys.exit(1)

    if not workers:
        print("ERROR: 'workers' missing or empty in Terraform output.", file=sys.stderr)
        sys.exit(1)

    # Verify every group member has a corresponding entry in vm_ips
    all_named = set(control_planes) | set(workers)
    missing = all_named - set(vm_ips)
    if missing:
        print(
            f"ERROR: hosts {sorted(missing)} appear in groups but are missing from vm_ips.",
            file=sys.stderr,
        )
        sys.exit(1)

    all_hosts: dict = {}
    for name, ip in vm_ips.items():
        all_hosts[name] = {
            "ansible_host": ip,
            "ansible_user": ssh_user,
            "ip":           ip,
            "access_ip":    ip,
        }

    return {
        "all": {
            "hosts": all_hosts,
            "children": {
                "kube_control_plane": {"hosts": {h: {} for h in control_planes}},
                "kube_node":          {"hosts": {h: {} for h in workers}},
                "etcd":               {"hosts": {h: {} for h in control_planes}},
                "k8s_cluster": {
                    "children": {
                        "kube_control_plane": {},
                        "kube_node": {},
                    }
                },
                "calico_rr": {"hosts": {}},
            },
        }
    }


def main() -> None:
    args = parse_args()

    if not args.tf_output.exists():
        print(f"ERROR: {args.tf_output} not found.", file=sys.stderr)
        sys.exit(1)

    tf = load_tf_output(args.tf_output)
    inventory = build_inventory(tf)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w") as fh:
        yaml.dump(inventory, fh, default_flow_style=False, sort_keys=False)

    print(f"Inventory written → {args.out}")


if __name__ == "__main__":
    main()
