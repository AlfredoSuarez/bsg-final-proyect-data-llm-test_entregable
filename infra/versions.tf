terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Backend remoto recomendado para Fase 1.1.
  # Mientras tanto el state vive local (excluido por .gitignore).
  # backend "s3" {
  #   bucket         = "bsg-acmeco-tfstate"
  #   key            = "rag-pipeline/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "terraform-locks"
  #   encrypt        = true
  # }
}
