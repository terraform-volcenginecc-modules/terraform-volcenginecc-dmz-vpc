################################################################################
# ecs module
#
# Provisions one or more ECS instances spread across the provided subnets.
#
# Each instance is created in a private subnet of dev or prd VPC and attached
# to the corresponding security group. Instances do NOT receive an EIP – they
# rely on the dmz NAT gateway (for dev) or are addressed via the dmz ALB
# (for prd).
################################################################################

locals {
  # Build a flattened map of instances. For each subnet we create N instances
  # (instances_per_subnet), giving every instance a unique key suitable for
  # for_each.
  instance_specs = {
    for item in flatten([
      for subnet_idx, subnet_id in var.subnet_ids : [
        for inst_idx in range(var.instances_per_subnet) : {
          key       = "${var.name_prefix}-${subnet_idx + 1}-${inst_idx + 1}"
          subnet_id = subnet_id
          zone_id   = var.zone_ids[subnet_idx]
        }
      ]
    ]) : item.key => item
  }
}

resource "volcenginecc_ecs_instance" "this" {
  for_each = local.instance_specs

  instance_name        = each.key
  hostname             = each.key
  description          = "DMZ landing zone workload ${var.name_prefix}"
  instance_charge_type = "PostPaid"
  spot_strategy        = "NoSpot"
  instance_type        = var.instance_type
  password             = var.password
  zone_id              = each.value.zone_id
  project_name         = var.project_name

  image = {
    image_id = var.image_id
  }

  primary_network_interface = {
    subnet_id          = each.value.subnet_id
    security_group_ids = [var.security_group_id]
  }

  system_volume = {
    size                 = var.system_volume_size
    volume_type          = var.system_volume_type
    delete_with_instance = true
  }

  tags = var.tags

  # The volcenginecc Provider currently surfaces several optional read-only
  # fields under nested objects as "(known after apply)" on every plan,
  # leading to spurious in-place updates. Ignore those nested blocks (and the
  # related top-level optionals) so the state stays converged after the
  # initial create.
  lifecycle {
    ignore_changes = [
      image,
      primary_network_interface,
      system_volume,
      affinity_group_size,
      auto_pay,
      auto_renew,
      auto_renew_period,
      cpu_max_frequency,
      credit_specification,
      include_data_volumes,
      install_run_command_agent,
      period,
      period_unit,
    ]
  }
}
