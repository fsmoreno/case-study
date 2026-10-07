terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "name" {
  description = "Nome do repositório."
  type        = string
}

variable "keep_last_images" {
  type    = number
  default = 20
}

variable "tags" {
  type    = map(string)
  default = {}
}

# Tags imutáveis: a mesma tag (SHA do commit) nunca aponta para duas imagens diferentes; viabiliza rollback confiável.
resource "aws_ecr_repository" "this" {
  name                 = var.name
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  # KMS com a chave gerenciada aws/ecr (sem custo extra de chave); CMK própria é uma evolução possível.
  encryption_configuration {
    encryption_type = "KMS"
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Mantém apenas as ${var.keep_last_images} imagens mais recentes (controle de custo de armazenamento)"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.keep_last_images
      }
      action = { type = "expire" }
    }]
  })
}

output "repository_url" {
  value = aws_ecr_repository.this.repository_url
}
