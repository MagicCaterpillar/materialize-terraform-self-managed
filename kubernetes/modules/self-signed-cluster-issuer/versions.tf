terraform {
  required_version = ">= 1.0.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.10.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "2.4.0"
    }
  }
}
