variable "name_prefix" {
  type        = string
  description = "Name prefix for the instances (e.g. 'dev', 'prd')."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnet IDs into which the instances are deployed."
}

variable "zone_ids" {
  type        = list(string)
  description = "Zone IDs corresponding to subnet_ids (parallel arrays)."
}

variable "security_group_id" {
  type        = string
  description = "Security group ID applied to the instances' primary NIC."
}

variable "instance_type" {
  type        = string
  description = "ECS instance type."
  default     = "ecs.g3i.large"
}

variable "image_id" {
  type        = string
  description = "Image ID used for the instances."
}

variable "password" {
  type        = string
  description = "Login password for the instances."
  sensitive   = true
}

variable "system_volume_size" {
  type        = number
  description = "System volume size (GiB)."
  default     = 50
}

variable "system_volume_type" {
  type        = string
  description = "System volume type."
  default     = "ESSD_PL0"
}

variable "instances_per_subnet" {
  type        = number
  description = "Number of ECS instances created per subnet."
  default     = 1
}

variable "project_name" {
  type        = string
  description = "Project name to which the instances belong."
  default     = "default"
}

variable "tags" {
  type = list(object({
    key   = string
    value = string
  }))
  description = "Common tags applied to the instances."
  default     = []
}
