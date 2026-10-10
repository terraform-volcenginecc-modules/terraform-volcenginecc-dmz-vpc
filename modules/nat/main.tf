################################################################################
# nat module
#
# Encapsulates the unified public egress for the DMZ landing zone:
#   - Public NAT gateway in the dmz VPC's first business subnet
#   - Pay-as-you-go EIP attached to the NAT gateway
#   - SNAT entries for each upstream VPC CIDR (typically dev VPC)
################################################################################

# Public NAT Gateway – placed in the dmz VPC and used by every other VPC for
# outbound Internet access via Transit Router.
resource "volcenginecc_natgateway_ngw" "this" {
  vpc_id           = var.vpc_id
  subnet_id        = var.subnet_id
  nat_gateway_name = var.name
  spec             = var.spec
  network_type     = "internet"
  billing_type     = 2
  description      = "DMZ unified egress NAT gateway"
  project_name     = var.project_name
  tags             = var.tags
}

# Let the NAT control plane observe the EIP as fully detached before deleting
# the gateway. With destroy-only timing, this does not delay creation.
resource "time_sleep" "before_nat_gateway_destroy" {
  destroy_duration = "30s"

  depends_on = [volcenginecc_natgateway_ngw.this]
}

# EIP for NAT – pay-as-you-go BGP. Bound directly to the NAT gateway via
# instance_id/instance_type, which replaces the legacy
# `volcengine_eip_associate` resource used in the original landing-zone code.
resource "volcenginecc_vpc_eip" "nat" {
  name                 = "${var.name}-eip"
  description          = "EIP attached to ${var.name}"
  isp                  = "BGP"
  billing_type         = 2
  bandwidth            = var.eip_bandwidth_mbps
  project_name         = var.project_name
  instance_id          = volcenginecc_natgateway_ngw.this.id
  instance_type        = "Nat"
  bandwidth_package_id = var.bandwidth_package_id
  tags                 = var.tags

  depends_on = [time_sleep.before_nat_gateway_destroy]
}

# SNAT entries – one per upstream CIDR. Traffic from each source CIDR is
# masquerated through the NAT EIP when leaving the VPC.
resource "volcenginecc_natgateway_snatentry" "this" {
  for_each = { for idx, cidr in var.snat_source_cidrs : tostring(idx) => cidr }

  nat_gateway_id  = volcenginecc_natgateway_ngw.this.id
  eip_id          = volcenginecc_vpc_eip.nat.allocation_id
  source_cidr     = each.value
  snat_entry_name = "${var.name}-snat-${each.key}"
}
