"""Tests for the pure address arithmetic. No Azure needed: python -m pytest"""

import ipaddress
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from allocator import (  # noqa: E402
    VLAN_IDS,
    AllocationError,
    normalise_site_code,
    split_site,
)


def test_splits_into_eight_vlans():
    result = split_site("10.20.0.0/19", "LON01")

    assert [v.vlan_id for v in result.vlans] == [10, 20, 30, 40, 50, 60, 70, 80]
    assert [v.cidr for v in result.vlans] == [
        "10.20.0.0/23",
        "10.20.2.0/23",
        "10.20.4.0/23",
        "10.20.6.0/23",
        "10.20.8.0/23",
        "10.20.10.0/23",
        "10.20.12.0/23",
        "10.20.14.0/23",
    ]


def test_vlan_name_matches_vlan_id():
    for vlan in split_site("10.20.0.0/19", "LON01").vlans:
        assert vlan.vlan_name == str(vlan.vlan_id)


def test_vlan_details():
    first = split_site("10.20.0.0/19", "LON01").vlans[0]

    assert first.network_address == "10.20.0.0"
    assert first.netmask == "255.255.254.0"
    assert first.gateway == "10.20.0.1"
    assert first.first_host == "10.20.0.2"
    assert first.last_host == "10.20.1.254"
    assert first.broadcast == "10.20.1.255"
    assert first.usable_hosts == 510


def test_unused_half_is_reported_as_one_collapsed_reserve_block():
    assert split_site("10.20.0.0/19", "LON01").reserve == ("10.20.16.0/20",)


def test_vlans_and_reserve_exactly_cover_the_supernet_without_overlap():
    result = split_site("172.16.32.0/19", "NYC-DC")

    blocks = [ipaddress.ip_network(v.cidr) for v in result.vlans]
    blocks += [ipaddress.ip_network(r) for r in result.reserve]

    covered = sum(block.num_addresses for block in blocks)
    assert covered == ipaddress.ip_network(result.supernet).num_addresses

    for i, a in enumerate(blocks):
        for b in blocks[i + 1:]:
            assert not a.overlaps(b)


@pytest.mark.parametrize(
    "supernet", ["10.20.0.0/19", "172.16.32.0/19", "192.168.0.0/19"]
)
def test_all_vlans_sit_inside_the_supernet(supernet):
    result = split_site(supernet, "SITE1")
    parent = ipaddress.ip_network(supernet)
    for vlan in result.vlans:
        assert ipaddress.ip_network(vlan.cidr).subnet_of(parent)


def test_site_code_is_uppercased():
    assert split_site("10.20.0.0/19", " lon01 ").site_code == "LON01"


@pytest.mark.parametrize("code", ["", "X", "TOOLONGSITECODE", "BAD/CODE", "-LON"])
def test_bad_site_codes_rejected(code):
    with pytest.raises(AllocationError):
        normalise_site_code(code)


def test_wrong_prefix_rejected():
    with pytest.raises(AllocationError, match="must be a /19"):
        split_site("10.20.0.0/16", "LON01")


def test_unaligned_range_suggests_the_real_network():
    with pytest.raises(AllocationError, match=r"Did you mean 10\.20\.0\.0/19\?"):
        split_site("10.20.5.7/19", "LON01")


def test_garbage_range_rejected():
    with pytest.raises(AllocationError, match="not a valid IPv4 CIDR"):
        split_site("not-an-ip", "LON01")


def test_ipv6_rejected():
    with pytest.raises(AllocationError):
        split_site("2001:db8::/19", "LON01")


def test_vlan_ids_are_the_eight_standard_vlans():
    assert VLAN_IDS == (10, 20, 30, 40, 50, 60, 70, 80)
