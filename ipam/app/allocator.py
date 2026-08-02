"""Site subnet allocator.

Takes a site's /19 supernet and carves it into one /23 per VLAN, for the
eight standard VLANs (10, 20, 30, 40, 50, 60, 70, 80). The VLAN's name is
its ID as a string, so VLAN 10 is named "10".

A /19 holds sixteen /23s. Eight of them are handed out, lowest first, and the
untouched top half is reported as reserve rather than silently dropped - a
site that later needs a ninth VLAN can take the next block without renumbering
anything that already exists.

    10.20.0.0/19  ->  VLAN 10  10.20.0.0/23
                      VLAN 20  10.20.2.0/23
                      VLAN 30  10.20.4.0/23
                      ...
                      VLAN 80  10.20.14.0/23
                      reserve  10.20.16.0/20

No Azure dependencies live in this module: it is pure address arithmetic so it
can be tested (and reasoned about) on its own.
"""

from __future__ import annotations

import ipaddress
import re
from dataclasses import asdict, dataclass

SUPERNET_PREFIX = 19
VLAN_PREFIX = 23
VLAN_IDS: tuple[int, ...] = (10, 20, 30, 40, 50, 60, 70, 80)

# 2-10 chars, starts alphanumeric, allows internal hyphens. Table Storage keys
# reject / \ # ? so the character set is deliberately narrow.
SITE_CODE_RE = re.compile(r"^[A-Z0-9][A-Z0-9-]{1,9}$")


class AllocationError(ValueError):
    """Input the caller can fix, phrased for display back to the user."""


@dataclass(frozen=True)
class VlanAllocation:
    """One VLAN's /23 and the addresses a network engineer needs from it."""

    vlan_id: int
    vlan_name: str
    cidr: str
    network_address: str
    netmask: str
    gateway: str
    first_host: str
    last_host: str
    broadcast: str
    usable_hosts: int

    def as_dict(self) -> dict:
        return asdict(self)


@dataclass(frozen=True)
class SiteAllocation:
    """The full plan for a site: every VLAN plus whatever is left over."""

    site_code: str
    supernet: str
    vlans: tuple[VlanAllocation, ...]
    reserve: tuple[str, ...]

    def as_dict(self) -> dict:
        return {
            "site_code": self.site_code,
            "supernet": self.supernet,
            "vlans": [v.as_dict() for v in self.vlans],
            "reserve": list(self.reserve),
        }


def normalise_site_code(site_code: str) -> str:
    """Uppercase and validate a site code, or raise AllocationError."""
    code = (site_code or "").strip().upper()
    if not code:
        raise AllocationError("Site code is required.")
    if not SITE_CODE_RE.match(code):
        raise AllocationError(
            f"Site code {code!r} is invalid. Use 2-10 characters: letters, "
            "digits and internal hyphens only (for example LON01 or NYC-DC)."
        )
    return code


def parse_supernet(supernet: str) -> ipaddress.IPv4Network:
    """Parse the site range, insisting on an aligned IPv4 /19."""
    text = (supernet or "").strip()
    if not text:
        raise AllocationError("Site range is required.")

    try:
        network = ipaddress.ip_network(text, strict=True)
    except ValueError as exc:
        # The most common mistake is an address inside the block rather than
        # the block itself (10.20.5.7/19). Say which network they meant.
        if "has host bits set" in str(exc):
            loose = ipaddress.ip_network(text, strict=False)
            raise AllocationError(
                f"{text} is not the start of a range. Did you mean {loose}?"
            ) from exc
        raise AllocationError(f"{text!r} is not a valid IPv4 CIDR range.") from exc

    if network.version != 4:
        raise AllocationError("Only IPv4 ranges are supported.")
    if network.prefixlen != SUPERNET_PREFIX:
        raise AllocationError(
            f"Site range must be a /{SUPERNET_PREFIX}, but {text} is a "
            f"/{network.prefixlen}. A /{SUPERNET_PREFIX} is the smallest block "
            f"that holds {len(VLAN_IDS)} x /{VLAN_PREFIX} VLANs with room to grow."
        )
    return network


def split_site(supernet: str, site_code: str) -> SiteAllocation:
    """Build the VLAN plan for one site.

    Raises AllocationError on anything the caller typed wrong.
    """
    code = normalise_site_code(site_code)
    network = parse_supernet(supernet)

    blocks = list(network.subnets(new_prefix=VLAN_PREFIX))
    vlans = tuple(
        _describe(vlan_id, block) for vlan_id, block in zip(VLAN_IDS, blocks)
    )

    # Collapse the unused tail into the fewest possible CIDRs, so the reserve
    # reads as "10.20.16.0/20" rather than eight consecutive /23s.
    reserve = tuple(
        str(net)
        for net in ipaddress.collapse_addresses(blocks[len(VLAN_IDS):])
    )

    return SiteAllocation(
        site_code=code,
        supernet=str(network),
        vlans=vlans,
        reserve=reserve,
    )


def _describe(vlan_id: int, block: ipaddress.IPv4Network) -> VlanAllocation:
    """Describe a single VLAN block.

    Convention: the gateway takes the first usable address, so the assignable
    host pool starts one above it.
    """
    hosts = list(block.hosts())
    gateway = hosts[0]
    return VlanAllocation(
        vlan_id=vlan_id,
        vlan_name=str(vlan_id),
        cidr=str(block),
        network_address=str(block.network_address),
        netmask=str(block.netmask),
        gateway=str(gateway),
        first_host=str(hosts[1]),
        last_host=str(hosts[-1]),
        broadcast=str(block.broadcast_address),
        usable_hosts=len(hosts),
    )


CSV_COLUMNS = (
    "site_code",
    "vlan_id",
    "vlan_name",
    "cidr",
    "network_address",
    "netmask",
    "gateway",
    "first_host",
    "last_host",
    "broadcast",
    "usable_hosts",
)
