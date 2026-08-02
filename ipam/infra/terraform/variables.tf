variable "name_prefix" {
  description = "Prefix for all resource names, e.g. 'ipam'."
  type        = string
  default     = "ipam"

  validation {
    condition     = can(regex("^[a-z0-9]{2,11}$", var.name_prefix))
    error_message = "name_prefix must be 2-11 lowercase alphanumeric characters."
  }
}

variable "resource_group_name" {
  description = "Resource group that holds the whole solution."
  type        = string
  default     = "rg-site-ip-allocator"
}

variable "location" {
  description = "Azure region for every resource."
  type        = string
  default     = "eastus2"
}

# ------------------------------------------------------------------ network
# This is the VNet the app runs in - not the address space it hands out.
# Site /19s are data typed into the app; they are never deployed as Azure
# subnets, so there is no overlap between these prefixes and site ranges.
variable "vnet_address_space" {
  description = "Address space for the app's VNet."
  type        = list(string)
  default     = ["10.250.0.0/24"]
}

variable "private_endpoint_subnet_prefix" {
  description = "Subnet holding the private endpoints for the web app and storage."
  type        = string
  default     = "10.250.0.0/26"
}

variable "app_integration_subnet_prefix" {
  description = <<-EOT
    Subnet the web app VNet-integrates into for outbound traffic. Delegated to
    Microsoft.Web/serverFarms, so nothing else can be deployed here. Must be a
    /26 or larger - App Service needs the room to scale.
  EOT
  type        = string
  default     = "10.250.0.64/26"
}

variable "management_subnet_prefix" {
  description = <<-EOT
    Subnet for whatever you use to reach the private app: a jumpbox, a
    self-hosted pipeline agent, or a VPN/ExpressRoute landing spot. Created
    empty - nothing here is required for the app to run.
  EOT
  type        = string
  default     = "10.250.0.128/26"
}

# ------------------------------------------------------------------ compute
variable "app_service_sku" {
  description = <<-EOT
    App Service plan SKU. P1v3 is the sensible production default; B1 and S1
    also support both private endpoints and VNet integration if you want to
    spend less on a non-production instance.
  EOT
  type        = string
  default     = "P1v3"
}

variable "python_version" {
  description = "Python runtime for the web app."
  type        = string
  default     = "3.12"
}

# ------------------------------------------------------------------ access
variable "webapp_public_network_access_enabled" {
  description = <<-EOT
    Two-phase deployment switch for the WEB APP only.

    Leave true for the first apply so Terraform can zip-deploy the app code
    over the public SCM endpoint from your machine. The private endpoint is
    created either way. Then set false and re-apply to make the app reachable
    only from inside the VNet.

    Once false, any apply that pushes code must run from a network with
    private connectivity - a jumpbox or self-hosted agent in the management
    subnet, for example.
  EOT
  type        = bool
  default     = true
}

variable "storage_public_network_access_enabled" {
  description = <<-EOT
    Public access to the storage account. Defaults to false because nothing
    ever needs it: the web app reaches storage over the private endpoint, and
    Terraform never touches the data plane (the app creates its own tables).

    Set true only if you want to browse the tables from the portal without a
    jumpbox.
  EOT
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
