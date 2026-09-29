output "vpc_id" {
  description = "ID of the VPC."
  value       = volcenginecc_vpc_vpc.this.id
}

output "vpc_name" {
  description = "Name of the VPC."
  value       = volcenginecc_vpc_vpc.this.vpc_name
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC."
  value       = volcenginecc_vpc_vpc.this.cidr_block
}

output "business_subnet_ids" {
  description = "Ordered list of business subnet IDs."
  value       = [for k in sort(keys(volcenginecc_vpc_subnet.business)) : volcenginecc_vpc_subnet.business[k].id]
}

output "business_subnet_zone_ids" {
  description = "Ordered list of business subnet zone IDs (parallel to business_subnet_ids)."
  value       = [for k in sort(keys(volcenginecc_vpc_subnet.business)) : volcenginecc_vpc_subnet.business[k].zone_id]
}

output "tr_subnet_ids" {
  description = "Ordered list of TR connection-point subnet IDs."
  value       = [for k in sort(keys(volcenginecc_vpc_subnet.tr)) : volcenginecc_vpc_subnet.tr[k].id]
}

output "route_table_id" {
  description = "ID of the custom route table associated with the VPC (null if create_route_table = false)."
  value       = try(volcenginecc_vpc_route_table.this[0].id, null)
}

output "tr_attachment_id" {
  description = "ID of the TR VPC attachment."
  value       = volcenginecc_transitrouter_vpc_attachment.this.transit_router_attachment_id
}
