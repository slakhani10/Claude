"""Persistence for site allocations, in Azure Table Storage.

Two tables:

  sites  PartitionKey "SITE", RowKey <site code>  - one row per site, holding
         the /19 it was given. Small enough to scan, which is what makes the
         overlap check cheap.

  vlans  PartitionKey <site code>, RowKey "010".."080" - one row per VLAN.
         Partitioned by site so reading a site back is a single partition query.

Authentication is Entra ID only (DefaultAzureCredential). On App Service that
resolves to the web app's system-assigned managed identity, which Terraform
grants "Storage Table Data Contributor" - so there is no key or connection
string anywhere in the app, its settings, or this repo.

The tables are created on first use rather than by Terraform: the storage
account sits behind a private endpoint with shared keys disabled, so the
data plane is reachable from the web app but not from wherever Terraform runs.
"""

from __future__ import annotations

import ipaddress
import os
from datetime import datetime, timezone
from functools import cached_property

from azure.core.exceptions import (
    ClientAuthenticationError,
    HttpResponseError,
    ResourceExistsError,
    ResourceNotFoundError,
)
from azure.data.tables import TableServiceClient
from azure.identity import DefaultAzureCredential

from allocator import SiteAllocation

SITES_PARTITION = "SITE"


class StorageError(RuntimeError):
    """Something went wrong talking to storage; message is user-facing."""


class StorageNotConfigured(StorageError):
    """No storage account configured - preview works, saving does not."""


class SiteExists(StorageError):
    """A site with this code already has an allocation."""


class RangeOverlap(StorageError):
    """The requested /19 overlaps a range already handed to another site."""


