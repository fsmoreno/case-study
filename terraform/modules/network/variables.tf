variable "name" {
  description = "Prefixo dos recursos."
  type        = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  description = "Zonas de disponibilidade (uma subnet pública e uma privada por zona). Mínimo de 2: exigido pelo RDS (subnet group) e pelo ALB."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2
    error_message = "Informe ao menos 2 zonas de disponibilidade."
  }
}

variable "enable_nat" {
  description = "Cria UM NAT Gateway (compartilhado, em uma única AZ) para saída das subnets privadas. É um dos maiores custos fixos: ver docs/custos."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Habilita VPC Flow Logs para o CloudWatch."
  type        = bool
  default     = false
}

variable "flow_logs_retention_days" {
  description = "Retenção dos Flow Logs (1 ano: investigação de incidentes)."
  type        = number
  default     = 365
}

variable "eks_cluster_name" {
  description = "Se informado, adiciona as tags de descoberta de subnets do EKS/ALB Controller."
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
