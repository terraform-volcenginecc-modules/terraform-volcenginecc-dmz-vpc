################################################################################
# DMZ Landing Zone – root orchestration
#
# Creates a centralised public-egress / public-ingress hub on Volcengine using
# a Transit Router that interconnects three VPCs (dmz / dev / prd):
#
#   ┌────────────┐        ┌──────────────────┐        ┌────────────┐
#   │ Internet   │ <────> │  dmz VPC         │ <────> │ Transit    │
#   └────────────┘        │   - public ALB   │        │ Router     │
#                         │   - NAT gateway  │        └─────┬──────┘
#                         └──────────────────┘              │
#                                                           ├── dev VPC (egress)
#                                                           └── prd VPC (workload)
################################################################################

# ---------------------------------------------------------------------------
# Transit Router – central routing fabric
# ---------------------------------------------------------------------------
resource "volcenginecc_transitrouter_transit_router" "main" {
  transit_router_name = coalesce(var.tr_config.name, "${var.name_prefix}-tr")
  description         = coalesce(var.tr_config.description, "DMZ landing zone transit router")
  asn                 = var.tr_config.asn
  project_name        = var.project_name
  tags                = local.common_tags_list
}

# ---------------------------------------------------------------------------
# Three VPCs (dmz / dev / prd) – each with business + TR subnets and a custom
# route table that forwards RFC1918 (and optionally default) traffic via TR.
# ---------------------------------------------------------------------------
module "vpcs" {
  source   = "./modules/tr-vpc"
  for_each = var.vpcs

  vpc_name              = "${var.name_prefix}-${each.key}"
  cidr_block            = each.value.cidr_block
  business_subnet_cidrs = each.value.business_subnet_cidrs
  tr_subnet_cidrs       = each.value.tr_subnet_cidrs
  zones                 = var.zones
  project_name          = var.project_name
  tags                  = local.common_tags_list
}

# ---------------------------------------------------------------------------
# TR VPC Attachments – created at the root level and chained dmz -> dev -> prd
# so that only one attach operation hits the Transit Router at a time. The TR
# rejects concurrent attach / route-table operations with
# InvalidTransitRouterAttachment.InvalidStatus / InvalidTransitRouter.
# InvalidStatus, which previously forced `terraform apply -parallelism=1`.
#
# The three attachments are declared as separate resources (rather than
# for_each/count) so each can explicitly depend_on the previous one, forming a
# strict dmz -> dev -> prd chain that Terraform will never run concurrently.
# ---------------------------------------------------------------------------
resource "volcenginecc_transitrouter_vpc_attachment" "dmz" {
  transit_router_id              = volcenginecc_transitrouter_transit_router.main.transit_router_id
  vpc_id                         = module.vpcs[local.dmz_key].vpc_id
  transit_router_attachment_name = "${var.name_prefix}-${local.dmz_key}-attach"
  description                    = "Attachment between TR and ${var.name_prefix}-${local.dmz_key}"
  auto_publish_route_enabled     = true
  attach_points                  = module.vpcs[local.dmz_key].tr_attach_points
  tags                           = local.common_tags_list
}

resource "volcenginecc_transitrouter_vpc_attachment" "dev" {
  transit_router_id              = volcenginecc_transitrouter_transit_router.main.transit_router_id
  vpc_id                         = module.vpcs[local.dev_key].vpc_id
  transit_router_attachment_name = "${var.name_prefix}-${local.dev_key}-attach"
  description                    = "Attachment between TR and ${var.name_prefix}-${local.dev_key}"
  auto_publish_route_enabled     = true
  attach_points                  = module.vpcs[local.dev_key].tr_attach_points
  tags                           = local.common_tags_list

  # Wait for the dmz attachment so only one attach hits the TR at a time.
  depends_on = [volcenginecc_transitrouter_vpc_attachment.dmz]
}

resource "volcenginecc_transitrouter_vpc_attachment" "prd" {
  transit_router_id              = volcenginecc_transitrouter_transit_router.main.transit_router_id
  vpc_id                         = module.vpcs[local.prd_key].vpc_id
  transit_router_attachment_name = "${var.name_prefix}-${local.prd_key}-attach"
  description                    = "Attachment between TR and ${var.name_prefix}-${local.prd_key}"
  auto_publish_route_enabled     = true
  attach_points                  = module.vpcs[local.prd_key].tr_attach_points
  tags                           = local.common_tags_list

  # Wait for the dev attachment to keep the dmz -> dev -> prd chain serial.
  depends_on = [volcenginecc_transitrouter_vpc_attachment.dev]
}

