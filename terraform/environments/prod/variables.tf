variable "region" {
  type    = string
  default = "us-east-1"
}

variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

variable "eks_public_access_cidrs" {
  description = "CIDRs autorizados a acessar a API do Kubernetes (ex.: VPN/escritório). Sem padrão: deve ser informado."
  type        = list(string)
}

variable "node_capacity_type" {
  description = "ON_DEMAND ou SPOT."
  type        = string
  default     = "ON_DEMAND"
}

variable "rds_multi_az" {
  description = "Multi-AZ no RDS. Padrão false (ADR-005); recomendado em produção real, ao custo de ~2x na instância."
  type        = bool
  default     = false
}
