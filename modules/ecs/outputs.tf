output "instance_ids" {
  description = "Map of instance_name → instance_id."
  value       = { for k, v in volcenginecc_ecs_instance.this : k => v.instance_id }
}

output "private_ips" {
  description = "Map of instance_name → primary private IP."
  value       = { for k, v in volcenginecc_ecs_instance.this : k => v.primary_network_interface.primary_ip_address }
}

output "private_ip_list" {
  description = "Sorted list of primary private IPs (handy for ALB backend wiring)."
  value = [
    for k in sort(keys(volcenginecc_ecs_instance.this)) :
    volcenginecc_ecs_instance.this[k].primary_network_interface.primary_ip_address
  ]
}