# Map each VPC key to its attachment ID so associations / propagations / route
# tables can look attachments up by key.
locals {
  tr_attachment_id_by_key = {
    (local.dmz_key) = volcenginecc_transitrouter_vpc_attachment.dmz.transit_router_attachment_id
    (local.dev_key) = volcenginecc_transitrouter_vpc_attachment.dev.transit_router_attachment_id
    (local.prd_key) = volcenginecc_transitrouter_vpc_attachment.prd.transit_router_attachment_id
  }
}

# ---------------------------------------------------------------------------
# Serialization wait #2 – let the Transit Router settle AFTER all three VPC
# attachments are created and BEFORE the TR route table is created.
#
# Only `destroy_duration` is set, so apply is NOT slowed down. On destroy the
# dependency reverses: the TR route table is deleted first, then this resource
# waits 10s (giving the TR time to leave its transient state) before the three
# attachments are deleted – avoiding InvalidTransitRouterAttachment.InvalidStatus
# / InvalidTransitRouter.InvalidStatus during teardown.
# ---------------------------------------------------------------------------
resource "time_sleep" "after_attachments" {
  destroy_duration = "10s"

  depends_on = [
    volcenginecc_transitrouter_vpc_attachment.dmz,
    volcenginecc_transitrouter_vpc_attachment.dev,
    volcenginecc_transitrouter_vpc_attachment.prd,
  ]
}

# ---------------------------------------------------------------------------
# Transit Router route table + associations + propagations.
#
# The volcenginecc (Cloud-Control) provider does NOT actually publish VPC CIDRs
# into any TR route table via `auto_publish_route_enabled`, so cross-VPC traffic
# (dmz<->prd for ALB backends, dev<->dmz for egress) is black-holed at the TR.
#
# To make the TR forward traffic we explicitly:
#   1. Create a custom TR route table.
#   2. Associate every VPC attachment to it (decides which table an attachment
#      consults for outbound lookups).
#   3. Propagate every VPC attachment into it (installs each VPC's CIDR as a
#      route pointing back at its own attachment).
# ---------------------------------------------------------------------------
resource "volcenginecc_transitrouter_transit_router_route_table" "main" {
  transit_router_id               = volcenginecc_transitrouter_transit_router.main.transit_router_id
  transit_router_route_table_name = "${var.name_prefix}-tr-rt"
  description                     = "Custom TR route table interconnecting dmz dev prd VPCs"
  tags                            = local.common_tags_list

  # Created after the attachments settle; on destroy this table is removed
  # before the attachments (which then wait via time_sleep.after_attachments).
  depends_on = [time_sleep.after_attachments]
}

# ---------------------------------------------------------------------------
# Serialization wait #1 – let the Transit Router / route table settle AFTER the
# route table is created and BEFORE associations/propagations are created.
#
# On destroy the dependency reverses: all associations/propagations are deleted
# first, then this resource waits 10s before the TR route table is deleted –
# this is exactly the step that previously failed with
# InvalidTransitRouter.InvalidStatus during teardown.
# ---------------------------------------------------------------------------
resource "time_sleep" "after_tr_route_table" {
  destroy_duration = "10s"

  depends_on = [volcenginecc_transitrouter_transit_router_route_table.main]
}

# Associate every VPC attachment with the custom TR route table so that traffic
# entering the TR from any VPC is looked up against a table that knows all VPCs.
#
# Associations and propagations all mutate the same TR route table and must not
# run concurrently (InvalidTransitRouter.InvalidStatus). They are therefore
# declared as separate, explicitly chained resources in a fixed order:
#   assoc dmz -> assoc dev -> assoc prd -> prop dmz -> prop dev -> prop prd
# This removes the need for `terraform apply -parallelism=1`.
resource "volcenginecc_transitrouter_transit_router_route_table_association" "dmz" {
  transit_router_attachment_id  = local.tr_attachment_id_by_key[local.dmz_key]
  transit_router_route_table_id = volcenginecc_transitrouter_transit_router_route_table.main.transit_router_route_table_id

  depends_on = [time_sleep.after_tr_route_table]
}

resource "volcenginecc_transitrouter_transit_router_route_table_association" "dev" {
  transit_router_attachment_id  = local.tr_attachment_id_by_key[local.dev_key]
  transit_router_route_table_id = volcenginecc_transitrouter_transit_router_route_table.main.transit_router_route_table_id

  depends_on = [volcenginecc_transitrouter_transit_router_route_table_association.dmz]
}

