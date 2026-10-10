################################################################################
# alb module
#
# Encapsulates the unified public ingress for the DMZ landing zone:
#   - Public ALB (multi-AZ) deployed in the dmz VPC
#   - HTTP/HTTPS listener forwarding to a server group of backend ECS instances
#     (the prd VPC instances are reachable via the Transit Router)
#   - Server group with IP-type backends and HTTP health checks
################################################################################

# Public ALB – deployed across all dmz business subnets so traffic can be
# distributed across multiple AZs.
resource "volcenginecc_alb_load_balancer" "this" {
  type                       = "public"
  vpc_id                     = var.vpc_id
  load_balancer_name         = var.name
  load_balancer_billing_type = 1
  load_balancer_edition      = var.edition
  address_ip_version         = var.address_ip_version
  description                = "DMZ unified public ingress"
  project_name               = var.project_name

  # The ALB will automatically create a public EIP (pay-as-you-go,
  # billed by traffic) using the configuration below.
  eip_billing_config = {
    isp          = "BGP"
    billing_type = 3
    bandwidth    = var.eip_bandwidth_mbps
  }

  zone_mappings = [
    for idx, sid in var.subnet_ids : {
      subnet_id = sid
      zone_id   = var.zone_ids[idx]
    }
  ]

  tags = var.tags
}

# The resource schema only exposes the configured zone and subnet IDs. Read
# the completed ALB through its data source to obtain the EIPs created per AZ.
data "volcenginecc_alb_load_balancer" "this" {
  id = volcenginecc_alb_load_balancer.this.id
}

# Server group – IP-based backends so the ALB can target ECS instances that
# may sit in a different VPC (prd VPC, reachable via the Transit Router).
resource "volcenginecc_alb_server_group" "this" {
  vpc_id            = var.vpc_id
  server_group_name = "${var.name}-sg"
  server_group_type = "ip"
  protocol          = "HTTP"
  scheduler         = "wrr"
  description       = "ALB backend group hosting prd workloads"
  project_name      = var.project_name

  health_check = {
    enabled             = "on"
    interval            = 2
    timeout             = 2
    method              = "GET"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    uri                 = var.health_check_uri
    port                = var.backend_port
    http_version        = "HTTP1.1"
    http_code           = "http_2xx"
    protocol            = "HTTP"
  }

  sticky_session_config = {
    sticky_session_enabled = "off"
  }

  servers = [
    for ip in var.backend_ips : {
      # For IP-type server groups the Volcengine API expects every nested
      # attribute to be set explicitly; we reuse the IP as instance_id which
      # matches the official landing-zone reference implementation.
      type           = "ip"
      instance_id    = ip
      ip             = ip
      port           = var.backend_port
      weight         = 100
      description    = "prd workload backend"
      remote_enabled = "on"
      server_id      = null
    }
  ]

  # Backend ECS instances are managed elsewhere; ignore drift on the servers
  # set so that scaling backends does not force ALB updates.
  lifecycle {
    ignore_changes = [servers]
  }
}

# Listener – binds the public-facing port to the server group.
resource "volcenginecc_alb_listener" "this" {
  load_balancer_id = volcenginecc_alb_load_balancer.this.id
  listener_name    = "${var.name}-listener"
  protocol         = var.listener_protocol
  port             = var.listener_port
  enabled          = "on"
  server_group_id  = volcenginecc_alb_server_group.this.id
  description      = "Default listener for ${var.name}"

  tags = var.tags
}
