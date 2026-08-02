# Site IP Allocator

An Azure web app that takes a site code and that site's **/19**, splits it into
**eight /23s — one per VLAN (10, 20, 30, 40, 50, 60, 70, 80)** — and stores the
result in an Azure Storage account. Each VLAN's **name is its ID**, so VLAN 10
is named `10`.

Both the web app and the storage account sit behind **private endpoints**. The
Terraform for the VNet, web app and storage account is in
[`infra/terraform/`](infra/terraform) and is **not applied automatically** —
see [Deploying](#deploying).

## What it produces

Input `LON01` + `10.20.0.0/19` gives:

| VLAN | Name | Range | Netmask | Gateway | Host range | Broadcast | Usable |
|---|---|---|---|---|---|---|---|
| 10 | `10` | `10.20.0.0/23` | 255.255.254.0 | 10.20.0.1 | 10.20.0.2 – 10.20.1.254 | 10.20.1.255 | 510 |
| 20 | `20` | `10.20.2.0/23` | 255.255.254.0 | 10.20.2.1 | 10.20.2.2 – 10.20.3.254 | 10.20.3.255 | 510 |
| 30 | `30` | `10.20.4.0/23` | 255.255.254.0 | 10.20.4.1 | 10.20.4.2 – 10.20.5.254 | 10.20.5.255 | 510 |
| 40 | `40` | `10.20.6.0/23` | 255.255.254.0 | 10.20.6.1 | 10.20.6.2 – 10.20.7.254 | 10.20.7.255 | 510 |
| 50 | `50` | `10.20.8.0/23` | 255.255.254.0 | 10.20.8.1 | 10.20.8.2 – 10.20.9.254 | 10.20.9.255 | 510 |
| 60 | `60` | `10.20.10.0/23` | 255.255.254.0 | 10.20.10.1 | 10.20.10.2 – 10.20.11.254 | 10.20.11.255 | 510 |
| 70 | `70` | `10.20.12.0/23` | 255.255.254.0 | 10.20.12.1 | 10.20.12.2 – 10.20.13.254 | 10.20.13.255 | 510 |
| 80 | `80` | `10.20.14.0/23` | 255.255.254.0 | 10.20.14.1 | 10.20.14.2 – 10.20.15.254 | 10.20.15.255 | 510 |

**Reserve: `10.20.16.0/20`.**

That reserve is worth a word. A /19 holds *sixteen* /23s, and eight VLANs only
consume half of it. Rather than silently discard the rest, the app reports the
untouched upper half as reserve, so a site that later needs a ninth VLAN can
take the next block without renumbering anything already deployed.

Conventions baked in: the **gateway takes the first usable address**, so the
assignable host pool starts one above it.

## How it is put together

```
Your network (VPN / ExpressRoute / peered VNet)
        │
        ▼  private endpoint only - no public ingress
┌───────────────────────────────────────────────────────┐
│ VNet 10.250.0.0/24                                    │
│                                                       │
│  snet-private-endpoints   PE: web app  ──►  App       │
│                           PE: table    ──►  Storage   │
│                                                       │
│  snet-app-integration     web app outbound            │
│   (delegated)             ──► table PE, never public  │
│                                                       │
│  snet-management          your jumpbox / build agent  │
└───────────────────────────────────────────────────────┘
```

The web app authenticates to storage with its **system-assigned managed
identity** against the `Storage Table Data Contributor` role. Shared access
keys are disabled on the account, so there is no key or connection string
anywhere in the app, its settings, or this repo.

### Storage layout

Two tables, created by the app on first use:

| Table | PartitionKey | RowKey | Holds |
|---|---|---|---|
| `sites` | `SITE` | site code | the /19, reserve, who allocated it and when |
| `vlans` | site code | `010`…`080` | one row per VLAN with every field above |

Partitioning `vlans` by site means reading a site back is a single-partition
query. Keeping `sites` small and scannable is what makes the duplicate-range
check cheap.

Two guards run on save: the site code must be unused (enforced by a
create-not-upsert, so two people racing get a clean 409), and the /19 must not
already belong to another site.

## Deploying

Terraform creates the VNet, the storage account and the web app, but **does not
run on its own** — you apply it. From `infra/terraform/`:

```bash
cp terraform.tfvars.example terraform.tfvars   # edit to taste
terraform init
terraform plan          # review before anything is created
terraform apply         # only when you are happy with the plan
```

### The two-phase lockdown

Deploying code to an app that is already private is a chicken-and-egg problem:
Terraform zip-deploys over the app's SCM endpoint, which the private endpoint
closes off. So:

**Phase 1** — `webapp_public_network_access_enabled = true` (the default).
Apply. Terraform pushes the code over the public SCM endpoint. The private
endpoint is created in this phase too.

**Phase 2** — set `webapp_public_network_access_enabled = false` and apply
again. The app is now reachable only from inside the VNet.

After phase 2, any apply that pushes new code has to run from somewhere with
private connectivity — a jumpbox or self-hosted agent in `snet-management` is
the usual answer.

Storage needs no such dance: `storage_public_network_access_enabled` defaults
to **false** from the very first apply, because nothing outside the VNet ever
talks to it. Terraform deliberately does not create the tables — that is a
data-plane call it could not make through a private endpoint anyway.

### Reaching the app once it is private

The private endpoint gives the app's normal hostname a private IP, published in
the `privatelink.azurewebsites.net` zone linked to the VNet. Anything that
resolves through Azure DNS in that VNet — or a peered VNet, or on-prem via a
DNS forwarder — gets the private address. `terraform output web_app_url` gives
you the URL.

### Add authentication

Private networking controls *where* requests come from, not *who* sends them.
Put Entra ID in front of the app by adding an `auth_settings_v2` block to
`azurerm_linux_web_app.main` once you have an app registration. The app already
reads `X-MS-CLIENT-PRINCIPAL-NAME` — the header Easy Auth injects — and records
the signed-in user against each allocation.

## Using it

The UI previews a plan first and writes nothing until you press **Save
allocation**, so a typo costs a click rather than an entry in the database.
Saved sites can be downloaded as CSV.

There is a JSON API over the same logic:

| Method | Path | Does |
|---|---|---|
| `POST` | `/api/allocate` | Split a range, save nothing |
| `POST` | `/api/sites` | Split and store |
| `GET` | `/api/sites` | List allocated sites |
| `GET` | `/api/sites/<code>` | One site with its VLANs |
| `POST` | `/api/sites/<code>/delete` | Remove a site, freeing its range |
| `GET` | `/api/health` | Liveness and storage status |

```bash
curl -X POST https://<app>/api/sites \
  -H 'Content-Type: application/json' \
  -d '{"site_code": "LON01", "supernet": "10.20.0.0/19"}'
```

## Running locally

The allocator logic has no Azure dependencies, so it runs anywhere:

```bash
cd app
pip install -r requirements.txt
python app.py            # http://127.0.0.1:8000
```

With no `IPAM_STORAGE_ACCOUNT` set the app starts in preview-only mode: it
splits ranges and shows results, and the save button is disabled. To point it
at real storage, set `IPAM_STORAGE_ACCOUNT` and sign in with `az login` — the
same `DefaultAzureCredential` that resolves to the managed identity in Azure
will pick up your CLI login locally. You will need network access to the
storage account's private endpoint and the `Storage Table Data Contributor`
role on your own account.

### Tests

```bash
cd app && python -m pytest tests/ -q
```

29 tests, no Azure required. They cover the subnet arithmetic (VLAN count,
boundaries, gateway/host/broadcast addresses, the reserve block, and that the
VLANs plus reserve exactly tile the /19 with no overlap), the input validation,
and the storage layer's property mapping and duplicate-range guard.

### App settings

| Setting | Purpose |
|---|---|
| `IPAM_STORAGE_ACCOUNT` | Storage account name; unset means preview-only |
| `IPAM_TABLE_ENDPOINT` | Override the table endpoint (rarely needed) |
| `IPAM_SITES_TABLE` | Sites table name, default `sites` |
| `IPAM_VLANS_TABLE` | VLANs table name, default `vlans` |

## Layout

```
ipam/
  app/
    allocator.py           the subnet arithmetic - pure Python, no Azure
    storage.py             Table Storage persistence via managed identity
    app.py                 Flask routes: HTML pages and the JSON API
    templates/ static/     UI
    tests/                 pytest, runs without Azure
  infra/terraform/
    network.tf             VNet, subnets, private DNS zones
    storage.tf             storage account, table private endpoint, RBAC
    webapp.tf              App Service plan, web app, private endpoint
    variables.tf outputs.tf versions.tf
    terraform.tfvars.example
```
