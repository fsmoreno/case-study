variable "name" {
  description = "Identificador da instância e prefixo dos recursos."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Subnets PRIVADAS (mínimo 2 AZs, exigido pelo subnet group)."
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security groups autorizados a acessar o banco na porta 3306 (ex.: o dos nós do EKS)."
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "CIDRs autorizados (uso local/emulador). Em produção prefira allowed_security_group_ids."
  type        = list(string)
  default     = []
}

variable "db_name" {
  type = string
}

variable "master_username" {
  type = string
}

variable "engine_version" {
  description = "Versão do MySQL. Produção: 8.4 (confirmar a versão menor disponível na região). O Floci emula 8.0.36."
  type        = string
  default     = "8.4"
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "max_allocated_storage" {
  description = "Teto do autoscaling de storage (0 desabilita)."
  type        = number
  default     = 100
}

variable "storage_type" {
  type    = string
  default = "gp3"
}

variable "multi_az" {
  description = "Padrão false (decisão ADR-005: single-AZ). Multi-AZ é recomendado em produção real e custa ~2x a instância."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "skip_final_snapshot" {
  type    = bool
  default = false
}

variable "iam_database_authentication" {
  type    = bool
  default = true
}

variable "log_exports" {
  description = "Logs exportados para o CloudWatch."
  type        = list(string)
  default     = ["error", "slowquery"]
}

variable "tags" {
  type    = map(string)
  default = {}
}
