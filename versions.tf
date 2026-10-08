terraform {
  required_version = ">= 1.4.0"

  required_providers {
    volcenginecc = {
      source  = "volcengine/volcenginecc"
      version = "~> 0.0.70"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}
