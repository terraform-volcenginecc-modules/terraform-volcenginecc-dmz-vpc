variable "vpc_name" {
  type        = string
  description = "Name of the VPC."
}

variable "cidr_block" {
  type        = string
  description = "CIDR block of the VPC."
}

variable "business_subnet_cidrs" {
  type        = list(string)
  description = "CIDR blocks for the business subnets (multi-AZ)."
}

variable "tr_subnet_cidrs" {
  type        = list(string)
  description = "CIDR blocks for the TR connection-point subnets (multi-AZ)."
}

variable "zones" {
  type        = list(string)
  description = "Availability zones for subnets (round-robin)."

  validation {
    condition     = length(var.zones) >= 2
    error_message = "At least two AZs are required for HA."
  }
}

variable "transit_router_id" {
  type        = string
  description = "ID of the central Transit Router this VPC attaches to."
}

variable "outbound" {
  type        = bool
  description = "Whether the VPC should route 0.0.0.0/0 to the Transit Router."
  default     = false
}

variable "internal_route_cidrs" {
  type        = list(string)
  description = "CIDRs that must be routed via the Transit Router."
  default     = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
}

variable "extra_route_entries" {
  description = "Optional list of additional custom route entries."
  type = list(object({
    destination_cidr_block = string
    next_hop_type          = string
    next_hop_id            = string
    description            = string
  }))
  default = []
}

# Set to false when the route table needs to be created at root level (for
# example when its contents depend on resources outside this module, like a
# NAT gateway). When false, the module skips route_table creation; the caller
# is responsible for managing the dmz VPC's routing externally.
variable "create_route_table" {
  type        = bool
  description = "Whether this module should create the VPC's custom route table."
  default     = true
}

variable "project_name" {
  type        = string
  description = "Project name to which all resources belong."
  default     = "default"
}

variable "tags" {
  type = list(object({
    key   = string
    value = string
  }))
  description = "Common tags applied to all resources."
  default     = []
}
