################################################################################
# Global / Naming
################################################################################

variable "region" {
  type        = string
  description = "Volcengine region in which to deploy the DMZ landing zone."
  default     = "cn-beijing"
}

variable "name_prefix" {
  type        = string
  description = "Common name prefix for all resources to make them easy to identify."
  default     = "dmz"
}

variable "project_name" {
  type        = string
  description = "Volcengine project name to which all resources belong."
  default     = "default"
}

variable "zones" {
  type        = list(string)
  description = "List of availability zones used for multi-AZ subnets."
  default     = ["cn-beijing-a", "cn-beijing-b"]

  validation {
    condition     = length(var.zones) >= 2
    error_message = "At least two availability zones are required for HA."
  }
}

################################################################################
# VPC Topology (dmz / dev / prd)
################################################################################

# The DMZ landing zone is built on three VPCs:
#   - dmz : hosts NAT gateway and public ALB (the only VPC with public exposure)
#   - dev : development workload VPC, traffic egresses through dmz NAT
#   - prd : production workload VPC, fronted by the dmz ALB
# Every VPC has business subnets (for workloads / NAT / ALB) and TR subnets
# (used as connection points by the Transit Router VPC Attachment).
variable "vpcs" {
  description = "Topology of the three VPCs that make up the DMZ landing zone."
  type = map(object({
    cidr_block            = string
    business_subnet_cidrs = list(string)
    tr_subnet_cidrs       = list(string)
    # outbound = true means the VPC's default route 0.0.0.0/0 should be sent
    # to the Transit Router (and ultimately to the dmz NAT). This is typically
    # enabled for dev VPC only.
    outbound = bool
  }))

  default = {
    dmz = {
      cidr_block            = "172.16.0.0/16"
      business_subnet_cidrs = ["172.16.0.0/24", "172.16.1.0/24"]
      tr_subnet_cidrs       = ["172.16.3.0/24", "172.16.4.0/24"]
      outbound              = false
    }
    dev = {
      cidr_block            = "172.17.0.0/16"
      business_subnet_cidrs = ["172.17.0.0/24", "172.17.1.0/24"]
      tr_subnet_cidrs       = ["172.17.3.0/24", "172.17.4.0/24"]
      outbound              = true
    }
    prd = {
      cidr_block            = "172.18.0.0/16"
      business_subnet_cidrs = ["172.18.0.0/24", "172.18.1.0/24"]
      tr_subnet_cidrs       = ["172.18.3.0/24", "172.18.4.0/24"]
      outbound              = false
    }
  }

  validation {
    condition     = contains(keys(var.vpcs), "dmz") && contains(keys(var.vpcs), "dev") && contains(keys(var.vpcs), "prd")
    error_message = "The vpcs map must contain the keys 'dmz', 'dev' and 'prd'."
  }
}

# Default routes pushed into every VPC route table, ensuring all RFC1918 traffic
# is sent to the Transit Router for cross-VPC communication.
variable "vpc_internal_route_cidrs" {
  type        = list(string)
  description = "CIDRs that must be routed via the Transit Router from each VPC."
  default     = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
}

################################################################################
# Transit Router
################################################################################

variable "tr_config" {
  description = "Configuration of the central Transit Router."
  type = object({
    name        = optional(string)
    description = optional(string)
    asn         = optional(number, 64512)
  })
  default = {}
}

################################################################################
# NAT Gateway / EIP / Bandwidth Package
################################################################################

variable "nat_gateway_spec" {
  type        = string
  description = "Specification of the dmz NAT gateway."
  default     = "Small"
}

variable "nat_eip_bandwidth_mbps" {
  type        = number
  description = "Bandwidth (Mbps) of the EIP attached to the NAT gateway."
  default     = 5
}

variable "alb_eip_bandwidth_mbps" {
  type        = number
  description = "Bandwidth (Mbps) of the EIP automatically attached to the ALB."
  default     = 5
}

variable "shared_bandwidth_package_mbps" {
  type        = number
  description = "Total bandwidth (Mbps) of the shared bandwidth package aggregating NAT and ALB EIPs."
  default     = 10
}

################################################################################
# Security Group
################################################################################

variable "default_ingress_rules" {
  description = "Common ingress rules applied to every VPC's security group."
  type = list(object({
    policy      = string
    port_start  = number
    port_end    = number
    protocol    = string
    priority    = number
    cidr_ip     = string
    description = string
  }))

  default = [
    {
      policy      = "Accept"
      port_start  = 22
      port_end    = 22
      protocol    = "TCP"
      priority    = 1
      cidr_ip     = "0.0.0.0/0"
      description = "Allow SSH from anywhere"
    },
    {
      policy      = "Accept"
      port_start  = 80
      port_end    = 80
      protocol    = "TCP"
      priority    = 1
      cidr_ip     = "0.0.0.0/0"
      description = "Allow HTTP"
    },
    {
      policy      = "Accept"
      port_start  = 443
      port_end    = 443
      protocol    = "TCP"
      priority    = 1
      cidr_ip     = "0.0.0.0/0"
      description = "Allow HTTPS"
    },
  ]
}

################################################################################
# ALB
################################################################################

variable "alb_config" {
  description = "Public ALB configuration deployed in the dmz VPC."
  type = object({
    address_ip_version = optional(string, "IPv4")
    edition            = optional(string, "Standard")
    listener_port      = optional(number, 80)
    listener_protocol  = optional(string, "HTTP")
    health_check_uri   = optional(string, "/")
  })
  default = {}
}

################################################################################
# ECS workloads
################################################################################

variable "ecs_config" {
  description = "Workload ECS configuration."
  type = object({
    instance_type      = optional(string, "ecs.g3i.large")
    image_id           = string
    system_volume_type = optional(string, "ESSD_PL0")
    system_volume_size = optional(number, 50)
    password           = string
    # Number of ECS instances created per business subnet (in dev and prd).
    instances_per_subnet = optional(number, 1)
  })
}

################################################################################
# Tags
################################################################################

variable "common_tags" {
  type        = map(string)
  description = "Common tags applied to every resource that supports tagging."
  default = {
    Project     = "dmz-landing-zone"
    Environment = "shared"
    ManagedBy   = "Terraform"
  }
}
