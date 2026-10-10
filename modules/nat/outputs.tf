output "nat_gateway_id" {
  description = "ID of the NAT gateway."
  value       = volcenginecc_natgateway_ngw.this.id
}

output "eip_id" {
  description = "Allocation ID of the EIP attached to the NAT gateway."
  value       = volcenginecc_vpc_eip.nat.allocation_id
}

output "eip_address" {
  description = "Public IPv4 address of the NAT EIP."
  value       = volcenginecc_vpc_eip.nat.eip_address
}
