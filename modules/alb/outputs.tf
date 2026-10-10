output "alb_id" {
  description = "ID of the ALB."
  value       = volcenginecc_alb_load_balancer.this.id
}

output "alb_dns_name" {
  description = "DNS name of the ALB."
  value       = volcenginecc_alb_load_balancer.this.dns_name
}

output "server_group_id" {
  description = "ID of the ALB server group."
  value       = volcenginecc_alb_server_group.this.id
}

output "listener_id" {
  description = "ID of the ALB listener."
  value       = volcenginecc_alb_listener.this.id
}

locals {
  alb_eip_allocation_ids = distinct(flatten([
    for zm in data.volcenginecc_alb_load_balancer.this.zone_mappings : [
      for addr in zm.load_balancer_addresses : addr.eip_id
    ]
  ]))

  alb_eip_addresses = distinct(flatten([
    for zm in data.volcenginecc_alb_load_balancer.this.zone_mappings : [
      for addr in zm.load_balancer_addresses : addr.eip_address
    ]
  ]))
}

output "alb_eip_allocation_ids" {
  description = "Allocation IDs of all EIPs automatically attached to the ALB."
  value       = local.alb_eip_allocation_ids
}

output "alb_eip_addresses" {
  description = "Public IPv4 addresses of all EIPs automatically attached to the ALB."
  value       = local.alb_eip_addresses
}

# Compatibility outputs for callers that still expect one ALB EIP.
output "alb_eip_allocation_id" {
  description = "First allocation ID of the EIPs automatically attached to the ALB."
  value       = try(local.alb_eip_allocation_ids[0], null)
}

output "alb_eip_address" {
  description = "First public IPv4 address of the EIPs automatically attached to the ALB."
  value       = try(local.alb_eip_addresses[0], null)
}