resource "volcenginecc_transitrouter_transit_router_route_table_association" "prd" {
  transit_router_attachment_id  = local.tr_attachment_id_by_key[local.prd_key]
  transit_router_route_table_id = volcenginecc_transitrouter_transit_router_route_table.main.transit_router_route_table_id

  depends_on = [volcenginecc_transitrouter_transit_router_route_table_association.dev]
}

# Propagate every VPC attachment into the custom TR route table so each VPC's
# CIDR is installed as a route pointing back at its attachment. This is what was
# missing and caused the ALB health checks / cross-VPC pings to fail. The
# propagations run after all associations, still strictly one at a time.
resource "volcenginecc_transitrouter_route_table_propagation" "dmz" {
  transit_router_attachment_id  = local.tr_attachment_id_by_key[local.dmz_key]
  transit_router_route_table_id = volcenginecc_transitrouter_transit_router_route_table.main.transit_router_route_table_id

  depends_on = [volcenginecc_transitrouter_transit_router_route_table_association.prd]
}

resource "volcenginecc_transitrouter_route_table_propagation" "dev" {
  transit_router_attachment_id  = local.tr_attachment_id_by_key[local.dev_key]
  transit_router_route_table_id = volcenginecc_transitrouter_transit_router_route_table.main.transit_router_route_table_id

  depends_on = [volcenginecc_transitrouter_route_table_propagation.dmz]
}

resource "volcenginecc_transitrouter_route_table_propagation" "prd" {
  transit_router_attachment_id  = local.tr_attachment_id_by_key[local.prd_key]
  transit_router_route_table_id = volcenginecc_transitrouter_transit_router_route_table.main.transit_router_route_table_id

  depends_on = [volcenginecc_transitrouter_route_table_propagation.dev]
}

# ---------------------------------------------------------------------------
# Per-VPC security groups – uniform baseline rules plus an extra rule that
# accepts traffic from the dmz business subnets (where the ALB sits), so that
# the ALB can reach prd backends across VPCs.
# ---------------------------------------------------------------------------
locals {
  dmz_business_cidrs = [
    for cidr in var.vpcs[local.dmz_key].business_subnet_cidrs : cidr
  ]

  # ingress rules: shared baseline, plus ALB back-source for non-dmz VPCs.
  ingress_rules_per_vpc = {
    for k in keys(var.vpcs) : k => concat(
      var.default_ingress_rules,
      k == local.dmz_key ? [] : [
        for cidr in local.dmz_business_cidrs : {
          policy      = "Accept"
          port_start  = 1
          port_end    = 65535
          protocol    = "TCP"
          priority    = 10
          cidr_ip     = cidr
          description = "ALB back-source rule from dmz subnet"
        }
      ],
    )
  }
}

resource "volcenginecc_vpc_security_group" "this" {
  for_each = var.vpcs

  vpc_id              = module.vpcs[each.key].vpc_id
  security_group_name = "${var.name_prefix}-${each.key}-sg"
  description         = "Default security group for ${each.key} VPC"
  project_name        = var.project_name

  ingress_permissions = [
    for r in local.ingress_rules_per_vpc[each.key] : {
      policy      = lower(r.policy) == "accept" ? "accept" : "drop"
      port_start  = r.port_start
      port_end    = r.port_end
      protocol    = lower(r.protocol)
      priority    = r.priority
      cidr_ip     = r.cidr_ip
      description = r.description
    }
  ]

  tags = local.common_tags_list
}

# ---------------------------------------------------------------------------
# Public NAT Gateway in dmz VPC – unified public egress for the landing zone.
# The dev VPC's CIDR is registered as a SNAT source so its workloads can reach
# the Internet via this NAT (over the Transit Router).
# ---------------------------------------------------------------------------
module "nat" {
  source = "./modules/nat"

  name   = "${var.name_prefix}-nat"
  vpc_id = module.vpcs[local.dmz_key].vpc_id
  # Place the NAT gateway in the second dmz business subnet to keep the first
  # subnet free for the ALB (matches the original landing-zone topology).
  subnet_id          = module.vpcs[local.dmz_key].business_subnet_ids[1]
  spec               = var.nat_gateway_spec
  eip_bandwidth_mbps = var.nat_eip_bandwidth_mbps
  snat_source_cidrs  = [var.vpcs[local.dev_key].cidr_block]
  project_name       = var.project_name
  tags               = local.common_tags_list
}

