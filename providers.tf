# Provider configuration is centralized in the root module only.
# Credentials should be supplied via environment variables (VOLCENGINE_ACCESS_KEY /
# VOLCENGINE_SECRET_KEY) instead of being hard-coded here.
provider "volcenginecc" {
  region = var.region
}
