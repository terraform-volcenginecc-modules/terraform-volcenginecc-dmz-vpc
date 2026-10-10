################################################################################
# Root module outputs
################################################################################

output "transit_router_id" {
  description = "ID of the central Transit Router."
  value       = volcenginecc_transitrouter_transit_router.main.transit_router_id
}

output "transit_router_route_table_id" {
  description = "ID of the custom TR route table interconnecting the VPCs."
  value       = volcenginecc_transitrouter_transit_router_route_table.main.transit_router_route_table_id
}

output "vpc_ids" {
  description = "Map of VPC alias (dmz/dev/prd) → VPC ID."
  value       = { for k, m in module.vpcs : k => m.vpc_id }
}

output "vpc_route_table_ids" {
  description = "Map of VPC alias → custom route table ID."
  value = merge(
    { for k, rt in volcenginecc_vpc_route_table.non_dmz : k => rt.id },
    { (local.dmz_key) = volcenginecc_vpc_route_table.dmz.id },
  )
}

output "tr_attachment_ids" {
  description = "Map of VPC alias → Transit Router VPC attachment ID."
  value       = local.tr_attachment_id_by_key
}

output "security_group_ids" {
  description = "Map of VPC alias → security group ID."
  value       = { for k, sg in volcenginecc_vpc_security_group.this : k => sg.security_group_id }
}

output "nat_gateway_id" {
  description = "ID of the dmz NAT gateway."
  value       = module.nat.nat_gateway_id
}

output "nat_eip_address" {
  description = "Public IPv4 address of the NAT EIP."
  value       = module.nat.eip_address
}

output "alb_id" {
  description = "ID of the public ALB."
  value       = module.alb.alb_id
}

output "alb_dns_name" {
  description = "DNS name of the public ALB."
  value       = module.alb.alb_dns_name
}

output "alb_eip_address" {
  description = "First public IPv4 address of the ALB EIPs."
  value       = module.alb.alb_eip_address
}

output "alb_eip_addresses" {
  description = "Public IPv4 addresses of all ALB EIPs."
  value       = module.alb.alb_eip_addresses
}

output "shared_bandwidth_package_id" {
  description = "ID of the shared bandwidth package aggregating NAT and ALB EIPs."
  value       = volcenginecc_vpc_bandwidth_package.shared.bandwidth_package_id
}

output "dev_instance_ids" {
  description = "Map of dev workload instance name → ID."
  value       = module.ecs_dev.instance_ids
}

output "prd_instance_ids" {
  description = "Map of prd workload instance name → ID."
  value       = module.ecs_prd.instance_ids
}

output "prd_backend_ips" {
  description = "Private IPs of prd workloads, registered as ALB backends."
  value       = module.ecs_prd.private_ip_list
}