# ---------------------------------------------------------------------------
# dmz VPC route table – managed at the root level because its custom route
# entries must reference the NAT gateway created above. The route table:
#   - Sends 0.0.0.0/0 to the local NAT gateway (so dev egress traffic that
#     enters dmz via TR can leave through the NAT).
#   - Sends each non-dmz VPC CIDR back to the Transit Router so ALB return
#     traffic to prd workloads is reachable.
# ---------------------------------------------------------------------------
locals {
  dmz_route_entries = concat(
    [
      {
        destination_cidr_block = "0.0.0.0/0"
        next_hop_type          = "NatGW"
        next_hop_id            = module.nat.nat_gateway_id
        description            = "dmz default route to NAT gateway"
      }
    ],
    [
      for k, v in var.vpcs : {
        destination_cidr_block = v.cidr_block
        next_hop_type          = "TransitRouter"
        next_hop_id            = volcenginecc_transitrouter_transit_router.main.transit_router_id
        description            = "Return route to ${k} VPC via TR"
      } if k != local.dmz_key
    ],
  )
}

resource "volcenginecc_vpc_route_table" "dmz" {
  vpc_id           = module.vpcs[local.dmz_key].vpc_id
  route_table_name = "${var.name_prefix}-${local.dmz_key}-rt"
  description      = "Custom route table for dmz VPC with NAT and TR return paths"
  project_name     = var.project_name

  # Bind the route table to all dmz business subnets so both ALB and NAT
  # subnets share the same routing decisions.
  subnet_ids = module.vpcs[local.dmz_key].business_subnet_ids

  custom_route_entries = [
    for entry in local.dmz_route_entries : {
      destination_cidr_block = entry.destination_cidr_block
      next_hop_type          = entry.next_hop_type
      next_hop_id            = entry.next_hop_id
      description            = entry.description
    }
  ]

  tags = local.common_tags_list

  # Routes that reference the Transit Router require the dmz VPC attachment to
  # exist beforehand, otherwise the API rejects the entries.
  depends_on = [volcenginecc_transitrouter_vpc_attachment.dmz]
}

# ---------------------------------------------------------------------------
# dev / prd VPC route tables – also managed at the root level (previously built
# inside the tr-vpc module). Keeping them here avoids a dependency cycle: the
# route tables need the TR attachment ID, and the attachments need the module's
# subnets. All non-dmz VPCs forward RFC1918 traffic (and, when outbound = true,
# the default route) to the Transit Router.
# ---------------------------------------------------------------------------
locals {
  non_dmz_route_entries = {
    for k, v in var.vpcs : k => concat(
      [
        for cidr in var.vpc_internal_route_cidrs : {
          destination_cidr_block = cidr
          next_hop_type          = "TransitRouter"
          next_hop_id            = volcenginecc_transitrouter_transit_router.main.transit_router_id
          description            = "RFC1918 traffic via Transit Router"
        }
      ],
      v.outbound ? [{
        destination_cidr_block = "0.0.0.0/0"
        next_hop_type          = "TransitRouter"
        next_hop_id            = volcenginecc_transitrouter_transit_router.main.transit_router_id
        description            = "Default route via Transit Router for unified egress through dmz NAT"
      }] : [],
    ) if k != local.dmz_key
  }
}

resource "volcenginecc_vpc_route_table" "non_dmz" {
  for_each = local.non_dmz_route_entries

  vpc_id           = module.vpcs[each.key].vpc_id
  route_table_name = "${var.name_prefix}-${each.key}-rt"
  description      = "Custom route table for ${each.key} VPC"
  project_name     = var.project_name
  subnet_ids       = module.vpcs[each.key].business_subnet_ids

  custom_route_entries = [
    for entry in each.value : {
      destination_cidr_block = entry.destination_cidr_block
      next_hop_type          = entry.next_hop_type
      next_hop_id            = entry.next_hop_id
      description            = entry.description
    }
  ]

  tags = local.common_tags_list

  # TransitRouter next hops require this VPC's attachment to exist first.
  depends_on = [
    volcenginecc_transitrouter_vpc_attachment.dev,
    volcenginecc_transitrouter_vpc_attachment.prd,
  ]
}

# ---------------------------------------------------------------------------
# Workload ECS instances for dev and prd VPCs (no instances in dmz). The
# instances are spread across business subnets/AZs and use the per-VPC SG.
# ---------------------------------------------------------------------------
module "ecs_dev" {
  source = "./modules/ecs"