class TableStore:
    def __init__(
        self,
        account: str | None = None,
        endpoint: str | None = None,
        sites_table: str | None = None,
        vlans_table: str | None = None,
    ) -> None:
        account = account or os.environ.get("IPAM_STORAGE_ACCOUNT", "")
        self.endpoint = endpoint or os.environ.get("IPAM_TABLE_ENDPOINT") or (
            f"https://{account}.table.core.windows.net" if account else ""
        )
        self.sites_table = sites_table or os.environ.get("IPAM_SITES_TABLE", "sites")
        self.vlans_table = vlans_table or os.environ.get("IPAM_VLANS_TABLE", "vlans")

    @property
    def configured(self) -> bool:
        return bool(self.endpoint)

    # ------------------------------------------------------------ internals
    @cached_property
    def _service(self) -> TableServiceClient:
        if not self.configured:
            raise StorageNotConfigured(
                "No storage account is configured. Set IPAM_STORAGE_ACCOUNT "
                "(App Service sets this from Terraform) to enable saving."
            )
        return TableServiceClient(
            endpoint=self.endpoint, credential=DefaultAzureCredential()
        )

    def _table(self, name: str):
        """Get a table client, creating the table the first time we need it."""
        client = self._service.get_table_client(name)
        try:
            client.create_table()
        except ResourceExistsError:
            pass
        return client

    # --------------------------------------------------------------- writes
    def save(self, allocation: SiteAllocation, created_by: str = "") -> None:
        """Persist a site plan.

        Raises SiteExists if the code is taken, RangeOverlap if the /19
        collides with another site's range.
        """
        try:
            self._check_no_overlap(allocation)

            sites = self._table(self.sites_table)
            entity = {
                "PartitionKey": SITES_PARTITION,
                "RowKey": allocation.site_code,
                "Supernet": allocation.supernet,
                "VlanCount": len(allocation.vlans),
                "Reserve": ",".join(allocation.reserve),
                "CreatedUtc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "CreatedBy": created_by or "unknown",
            }
            try:
                # create (not upsert): the 409 is our guard against two people
                # allocating the same site code at once.
                sites.create_entity(entity)
            except ResourceExistsError as exc:
                raise SiteExists(
                    f"Site {allocation.site_code} already has an allocation. "
                    "Delete it first if you need to re-issue its ranges."
                ) from exc

            vlan_table = self._table(self.vlans_table)
            for vlan in allocation.vlans:
                record = vlan.as_dict()
                vlan_table.upsert_entity(
                    {
                        "PartitionKey": allocation.site_code,
                        "RowKey": f"{vlan.vlan_id:03d}",
                        "Supernet": allocation.supernet,
                        **{_pascal(k): v for k, v in record.items()},
                    }
                )
        except StorageError:
            raise
        except (ClientAuthenticationError, HttpResponseError) as exc:
            raise StorageError(_explain(exc)) from exc

    def delete_site(self, site_code: str) -> None:
        """Remove a site and its VLAN rows, freeing the range for reuse."""
        try:
            vlan_table = self._table(self.vlans_table)
            for entity in vlan_table.query_entities(
                "PartitionKey eq @site",
                parameters={"site": site_code},
                select=["PartitionKey", "RowKey"],
            ):
                vlan_table.delete_entity(entity["PartitionKey"], entity["RowKey"])
            try:
                self._table(self.sites_table).delete_entity(
                    SITES_PARTITION, site_code
                )
            except ResourceNotFoundError:
                pass
        except (ClientAuthenticationError, HttpResponseError) as exc:
            raise StorageError(_explain(exc)) from exc

    # ---------------------------------------------------------------- reads
    def list_sites(self) -> list[dict]:
        """All allocated sites, newest first."""
        try:
            rows = [
                {
                    "site_code": e["RowKey"],
                    "supernet": e.get("Supernet", ""),
                    "vlan_count": e.get("VlanCount", 0),
                    "reserve": e.get("Reserve", ""),
                    "created_utc": e.get("CreatedUtc", ""),
                    "created_by": e.get("CreatedBy", ""),
                }
                for e in self._table(self.sites_table).list_entities()
            ]
        except (ClientAuthenticationError, HttpResponseError) as exc:
            raise StorageError(_explain(exc)) from exc
        return sorted(rows, key=lambda r: r["created_utc"], reverse=True)

    def get_site(self, site_code: str) -> dict | None:
        """One site with its VLAN rows, or None if it was never allocated."""
        try:
            try:
                site = self._table(self.sites_table).get_entity(
                    SITES_PARTITION, site_code
                )
            except ResourceNotFoundError:
                return None

            vlans = [
                {_snake(k): v for k, v in e.items() if k not in _TABLE_KEYS}
                for e in self._table(self.vlans_table).query_entities(
                    "PartitionKey eq @site", parameters={"site": site_code}
                )
            ]
        except (ClientAuthenticationError, HttpResponseError) as exc:
            raise StorageError(_explain(exc)) from exc

        vlans.sort(key=lambda v: int(v.get("vlan_id", 0)))
        return {
            "site_code": site["RowKey"],
            "supernet": site.get("Supernet", ""),
            "reserve": [r for r in site.get("Reserve", "").split(",") if r],
            "created_utc": site.get("CreatedUtc", ""),
            "created_by": site.get("CreatedBy", ""),
            "vlans": vlans,
        }

    # ----------------------------------------------------------- validation
    def _check_no_overlap(self, allocation: SiteAllocation) -> None:
        """Reject a range already issued to another site.

        Since every supernet is an aligned /19, "overlaps" here means the same
        block under a different site code - the mistake this exists to catch.
        The comparison stays an overlap test rather than a string match so it
        keeps working if the allocator ever accepts mixed prefix lengths.

        Best effort: two saves racing each other could both pass. The site-code
        uniqueness guard in save() is the hard one.
        """
        candidate = ipaddress.ip_network(allocation.supernet)
        for site in self.list_sites():
            if site["site_code"] == allocation.site_code or not site["supernet"]:
                continue
            if candidate.overlaps(ipaddress.ip_network(site["supernet"])):
                raise RangeOverlap(
                    f"{allocation.supernet} overlaps {site['supernet']}, already "
                    f"allocated to site {site['site_code']}."
                )


_TABLE_KEYS = {"PartitionKey", "RowKey", "Timestamp", "etag", "Supernet"}


def _pascal(name: str) -> str:
    """vlan_id -> VlanId, to match Table Storage property conventions."""
    return "".join(part.title() for part in name.split("_"))


def _snake(name: str) -> str:
    """VlanId -> vlan_id, undoing _pascal on the way back out."""
    out = []
    for i, ch in enumerate(name):
        if ch.isupper() and i:
            out.append("_")
        out.append(ch.lower())
    return "".join(out)


def _explain(exc: Exception) -> str:
    """Turn the usual Azure failures into something actionable."""
    text = str(exc)
    if isinstance(exc, ClientAuthenticationError) or "AuthorizationPermissionMismatch" in text:
        return (
            "Storage rejected the app's identity. Confirm the web app's managed "
            "identity holds 'Storage Table Data Contributor' on the account "
            "(role assignments can take a few minutes to take effect)."
        )
    # A missing private DNS zone link looks identical to a firewall refusal.
    if "AuthorizationFailure" in text or "not authorized" in text.lower():
        return (
            "Storage refused the connection. If public network access is "
            "disabled, check the private endpoint and that the app's VNet "
            "integration routes table traffic through it."
        )
    return f"Storage error: {text}"
