# Ambiente LOCAL: aplica de verdade contra o Floci (emulador da AWS), provando que os módulos funcionam.
# São os MESMOS módulos network, rds e secrets usados em environments/prod; só mudam os valores.
# Credenciais fictícias vêm do ambiente (AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test), nunca do código.
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
}

provider "aws" {
  region = var.region

  # O emulador não valida credenciais nem expõe metadados/contas reais.
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  skip_region_validation      = true

  endpoints {
    ec2            = var.floci_endpoint
    rds            = var.floci_endpoint
    secretsmanager = var.floci_endpoint
    iam            = var.floci_endpoint
    sts            = var.floci_endpoint
  }
}

locals {
  name = "estuda"
  tags = {
    Project     = "estuda"
    Environment = "local"
    ManagedBy   = "terraform"
  }
}

module "network" {
  source = "../../modules/network"

  name             = local.name
  azs              = ["${var.region}a", "${var.region}b"]
  enable_nat       = false # sem custo/complexidade no emulador
  enable_flow_logs = false
  tags             = local.tags
}

module "rds" {
  source = "../../modules/rds"

  name       = local.name
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.private_subnet_ids

  # Os pods do Kind chegam ao RDS emulado pela rede do Docker; no emulador basta liberar o CIDR da VPC.
  allowed_cidr_blocks = [module.network.vpc_cidr]

  db_name         = "estuda"
  master_username = "estuda"

  # Valores compatíveis com o que o Floci emula (MySQL 8.0.36, gp2) e sem proteções que impeçam o destroy local.
  engine_version              = "8.0.36"
  instance_class              = "db.t3.micro"
  storage_type                = "gp2"
  max_allocated_storage       = 0
  backup_retention_days       = 1
  deletion_protection         = false
  skip_final_snapshot         = true
  iam_database_authentication = false
  log_exports                 = []
  tags                        = local.tags
}

module "secrets" {
  source = "../../modules/secrets"

  name = "estuda/db"
  values = {
    DB_NAME     = module.rds.db_name
    DB_USER     = module.rds.master_username
    DB_PASSWORD = module.rds.master_password
  }
  recovery_window_in_days = 0
  tags                    = local.tags
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
  recovery_window_in_days = 0
  tags                    = local.tags
}
