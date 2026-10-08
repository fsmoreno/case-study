# Ambiente PRODUÇÃO (hipotético). Código validado (fmt/validate/tflint) e escaneado (Checkov); NUNCA aplicado.
# Compõe os mesmos módulos network, rds e secrets do ambiente local, mais eks, iam-irsa e ecr.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # State remoto, criptografado e com lock nativo do S3. O bucket é criado fora deste código (bootstrap),
  # com versionamento, bloqueio de acesso público e acesso restrito. `terraform init -backend=false` ignora este bloco.
  backend "s3" {
    bucket       = "estuda-tfstate-REPLACE_ME"
    key          = "prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

locals {
  name = "estuda"
  tags = {
    Project     = "estuda"
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}

module "network" {
  source = "../../modules/network"

  name             = local.name
  azs              = var.azs
  enable_nat       = true # UM NAT compartilhado (custo); ver docs/custos para a alternativa de 1 NAT por AZ
  enable_flow_logs = true
  eks_cluster_name = local.name
  tags             = local.tags
}

module "eks" {
  source = "../../modules/eks"

  name                = local.name
  subnet_ids          = module.network.private_subnet_ids
  public_access_cidrs = var.eks_public_access_cidrs
  node_capacity_type  = var.node_capacity_type
  tags                = local.tags
}

module "rds" {
  source = "../../modules/rds"

  name       = local.name
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.private_subnet_ids

  # Somente os nós do EKS alcançam o banco, na porta 3306.
  allowed_security_group_ids = [module.eks.cluster_security_group_id]

  db_name         = "estuda"
  master_username = "estuda"
  multi_az        = var.rds_multi_az # padrão false: ADR-005
  tags            = local.tags
}

module "secrets" {
  source = "../../modules/secrets"

  name = "estuda/db"
  values = {
    DB_NAME     = module.rds.db_name
    DB_USER     = module.rds.master_username
    DB_PASSWORD = module.rds.master_password
  }
  tags = local.tags
}

# Senha do admin do Grafana: gerada aqui e entregue ao cluster pelo ESO (chart platform, namespace monitoring).
resource "random_password" "grafana" {
  length  = 24
  special = false
}

module "secrets_grafana" {
  source = "../../modules/secrets"

  name = "estuda/grafana"
  values = {
    "admin-user"     = "admin"
    "admin-password" = random_password.grafana.result
  }
  tags = local.tags
}

module "ecr" {
  source = "../../modules/ecr"

  name = "estuda-api"
  tags = local.tags
}

# Imagem do Job de migration (hook do Helm), versionada com a mesma tag da aplicação.
module "ecr_migrations" {
  source = "../../modules/ecr"

  name = "estuda-api-migrations"
  tags = local.tags
}

# IRSA do External Secrets Operator: lê SOMENTE os dois segredos da plataforma (privilégio mínimo, por ARN).
data "aws_iam_policy_document" "eso" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [module.secrets.arn, module.secrets_grafana.arn]
  }
}

module "irsa_eso" {
  source = "../../modules/iam-irsa"

  name              = "${local.name}-external-secrets"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  namespace         = "external-secrets"
  service_account   = "external-secrets"
  policy_json       = data.aws_iam_policy_document.eso.json
  tags              = local.tags
}
