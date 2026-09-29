locals {
  # Convert the map-style common_tags into the [{ key, value }] list format
  # expected by every volcenginecc resource.
  common_tags_list = [for k, v in var.common_tags : { key = k, value = v }]

  # Core VPC keys we reference repeatedly.
  dmz_key = "dmz"
  dev_key = "dev"
  prd_key = "prd"
}
