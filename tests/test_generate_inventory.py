"""
tests/test_generate_inventory.py

Unit tests for ansible/scripts/generate_inventory.py.

Run with:
    python3 -m pytest tests/ -v

No external dependencies beyond pytest and pyyaml (both available on the runner).
"""

import json
import sys
from pathlib import Path

import pytest
import yaml

# Make the script importable without executing main()
sys.path.insert(0, str(Path(__file__).parent.parent / "ansible" / "scripts"))
from generate_inventory import build_inventory, load_tf_output


# ── Fixtures ──────────────────────────────────────────────────────────────────

FIXTURE_DIR = Path(__file__).parent / "fixtures"


def load_fixture(name: str) -> dict:
    """Load a terraform-output JSON fixture and parse it the same way the
    script does (strip the wrapping 'value' key)."""
    return load_tf_output(FIXTURE_DIR / name)


@pytest.fixture
def valid_tf():
    return load_fixture("terraform-output.json")


# ── Happy path ────────────────────────────────────────────────────────────────

def test_all_hosts_present(valid_tf):
    inv = build_inventory(valid_tf)
    hosts = inv["all"]["hosts"]
    assert "k8s-cp-01" in hosts
    assert "k8s-worker-01" in hosts
    assert "k8s-worker-02" in hosts


def test_host_has_required_fields(valid_tf):
    inv = build_inventory(valid_tf)
    cp = inv["all"]["hosts"]["k8s-cp-01"]
    assert cp["ansible_host"] == valid_tf["vm_ips"]["k8s-cp-01"]
    assert cp["ip"] == valid_tf["vm_ips"]["k8s-cp-01"]
    assert cp["access_ip"] == valid_tf["vm_ips"]["k8s-cp-01"]


def test_control_plane_group(valid_tf):
    inv = build_inventory(valid_tf)
    cp_hosts = inv["all"]["children"]["kube_control_plane"]["hosts"]
    assert "k8s-cp-01" in cp_hosts
    assert "k8s-worker-01" not in cp_hosts


def test_worker_group(valid_tf):
    inv = build_inventory(valid_tf)
    node_hosts = inv["all"]["children"]["kube_node"]["hosts"]
    assert "k8s-worker-01" in node_hosts
    assert "k8s-worker-02" in node_hosts
    assert "k8s-cp-01" not in node_hosts


def test_etcd_colocated_with_control_plane(valid_tf):
    inv = build_inventory(valid_tf)
    etcd_hosts = inv["all"]["children"]["etcd"]["hosts"]
    assert "k8s-cp-01" in etcd_hosts
    assert "k8s-worker-01" not in etcd_hosts


def test_k8s_cluster_has_both_children(valid_tf):
    inv = build_inventory(valid_tf)
    children = inv["all"]["children"]["k8s_cluster"]["children"]
    assert "kube_control_plane" in children
    assert "kube_node" in children


def test_calico_rr_is_empty(valid_tf):
    inv = build_inventory(valid_tf)
    assert inv["all"]["children"]["calico_rr"]["hosts"] == {}


def test_host_dicts_are_empty_dicts_not_null(valid_tf):
    """Kubespray expects {} not null for host entries in group lists."""
    inv = build_inventory(valid_tf)
    for group_name in ("kube_control_plane", "kube_node", "etcd"):
        for host, value in inv["all"]["children"][group_name]["hosts"].items():
            assert value == {}, (
                f"{group_name}/{host} should be {{}} not {value!r}"
            )


def test_output_is_valid_yaml(valid_tf, tmp_path):
    """Round-trip through yaml.dump/yaml.safe_load without errors."""
    inv = build_inventory(valid_tf)
    out = tmp_path / "hosts.yaml"
    out.write_text(yaml.dump(inv, default_flow_style=False, sort_keys=False))
    reloaded = yaml.safe_load(out.read_text())
    assert reloaded["all"]["hosts"]["k8s-cp-01"]["ansible_host"] == valid_tf["vm_ips"]["k8s-cp-01"]


# ── Error paths ───────────────────────────────────────────────────────────────

def test_missing_vm_ips_exits(tmp_path):
    bad = {"control_planes": ["k8s-cp-01"], "workers": ["k8s-worker-01"]}
    with pytest.raises(SystemExit) as exc:
        build_inventory(bad)
    assert exc.value.code != 0


def test_empty_vm_ips_exits():
    bad = {"vm_ips": {}, "control_planes": ["k8s-cp-01"], "workers": ["k8s-worker-01"]}
    with pytest.raises(SystemExit) as exc:
        build_inventory(bad)
    assert exc.value.code != 0


def test_missing_control_planes_exits():
    bad = {
        "vm_ips": {"k8s-cp-01": "192.168.1.201"},
        "workers": ["k8s-worker-01"],
    }
    with pytest.raises(SystemExit) as exc:
        build_inventory(bad)
    assert exc.value.code != 0


def test_missing_workers_exits():
    bad = {
        "vm_ips": {"k8s-cp-01": "192.168.1.201"},
        "control_planes": ["k8s-cp-01"],
    }
    with pytest.raises(SystemExit) as exc:
        build_inventory(bad)
    assert exc.value.code != 0


def test_group_member_missing_from_vm_ips_exits():
    """A host listed in control_planes but absent from vm_ips should fail."""
    bad = {
        "vm_ips": {"k8s-cp-01": "192.168.1.201"},
        "control_planes": ["k8s-cp-01", "k8s-cp-02"],  # k8s-cp-02 not in vm_ips
        "workers": ["k8s-worker-01"],
    }
    with pytest.raises(SystemExit) as exc:
        build_inventory(bad)
    assert exc.value.code != 0
