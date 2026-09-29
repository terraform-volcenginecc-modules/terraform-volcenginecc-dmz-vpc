variable "name" {
  type        = string
  description = "Name prefix for ALB, server group and listener."
}

variable "vpc_id" {
  type        = string
  description = "ID of the dmz VPC where the ALB lives."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Business subnet IDs the ALB binds to (multi-AZ)."
}

variable "zone_ids" {
  type        = list(string)
  description = "Zone IDs corresponding to subnet_ids (parallel arrays)."
}

variable "address_ip_version" {
  type        = string
  description = "IP type of the ALB."
  default     = "IPv4"
}

variable "edition" {
  type        = string
  description = "ALB edition: Basic / Standard."
  default     = "Standard"
}

variable "eip_bandwidth_mbps" {
  type        = number
  description = "Bandwidth (Mbps) for the EIP automatically attached to the ALB."
  default     = 5
}

variable "listener_port" {
  type        = number
  description = "Listener port."
  default     = 80
}

variable "listener_protocol" {
  type        = string
  description = "Listener protocol (HTTP or HTTPS)."
  default     = "HTTP"
}

variable "backend_port" {
  type        = number
  description = "Port on which backend ECS instances listen."
  default     = 80
}

variable "backend_ips" {
  type        = list(string)
  description = "IP addresses of backend ECS instances."
  default     = []
}

variable "health_check_uri" {
  type        = string
  description = "HTTP URI used for ALB health checks."
  default     = "/"
}

variable "project_name" {
  type        = string
  description = "Project name."
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
