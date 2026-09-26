# Azure Server Inventory — OS & SQL Lifecycle Dashboard

A near-real-time, interactive web app that inventories **every Windows server
across your entire Azure environment** — even when firewalls block
region-to-region connectivity — and color-codes each server's lifecycle
status:

| Status | Meaning | Color |
|---|---|---|
| 🔴 **End of life** | Past Microsoft's end of extended support | Red |
| 🟠 **Nearing EOL** | Extended support ends within 12 months (configurable) | Amber |
| 🟢 **Supported** | Inside extended support | Green |
| ⚪ **Unknown** | Caption didn't match a rule, or the server was unreachable | Grey |

The same classification is applied to **SQL Server**: the dashboard shows
whether SQL is installed, every instance's **edition** (Standard, Enterprise,
Express, Developer…), **version/patch level**, and whether that SQL release is
EOL, nearing EOL, or compliant.

All server facts come from **live WMI queries** — the *actual* installed OS
caption (`Win32_OperatingSystem.Caption`), the **physical core count**
(`Win32_Processor.NumberOfCores` summed across sockets), memory, domain, and
SQL Server details read from the registry over WMI (`StdRegProv`) — no agent
and no SQL login required.

## Architecture

The design works *with* your network constraint instead of against it:
regions cannot talk to each other, but **one blob storage account is reachable
from every region** (via a private endpoint in each region), so it becomes the
only cross-region data path. Inventory runs in these seven regions:

`northcentralus` · `eastus2` · `northeurope` · `uksouth` · `southeastasia` ·
`australiaeast` · `brazilsoutheast`

```mermaid
flowchart LR
    subgraph R1["Region: northcentralus (isolated)"]
        F1["PowerShell Function App\n(VNet-integrated, private endpoint)"] -- "WMI / WinRM\n(intra-region only)" --> S1["Windows VMs\n+ SQL Server"]
        F1 --> PE1["PE: blob"]
    end
    subgraph R2["Region: uksouth (isolated)"]
        F2["PowerShell Function App\n(VNet-integrated, private endpoint)"] -- WMI --> S2["Windows VMs"]
        F2 --> PE2["PE: blob"]
    end
    subgraph R3["… 5 more regions …"]
        F3["Function Apps"] -- WMI --> S3["Windows VMs"]
        F3 --> PE3["PE: blob"]
    end

    PE1 -- "regions/northcentralus.json" --> B[("Central blob storage\n(private endpoints in ALL regions)")]
    PE2 -- "regions/uksouth.json" --> B
    PE3 --> B

    B --> AGG["GetInventory\nHTTP function (private endpoint)"]
    AGG --> D["Interactive dashboard\n(static website via 'web'\nprivate endpoints)"]

    RES["GetReservationSavings\nHTTP function"] -- "reservations + cost\n(tenant-wide, not regional)" --> ARM[("Azure Capacity +\nCost Management APIs")]
    RES -- "cached savings.json" --> B
    RES --> D
```

1. **Regional collectors** (`functions/collector/InventoryCollector`) — a
   timer-triggered PowerShell function deployed **once per region**, VNet
   integrated into that region. Every 15 minutes it:
   - discovers the running Windows VMs in *its own region* via `Get-AzVM`
     (managed identity + Reader role — no credentials stored for discovery);
   - opens a parallel CIM/WMI session to each server and queries
     `Win32_OperatingSystem`, `Win32_Processor`, `Win32_ComputerSystem`,
     `Win32_Service` (SQL detection) and `StdRegProv` (SQL edition/version
     from the registry, still over WMI);
   - writes the region snapshot to the central account as
     `inventory/regions/<region>.json`.
2. **Aggregator** (`functions/collector/GetInventory`) — an HTTP function
   (deployed with every app; call any one of them) that merges all region
   blobs into a single JSON feed.
