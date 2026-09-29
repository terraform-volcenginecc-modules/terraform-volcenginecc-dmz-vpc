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

# The ALB-managed EIP allocation – used to register the ALB EIP into the
# shared bandwidth package alongside the NAT EIP. zone_mappings is a Set so
# we flatten and pick the first entry.
output "alb_eip_allocation_id" {
  description = "Allocation ID of the EIP automatically attached to the ALB."
  value = try(
    [
      for zm in tolist(volcenginecc_alb_load_balancer.this.zone_mappings) :
      [for addr in tolist(zm.load_balancer_addresses) : addr.eip_id][0]
    ][0],
    null,
  )
}

output "alb_eip_address" {
  description = "Public IPv4 address of the ALB EIP."
  value = try(
    [
      for zm in tolist(volcenginecc_alb_load_balancer.this.zone_mappings) :
      [for addr in tolist(zm.load_balancer_addresses) : addr.eip_address][0]
    ][0],
    null,
  )
}
