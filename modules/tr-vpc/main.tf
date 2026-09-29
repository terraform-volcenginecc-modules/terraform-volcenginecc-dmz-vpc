################################################################################
# tr-vpc module
#
# Encapsulates a single VPC slice of the DMZ landing zone:
#   - VPC + business subnets + TR connection-point subnets (multi-AZ)
#   - Custom route table that forwards RFC1918 traffic (and optionally the
#     default route) to the central Transit Router
#   - VPC Attachment that connects the VPC to the Transit Router
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

  # Static routes pushed into the VPC route table.
  # Internal CIDRs always go via TR; outbound (default) is enabled per VPC.
  internal_route_entries = [
    for cidr in var.internal_route_cidrs : {
      destination_cidr_block = cidr
      next_hop_type          = "TransitRouter"
      next_hop_id            = var.transit_router_id
      description            = "RFC1918 traffic via Transit Router"
    }
  ]
  outbound_route_entries = var.outbound ? [{
    destination_cidr_block = "0.0.0.0/0"
    next_hop_type          = "TransitRouter"
    next_hop_id            = var.transit_router_id
    description            = "Default route via Transit Router for unified egress through dmz NAT"
  }] : []

  custom_route_entries = concat(
    local.internal_route_entries,
    local.outbound_route_entries,
    var.extra_route_entries,
  )
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

# Custom route table – a dedicated route table is created and associated with
# every business subnet so we have full control over the routing entries.
# When the caller needs to inject route entries that reference resources
# created outside this module (e.g. a NAT gateway in the dmz VPC), set
# create_route_table = false and create the route table externally.
resource "volcenginecc_vpc_route_table" "this" {
  count = var.create_route_table ? 1 : 0

  vpc_id           = volcenginecc_vpc_vpc.this.id
  route_table_name = "${var.vpc_name}-rt"
  description      = "Custom route table for ${var.vpc_name}"
  project_name     = var.project_name
  subnet_ids       = [for s in volcenginecc_vpc_subnet.business : s.id]

  custom_route_entries = [
    for entry in local.custom_route_entries : {
      destination_cidr_block = entry.destination_cidr_block
      next_hop_type          = entry.next_hop_type
      next_hop_id            = entry.next_hop_id
      description            = entry.description
    }
  ]

  tags = var.tags

  # The route table references the Transit Router as a next hop, which
  # requires the VPC attachment to exist first; otherwise the API rejects the
  # custom route entry with "InvalidGroup.NotFound: RouteNextHopGroup".
  depends_on = [volcenginecc_transitrouter_vpc_attachment.this]
}

# TR VPC Attachment – attaches the VPC to the central Transit Router and
# automatically publishes routes back to the VPC where appropriate.
resource "volcenginecc_transitrouter_vpc_attachment" "this" {
  transit_router_id              = var.transit_router_id
  vpc_id                         = volcenginecc_vpc_vpc.this.id
  transit_router_attachment_name = "${var.vpc_name}-attach"
  description                    = "Attachment between TR and ${var.vpc_name}"
  auto_publish_route_enabled     = true

  attach_points = [
    for s in volcenginecc_vpc_subnet.tr : {
      subnet_id = s.id
      zone_id   = s.zone_id
    }
  ]

  tags = var.tags
}
