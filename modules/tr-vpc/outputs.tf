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

output "tr_attach_points" {
  description = "Ordered list of { subnet_id, zone_id } connection points for the TR VPC attachment (created in the root module)."
  value = [
    for k in sort(keys(volcenginecc_vpc_subnet.tr)) : {
      subnet_id = volcenginecc_vpc_subnet.tr[k].id
      zone_id   = volcenginecc_vpc_subnet.tr[k].zone_id
    }
  ]
}
