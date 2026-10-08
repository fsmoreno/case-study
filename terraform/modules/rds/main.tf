# Senha gerada pelo Terraform e entregue ao Secrets Manager (módulo secrets). Nunca aparece em arquivo nem no Git.
# Sem caracteres especiais: a string de conexão do golang-migrate (URL) não precisa de URL-encode.
# Ela fica no state do Terraform: em produção o state fica em bucket S3 criptografado, com acesso restrito.
resource "random_password" "master" {
  length  = 24
  special = false
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db"
  subnet_ids = var.subnet_ids
  tags       = var.tags
}

# Sem regras de saída (o banco não inicia conexões) e entrada somente na 3306 a partir de quem foi autorizado.
resource "aws_security_group" "this" {
  name        = "${var.name}-db"
  description = "Acesso ao MySQL ${var.name}"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-db" })
}

resource "aws_vpc_security_group_ingress_rule" "from_sg" {
  count                        = length(var.allowed_security_group_ids)
  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = var.allowed_security_group_ids[count.index]
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "MySQL a partir de security group autorizado"
}

resource "aws_vpc_security_group_ingress_rule" "from_cidr" {
  count             = length(var.allowed_cidr_blocks)
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = var.allowed_cidr_blocks[count.index]
  from_port         = 3306
  to_port           = 3306
  ip_protocol       = "tcp"
  description       = "MySQL a partir de CIDR autorizado"
}

resource "aws_db_instance" "this" {
  #checkov:skip=CKV_AWS_157:Single-AZ por decisão (ADR-005); Multi-AZ é variável (multi_az) e recomendado em produção real
  #checkov:skip=CKV_AWS_118:Enhanced monitoring fora do escopo do case (custo); métricas básicas do CloudWatch bastam
  identifier     = var.name
  engine         = "mysql"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage > 0 ? var.max_allocated_storage : null
  storage_type          = var.storage_type
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.master_username
  password = random_password.master.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false
  multi_az               = var.multi_az

  backup_retention_period             = var.backup_retention_days
  copy_tags_to_snapshot               = true
  deletion_protection                 = var.deletion_protection
  skip_final_snapshot                 = var.skip_final_snapshot
  final_snapshot_identifier           = var.skip_final_snapshot ? null : "${var.name}-final"
  auto_minor_version_upgrade          = true
  iam_database_authentication_enabled = var.iam_database_authentication
  enabled_cloudwatch_logs_exports     = var.log_exports

  tags = var.tags
}
