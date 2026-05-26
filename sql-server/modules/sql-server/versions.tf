terraform {
  required_version = ">= 1.8"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0, < 2.39.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5, < 3.9.0"
    }
  }
}