3. **Reservation savings** (`functions/collector/GetReservationSavings`) — an
   HTTP function serving the dashboard's second tab. Reservations are
   tenant-wide rather than regional, so it sits outside the per-region
   collection: any one app can answer it, and it caches its result in the same
   central account. See [Reservation cost & savings](#reservation-cost--savings).
4. **Dashboard** (`dashboard/`) — a dependency-free static web app hosted on
   the storage account's static website, in two tabs. **Servers** polls the
   aggregator every 60 seconds, classifies each OS and SQL build against the
   lifecycle tables in `dashboard/lifecycle.js`, and renders stat tiles, a
   per-region status breakdown, and a searchable / filterable / sortable table
   with CSV export. **Reservations** shows what each reservation costs per
   month against pay-as-you-go, and whether its utilization is actually earning
   that saving. Light and dark mode are both supported.

### Private networking

Everything is private-endpoint only once locked down:

| Traffic | Path |
|---|---|
| Function app inbound (GetInventory, SCM) | Private endpoint per app (`sites`), `privatelink.azurewebsites.net` |
| Collector → central storage | Private endpoint per region (`blob`), `privatelink.blob.core.windows.net` |
| Browser → dashboard static website | Private endpoint per region (`web`), `privatelink.web.core.windows.net` |
| Function app → region's servers | Regional VNet integration (delegated subnet), WMI/WinRM |

The three private DNS zones are created once and linked to every region's
VNet, so the same FQDNs resolve to the local private endpoint everywhere.

Because lifecycle rules live in the dashboard, updating EOL dates (e.g. when
Microsoft publishes Windows Server 2028) is a one-file edit — **no collector
redeployment**.

## Repository layout

```
infra/terraform/
  main.tf               Resource group, central storage, static website,
                        private DNS zones, storage private endpoints
  function_apps.tf      Per-region EP1 plans + function apps + VNet
                        integration + private endpoints + RBAC + zip deploy
  dashboard.tf          Uploads dashboard/ to the $web container
  variables.tf, outputs.tf, versions.tf
  terraform.tfvars.example   The seven regions, ready to fill in
functions/collector/
  InventoryCollector/   Timer trigger: WMI collection -> region blob
  GetInventory/         HTTP trigger: merge region blobs -> dashboard feed
  GetReservationSavings/  HTTP trigger: reservation costs -> dashboard feed
  Modules/
    AzReservationSavings/ Reservation costing logic, shared by the HTTP
                        endpoint and the console script (Azure Functions puts
                        Modules/ on $env:PSModulePath automatically)
  host.json, profile.ps1, requirements.psd1
dashboard/
  index.html, app.js, styles.css
  reservations.js       Reservations tab: tiles, saving meters, table, CSV
  lifecycle.js          Windows + SQL EOL tables and classification logic
  config.js             Set apiUrl / reservationsApiUrl here; empty = demo mode
  sample-data.js        Bundled demo snapshots (open index.html locally to try)
scripts/
  Get-AzReservationSavings.ps1   Console entry point for the module above
```

## Try it in 10 seconds (no Azure needed)

Open `dashboard/index.html` in a browser. With both URLs in `config.js` left
empty, the dashboard runs on bundled sample snapshots so you can see the
red/amber/green classification, filters, region bars and CSV export on the
**Servers** tab, and the cost/saving meters on the **Reservations** tab,
before deploying anything.

## Deploying

### Prerequisites

- Terraform ≥ 1.7 and an authenticated `azurerm` context (e.g. `az login`)
  with rights to create resources **and role assignments** (subscription
  Reader is granted to each app's managed identity).
- In **each of the seven regions**:
  - a subnet **delegated to `Microsoft.Web/serverFarms`** for the function
    app's VNet integration (this is how it reaches that region's servers);
  - a subnet for **private endpoints**;
  - the VNet ID (for the private DNS zone links).
- A **WMI service account** with remote WMI/WinRM rights on the target
  servers.
- Regional firewall rules allowing, **within each region only**:
  - Function subnet → servers: TCP 5985/5986 (WinRM; the collector uses
    WSMan by default, set `WMI_TRANSPORT=Dcom` for classic DCOM — that needs
    TCP 135 + dynamic RPC ports).
  - Function subnet → the region's storage `blob` private endpoint: TCP 443.

### Phase 1 — deploy (public deployment path still open)

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars   # fill in subnet/VNet IDs
export TF_VAR_wmi_password='<service account password>'
terraform init
terraform apply
```

With the default `public_network_access_enabled = true`, Terraform can
zip-deploy the function code and upload the dashboard from your machine while
all private endpoints are already being created.

### Phase 2 — lock down

In `terraform.tfvars` set:

```hcl
public_network_access_enabled = false
```

and `terraform apply` again. Storage and every function app now refuse public
traffic; everything flows through the private endpoints. From this point,
applies that push new code or dashboard content must run from a machine or
pipeline agent with private connectivity to those endpoints.

### Wire up the dashboard

1. Get **function keys** for `GetInventory` and `GetReservationSavings` from
   any one of the apps and set both URLs in `dashboard/config.js`:
   ```js
   apiUrl:             "https://srvinv-func-eastus2.azurewebsites.net/api/GetInventory?code=<key>"
   reservationsApiUrl: "https://srvinv-func-eastus2.azurewebsites.net/api/GetReservationSavings?code=<key>"
   ```
   (The hostname resolves to the private endpoint from linked VNets.) Either
   may be left empty — that tab then runs on bundled demo data.
   Re-apply Terraform — `dashboard.tf` detects the content change and
   re-uploads the file.
2. **Move `WMI_PASSWORD` to Key Vault**: create a secret, grant each app's
   managed identity *Key Vault Secrets User*, and change the app setting to
   `@Microsoft.KeyVault(SecretUri=https://<vault>.vault.azure.net/secrets/wmi-password/)`
   — the Terraform config ignores drift on that setting so your change
   sticks.
3. Tighten `Access-Control-Allow-Origin` in `GetInventory/run.ps1` to the
   dashboard's URL.

## Configuration reference (collector app settings)

| Setting | Purpose | Default |
|---|---|---|
| `INVENTORY_REGION` | The one region this app inventories | set by Terraform |
| `INVENTORY_STORAGE_ACCOUNT` | Central storage account name | set by Terraform |
| `INVENTORY_CONTAINER` | Blob container | `inventory` |
| `WMI_USERNAME` / `WMI_PASSWORD` | Remote WMI credentials | set by Terraform |
| `WMI_TRANSPORT` | `Wsman` or `Dcom` | `Wsman` |
| `COLLECTOR_THROTTLE` | Parallel WMI sessions | `8` |
| `RESERVATION_COST_SCOPE` | Billing scope for amortized reservation cost | the app's subscription |
| `RESERVATION_CURRENCY` | ISO currency for retail price comparisons | `USD` |
| `RESERVATION_CACHE_MINUTES` | How long `GetReservationSavings` serves its cached result | `360` |

Collection cadence is the timer CRON in
`InventoryCollector/function.json` (default every 15 minutes); dashboard poll
interval is `refreshSeconds` in `dashboard/config.js` (default 60 s).

## Lifecycle data

End-of-extended-support dates ship in `dashboard/lifecycle.js` for Windows
Server 2003 → 2025 and SQL Server 2000 → 2022, with SQL versions mapped from
the registry build number (e.g. `15.x` → SQL Server 2019). "Nearing EOL"
means within `NEARING_MONTHS` (12) months of the date. ESU coverage is
deliberately ignored — an ESU server still shows red so it stays on your
migration list. Verify dates against
[Microsoft Lifecycle](https://learn.microsoft.com/lifecycle/) when updating.

## Reservation cost & savings

The same costing logic is served three ways, from one implementation in
`functions/collector/Modules/AzReservationSavings`:

| Surface | What it is |
|---|---|
| **Reservations tab** | In the dashboard, beside Servers — tiles, a saving meter per reservation, and a filterable table |
| **`GetReservationSavings`** | HTTP function that feeds that tab (deployed with every regional app; call any one) |
| **`Get-AzReservationSavings`** | The same report in a console, for ad-hoc slicing and CSV |

### The dashboard tab

Bar length is the pay-as-you-go cost of the same capacity, so the longest bars
are where the money is. The filled part is what the reservation saves you, and
its color answers a different question — whether you are actually *realizing*
that saving at current utilization:

| Color | Meaning |
|---|---|
| 🟢 **Fully used** | ≥ 90% utilized — the projected saving is real |
| 🟠 **Under-used** | Below 90% — you are paying for capacity you are not using |
| 🔴 **Losing money** | Realized saving is negative: the reservation costs more than the usage it covers |
| ⚪ **Unknown** | No utilization data for this reservation |

That distinction is the point of the tab. A reservation can show a healthy
30% projected discount and still be losing money, because the discount only
applies to hours you actually consume. The table's *Saving / month* column is
the projected figure; the utilization meter beside it is what you are getting.

Reservations are tenant-wide rather than regional, so this endpoint is not
part of the per-region collection: any one app can answer it, and the result
is **cached in the central storage account** (`reservations/savings.json`,
6 hours by default). Reservation costs move at most daily, and the Cost
Management query API throttles hard, so the tab loads on first open and then
only when you ask — unlike the servers tab's 60-second poll. `Refresh now`
sends `?refresh=true`, which bypasses the cache and recollects.

### The console report

```powershell
Connect-AzAccount
. ./scripts/Get-AzReservationSavings.ps1
Show-AzReservationSavings
```

```
Name              Sku              Region      Qty Term Cost/mo (USD) PAYG/mo (USD) Saving/mo (USD) Saving % Util % Mo left Source
----              ---              ------      --- ---- ------------- ------------- --------------- -------- ------ ------- ------
prod-d4sv3-eastus Standard_D4s_v3  eastus       10 P3Y       1,015.60      1,401.60          386.00     27.5   97.2      18 CostManagement
dev-e8sv5-weu     Standard_E8s_v5  westeurope    4 P1Y         966.67      1,471.68          505.01     34.3   35.0       5 Retail

  Reservation cost / month                  1,982.27 USD
  Pay-as-you-go equivalent                  2,873.28 USD
  Projected saving / month                    891.01 USD
  Projected saving / year                  10,692.12 USD
  Realized at current utilization             439.43 USD
```

`Get-AzReservationSavings` emits one object per reservation, so the data is
yours to slice — `Export-Csv`, `ConvertTo-Json`, `Where-Object`, whatever:

```powershell
Get-AzReservationSavings | Sort-Object MonthlySaving | Select-Object -First 10
Get-AzReservationSavings -CostScope '/providers/Microsoft.Billing/billingAccounts/1234567' |
    Export-Csv ./reservation-savings.csv -NoTypeInformation
```

### Where the numbers come from

**Monthly cost** resolves from the best source available, and every row
records which one won in its `CostSource` property:

| Source | What it is | Requires |
|---|---|---|
| `CostManagement` | Actual amortized cost billed last complete month, grouped by `ReservationId` — reflects *your* prices | Cost Management Reader on an EA/MCA billing scope |
| `BillingPlan` | The real recurring payment, for reservations bought on the monthly plan | Reservation Reader |
| `Retail` | Public list price for the term, divided across it | nothing (public API) |

**Pay-as-you-go comparison** always comes from the public Azure Retail Prices
API. For VMs the *base* compute rate is used — Linux, non-Spot — because a
reservation discounts compute only, never the Windows or SQL licence on top
of it. Comparing against the Windows rate would overstate savings.

**Projected vs realized.** `MonthlySaving` is what the reservation earns if
fully used. `RealizedMonthlySaving` scales the pay-as-you-go side by actual
utilization, so an under-used reservation shows what it is *really* returning
— and goes negative when it costs more than the usage it covers. Anything
below 90% utilization is called out separately under the totals.

### Permissions — the one manual step

Terraform grants each app's managed identity **Cost Management Reader** on the
subscription, but it cannot grant **Reservations Reader**: reservation orders
live under `/providers/Microsoft.Capacity`, outside any subscription, so the
`azurerm` provider has no scope to assign at. Without it the endpoint returns
an empty list and says so in the response's `warnings`, which the dashboard
shows as a banner.

Grant it once after the first apply, using `terraform output
function_app_principal_ids`:

```bash
# Per reservation order:
az role assignment create --role "Reservations Reader" \
  --assignee <principal id> \
  --scope /providers/Microsoft.Capacity/reservationOrders/<order id>
```

Or cover every current and future order at once by granting the principal
Reservations Reader at the billing account scope: **Cost Management + Billing
→ <billing account> → Access control (IAM)**.

For *actual billed* costs rather than list prices, the identity also needs
Cost Management Reader at an EA/MCA **billing** scope, set as
`reservation_cost_scope`. The subscription-level grant Terraform makes only
sees that subscription's share of a shared reservation.

### Caveats worth knowing

- **Non-VM reservations** (Cosmos DB, SQL vCore, App Service, Databricks…)
  often have no `armSkuName` in the retail catalogue. Those rows report the
  reservation and its cost but leave the savings columns empty with a note,
  rather than guessing at a match.
- **Retail rows are list price.** If you have an EA/MCA discount, the
  `Retail` source understates your saving. Pass `-CostScope` with a billing
  account to get `CostManagement` numbers instead.
- **Instance size flexibility** means a reservation may be covering sizes
  other than its own SKU. The pay-as-you-go comparison uses the reservation's
  own SKU, which is the standard method, but the realized figure is the one
  to trust when flexibility is on.
- The current month is always partial, so the default billing month is the
  **last complete calendar month**. Override with `-CostMonth`.
- Savings assume **730 hours/month** (Azure's own convention); override with
  `-HoursPerMonth`.
- The dashboard tab reads a **cached** result (default 6 hours), so a figure
  there can lag a reservation you bought this morning. `Refresh now` forces a
  recollection; `RESERVATION_CACHE_MINUTES` changes the TTL.

Run `Get-Help Get-AzReservationSavings -Full` for every parameter.

## Notes & extension points

- **Non-Azure / Arc servers**: add discovery via `Get-AzConnectedMachine`
  (Azure Arc) in the collector, or feed a static target list per region.
- **Linux servers**: WMI is Windows-only; a parallel collector over SSH could
  emit the same JSON shape and the dashboard would render it unchanged.
- **Scale**: at hundreds of servers per region, raise `COLLECTOR_THROTTLE`,
  the `functionTimeout` in `host.json`, or split the region across multiple
  timer schedules.
- **SQL clusters/AGs**: detection is per-node (service + registry), which is
  usually what licensing and patching reviews want.
- **Dashboard auth**: the static website is network-restricted by the private
  endpoints; add Entra ID (e.g. Front Door + Easy Auth or an internal reverse
  proxy) if you also need identity-based access control.
