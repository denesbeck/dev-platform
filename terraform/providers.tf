terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.11"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "aws" {
  region = "eu-central-1"

  default_tags {
    tags = {
      App       = "dev-platform"
      ManagedBy = "terraform"
    }
  }
}
