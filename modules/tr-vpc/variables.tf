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
