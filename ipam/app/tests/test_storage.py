"""Storage logic that doesn't need Azure: key mapping and the overlap guard."""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from allocator import split_site  # noqa: E402
from storage import RangeOverlap, TableStore, _pascal, _snake  # noqa: E402


@pytest.mark.parametrize(
    "snake,pascal",
    [
        ("vlan_id", "VlanId"),
        ("cidr", "Cidr"),
        ("network_address", "NetworkAddress"),
        ("usable_hosts", "UsableHosts"),
    ],
)
def test_property_names_round_trip(snake, pascal):
    assert _pascal(snake) == pascal
    assert _snake(pascal) == snake


def test_every_vlan_field_survives_the_round_trip():
    vlan = split_site("10.20.0.0/19", "LON01").vlans[0].as_dict()
    stored = {_pascal(k): v for k, v in vlan.items()}
    assert {_snake(k): v for k, v in stored.items()} == vlan


def _store_with_sites(sites):
    store = TableStore(account="dummy")
    store.list_sites = lambda: sites  # type: ignore[method-assign]
    return store


def test_reusing_another_sites_range_is_rejected():
    store = _store_with_sites(
        [{"site_code": "LON01", "supernet": "10.20.0.0/19"}]
    )
    with pytest.raises(RangeOverlap, match="LON01"):
        store._check_no_overlap(split_site("10.20.0.0/19", "LON02"))


def test_neighbouring_range_is_allowed():
    store = _store_with_sites(
        [{"site_code": "LON01", "supernet": "10.20.0.0/19"}]
    )
    store._check_no_overlap(split_site("10.20.32.0/19", "LON02"))


def test_a_site_does_not_overlap_itself():
    store = _store_with_sites(
        [{"site_code": "LON01", "supernet": "10.20.0.0/19"}]
    )
    store._check_no_overlap(split_site("10.20.0.0/19", "LON01"))


def test_endpoint_is_derived_from_the_account_name():
    assert (
        TableStore(account="ipamstore1").endpoint
        == "https://ipamstore1.table.core.windows.net"
    )


def test_no_account_means_not_configured():
    assert not TableStore(account="").configured
