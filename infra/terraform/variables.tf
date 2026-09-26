variable "name_prefix" {
  description = "Prefix for all resource names, e.g. 'srvinv'."
  type        = string
  default     = "srvinv"

  validation {
    condition     = can(regex("^[a-z0-9]{2,11}$", var.name_prefix))
    error_message = "name_prefix must be 2-11 lowercase alphanumeric characters."
  }
}

variable "resource_group_name" {
  description = "Resource group that holds the whole solution."
  type        = string
  default     = "rg-server-inventory"
}

variable "hub_location" {
  description = "Region for the resource group and the central storage account."
  type        = string
  default     = "eastus2"
}

variable "regions" {
  description = <<-EOT
    One entry per Azure region to inventory, keyed by region name. Each region
    provides three pieces of its (isolated) network:
      functions_subnet_id        - subnet DELEGATED to Microsoft.Web/serverFarms;
                                   the function app VNet-integrates here to reach
                                   the region's servers over WMI/WinRM
      private_endpoint_subnet_id - subnet for the private endpoints (function
                                   app inbound + central storage blob/web)
      vnet_id                    - the region's VNet, linked to the private DNS
                                   zones so private-endpoint names resolve
  EOT
  type = map(object({
    functions_subnet_id        = string
    private_endpoint_subnet_id = string
    vnet_id                    = string
  }))
}

variable "wmi_username" {
  description = "Windows account with remote WMI rights on the target servers (DOMAIN\\user or .\\localadmin)."
  type        = string
}

variable "wmi_password" {
  description = "Password for the WMI account. Prefer switching the app setting to a Key Vault reference after deployment."
  type        = string
  sensitive   = true
}

variable "public_network_access_enabled" {
  description = <<-EOT
    Two-phase lockdown switch. Leave true for the FIRST apply so Terraform can
    zip-deploy the function code and upload the dashboard from your machine
    over the public endpoints (the private endpoints are created either way).
    Then set false and re-apply to shut off all public access - after that,
    applies that push code/content must run from a network with private
    connectivity (e.g. a self-hosted agent).
  EOT
  type        = bool
  default     = true
}

variable "collector_schedule" {
  description = "NCRONTAB expression for the inventory collection timer (informational - the schedule itself lives in functions/collector/InventoryCollector/function.json)."
  type        = string
  default     = "0 */15 * * * *"
}

variable "reservation_cost_scope" {
  description = <<-EOT
    Billing scope the GetReservationSavings endpoint queries for amortized
    cost, e.g. "/providers/Microsoft.Billing/billingAccounts/1234567" (EA) or
    ".../billingAccounts/<id>/billingProfiles/<id>" (MCA). Leave empty to use
    the app's own subscription, which only sees that subscription's share of a
    shared reservation - the endpoint then falls back to public list prices for
    anything it cannot cost, and says so per row.
  EOT
  type        = string
  default     = ""
}

variable "reservation_currency" {
  description = "ISO currency code for retail price comparisons in the reservation report (USD, EUR, GBP...)."
  type        = string
  default     = "USD"

  validation {
    condition     = can(regex("^[A-Z]{3}$", var.reservation_currency))
    error_message = "reservation_currency must be a three-letter ISO code, e.g. USD."
  }
}

variable "reservation_cache_minutes" {
  description = <<-EOT
    How long GetReservationSavings serves its cached result before
    recollecting. Reservation costs move at most daily and the Cost Management
    query API throttles hard, so keep this well above the dashboard's poll
    interval. Default 6 hours.
  EOT
  type        = number
  default     = 360
}
