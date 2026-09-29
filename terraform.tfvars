################################################################################
# Example variable values for a quick deploy. Replace placeholders before use.
#
# IMPORTANT:
# - Do NOT commit real credentials or production passwords to source control.
# - Provide AK/SK via VOLCENGINE_ACCESS_KEY / VOLCENGINE_SECRET_KEY env vars.
################################################################################

region       = "cn-beijing"
name_prefix  = "dmz"
project_name = "default"

zones = ["cn-beijing-a", "cn-beijing-c"]

# Three-VPC topology – dmz / dev / prd are required keys (validated).
# Adjust CIDRs / subnets to match your IP plan.
vpcs = {
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

nat_gateway_spec              = "Small"
nat_eip_bandwidth_mbps        = 5
alb_eip_bandwidth_mbps        = 5
shared_bandwidth_package_mbps = 10

alb_config = {
  address_ip_version = "IPv4"
  edition            = "Standard"
  listener_port      = 80
  listener_protocol  = "HTTP"
  health_check_uri   = "/"
}

# Replace image_id with a real Linux image ID in your region.
# Use a strong password and inject it via TF_VAR_ecs_config in production.
ecs_config = {
  instance_type        = "ecs.g3i.large"
  image_id             = "image-yzpyj8j5sl4e0wax4krm" # Rocky Linux 9.5 64 bit (cn-beijing public)
  password             = "ReplaceMe@12345"
  system_volume_type   = "ESSD_PL0"
  system_volume_size   = 50
  instances_per_subnet = 1
}

common_tags = {
  Project     = "dmz-landing-zone"
  Environment = "shared"
  Owner       = "platform-team"
  ManagedBy   = "Terraform"
}
