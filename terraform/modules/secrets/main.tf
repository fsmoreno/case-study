variable "name" {
  description = "Nome do segredo (ex.: estuda/db). É o que o ExternalSecret referencia em remoteRef.key."
  type        = string
}

variable "values" {
  description = "Chaves e valores do segredo; serializados como JSON (o ESO lê cada chave por 'property')."
  type        = map(string)
  sensitive   = true
}

variable "recovery_window_in_days" {
  description = "Janela de recuperação após exclusão (0 = exclusão imediata, útil no emulador/local)."
  type        = number
  default     = 7
}

variable "kms_key_id" {
  description = "Chave KMS própria (CMK). Nulo usa a chave gerenciada aws/secretsmanager."
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "aws_secretsmanager_secret" "this" {
  #checkov:skip=CKV2_AWS_57:Rotação automática exige uma Lambda de rotação do MySQL; fora do escopo do case (documentado)
  name                    = var.name
  recovery_window_in_days = var.recovery_window_in_days
  kms_key_id              = var.kms_key_id
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "this" {
  secret_id     = aws_secretsmanager_secret.this.id
  secret_string = jsonencode(var.values)
}

output "arn" {
  value = aws_secretsmanager_secret.this.arn
}

output "name" {
  value = aws_secretsmanager_secret.this.name
}