  name_prefix          = "${var.name_prefix}-dev"
  subnet_ids           = module.vpcs[local.dev_key].business_subnet_ids
  zone_ids             = module.vpcs[local.dev_key].business_subnet_zone_ids
  security_group_id    = volcenginecc_vpc_security_group.this[local.dev_key].security_group_id
  instance_type        = var.ecs_config.instance_type
  image_id             = var.ecs_config.image_id
  password             = var.ecs_config.password
  system_volume_size   = var.ecs_config.system_volume_size
  system_volume_type   = var.ecs_config.system_volume_type
  instances_per_subnet = var.ecs_config.instances_per_subnet
  project_name         = var.project_name
  tags                 = local.common_tags_list
}

module "ecs_prd" {
  source = "./modules/ecs"

  name_prefix          = "${var.name_prefix}-prd"
  subnet_ids           = module.vpcs[local.prd_key].business_subnet_ids
  zone_ids             = module.vpcs[local.prd_key].business_subnet_zone_ids
  security_group_id    = volcenginecc_vpc_security_group.this[local.prd_key].security_group_id
  instance_type        = var.ecs_config.instance_type
  image_id             = var.ecs_config.image_id
  password             = var.ecs_config.password
  system_volume_size   = var.ecs_config.system_volume_size
  system_volume_type   = var.ecs_config.system_volume_type
  instances_per_subnet = var.ecs_config.instances_per_subnet
  project_name         = var.project_name
  tags                 = local.common_tags_list
}

# ---------------------------------------------------------------------------
# Public ALB in dmz VPC – unified public ingress targeting prd workloads.
# ALB backend IPs come from the prd ECS module output. Backend reachability
# relies on the Transit Router (dmz↔prd) plus the SG rule that accepts ALB
# back-source traffic.
# ---------------------------------------------------------------------------
module "alb" {
  source = "./modules/alb"

  name               = "${var.name_prefix}-alb"
  vpc_id             = module.vpcs[local.dmz_key].vpc_id
  subnet_ids         = module.vpcs[local.dmz_key].business_subnet_ids
  zone_ids           = module.vpcs[local.dmz_key].business_subnet_zone_ids
  address_ip_version = var.alb_config.address_ip_version
  edition            = var.alb_config.edition
  eip_bandwidth_mbps = var.alb_eip_bandwidth_mbps
  listener_port      = var.alb_config.listener_port
  listener_protocol  = var.alb_config.listener_protocol
  health_check_uri   = var.alb_config.health_check_uri
  backend_port       = 80
  backend_ips        = module.ecs_prd.private_ip_list
  project_name       = var.project_name
  tags               = local.common_tags_list
}

# ---------------------------------------------------------------------------
# Shared Bandwidth Package – aggregates the NAT EIP and the ALB EIP so they
# share a single bandwidth budget (the central "公网出入口" optimisation).
# ---------------------------------------------------------------------------
resource "volcenginecc_vpc_bandwidth_package" "shared" {
  bandwidth_package_name = "${var.name_prefix}-shared-bp"
  description            = "Shared bandwidth package aggregating NAT and ALB EIPs"
  billing_type           = 2
  isp                    = "BGP"
  bandwidth              = var.shared_bandwidth_package_mbps
  protocol               = "IPv4"
  project_name           = var.project_name

  eip_addresses = concat(
    [{ allocation_id = module.nat.eip_id }],
    [for allocation_id in module.alb.alb_eip_allocation_ids : {
      allocation_id = allocation_id
    }],
  )

  tags = local.common_tags_list
}

# ---------------------------------------------------------------------------
# Transit Router static default route – unified egress (dev VPC -> TR -> dmz NAT).
#
# Propagations only install each VPC's own CIDR into the TR route table, so a
# 0.0.0.0/0 route toward the dmz attachment must be added explicitly. Traffic
# from the dev VPC whose default route points at the TR is then forwarded into
# the dmz VPC, where the dmz route table sends it out through the NAT gateway.
# ---------------------------------------------------------------------------
resource "volcenginecc_transitrouter_transit_router_route_entry" "default_egress" {
  transit_router_route_table_id            = volcenginecc_transitrouter_transit_router_route_table.main.transit_router_route_table_id
  destination_cidr_block                   = "0.0.0.0/0"
  transit_router_route_entry_next_hop_type = "Attachment"
  transit_router_route_entry_next_hop_id   = local.tr_attachment_id_by_key[local.dmz_key]
  transit_router_route_entry_name          = "${var.name_prefix}-tr-default-egress"
  description                              = "Default route to dmz attachment for unified NAT egress"

  # The next-hop attachment must already be associated/propagated in the table.
  # Depend on the last link of the association/propagation chain so this static
  # route is created only after the whole table has settled.
  depends_on = [
    volcenginecc_transitrouter_route_table_propagation.prd,
  ]
}
