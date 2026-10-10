variable "name" {
  type        = string
  description = "Name prefix used for NAT gateway, EIP and SNAT rules."
}

variable "vpc_id" {
  type        = string
  description = "ID of the dmz VPC where the NAT gateway lives."
}

variable "subnet_id" {
  type        = string
  description = "ID of the subnet in which the NAT gateway is provisioned."
}

variable "spec" {
  type        = string
  description = "NAT gateway specification (Small / Medium / Large / ...)."
  default     = "Small"
}

variable "eip_bandwidth_mbps" {
  type        = number
  description = "Bandwidth (Mbps) of the EIP attached to the NAT gateway."
  default     = 5
}

variable "snat_source_cidrs" {
  type        = list(string)
  description = "Source CIDRs that should be SNATed through this NAT gateway (e.g. dev VPC CIDR)."
  default     = []
}

variable "bandwidth_package_id" {
  type        = string
  description = "Optional shared bandwidth package ID; when set the NAT EIP is added to it."
  default     = null
}

variable "project_name" {
  type        = string
  description = "Project name to which the resources belong."
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
