variable "name" {
  description = "Nome do cluster."
  type        = string
}

variable "kubernetes_version" {
  description = "Versão do Kubernetes. Confirmar as versões suportadas pelo EKS na data do deploy."
  type        = string
  default     = "1.34"
}

variable "subnet_ids" {
  description = "Subnets privadas para o control plane (ENIs) e para os nós."
  type        = list(string)
}

variable "endpoint_public_access" {
  description = "Mantém o endpoint público da API do Kubernetes (restrito por public_access_cidrs). Falso = somente acesso privado (VPN/bastion)."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "CIDRs com acesso ao endpoint público. Sem padrão: deve ser informado de forma explícita (ex.: IP do escritório/VPN)."
  type        = list(string)
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND ou SPOT. SPOT reduz custo (ver docs/custos), mas pode ser interrompido."
  type        = string
  default     = "ON_DEMAND"
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "log_retention_days" {
  description = "Retenção dos logs do control plane (1 ano: auditoria)."
  type        = number
  default     = 365
}

variable "tags" {
  type    = map(string)
  default = {}
}
