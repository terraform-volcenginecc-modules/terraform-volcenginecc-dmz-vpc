################################################################################
# tr-vpc module
#
# Encapsulates a single VPC slice of the DMZ landing zone:
#   - VPC + business subnets + TR connection-point subnets (multi-AZ)
#
# NOTE: The TR VPC attachment and the custom route table are intentionally
# created in the ROOT module, not here. This keeps this module free of any
# dependency on root-module resources (the attachment ID), which would
# otherwise create a dependency cycle:
#   module.vpcs (subnets) -> attachment -> module.vpcs (route table).
# Creating the attachments and route tables at the root level also lets them be
# serialized dmz -> dev -> prd, removing the need for `-parallelism=1`.
################################################################################

locals {
  # Distribute subnets round-robin across the available zones.
  business_subnets = {
    for idx, cidr in var.business_subnet_cidrs :
    tostring(idx) => {
      name       = "${var.vpc_name}-biz-subnet-${idx + 1}"
      cidr_block = cidr
      zone_id    = var.zones[idx % length(var.zones)]
    }
  }

  tr_subnets = {
    for idx, cidr in var.tr_subnet_cidrs :
    tostring(idx) => {
      name       = "${var.vpc_name}-tr-subnet-${idx + 1}"
      cidr_block = cidr
      zone_id    = var.zones[idx % length(var.zones)]
    }
  }
}

# VPC – every VPC keeps its own CIDR block. CIDRs are designed not to overlap so
# that TR can route traffic between them without NAT.
resource "volcenginecc_vpc_vpc" "this" {
  vpc_name     = var.vpc_name
  cidr_block   = var.cidr_block
  description  = "DMZ landing zone VPC ${var.vpc_name}"
  project_name = var.project_name
  tags         = var.tags
}

# Business subnets – workloads (ECS, NAT, ALB) are deployed here.
resource "volcenginecc_vpc_subnet" "business" {
  for_each = local.business_subnets

  vpc_id      = volcenginecc_vpc_vpc.this.id
  subnet_name = each.value.name
  cidr_block  = each.value.cidr_block
  zone_id     = each.value.zone_id
  tags        = var.tags
}

# TR subnets – dedicated subnets used as connection points by the Transit
# Router. They are kept separate from business subnets so that operating the
# TR attachment does not interfere with workload subnets.
resource "volcenginecc_vpc_subnet" "tr" {
  for_each = local.tr_subnets

  vpc_id      = volcenginecc_vpc_vpc.this.id
  subnet_name = each.value.name
  cidr_block  = each.value.cidr_block
  zone_id     = each.value.zone_id
  tags        = var.tags
}
