output "endpoint" {
  description = "Endpoint (host:porta) da instância."
  value       = aws_db_instance.this.endpoint
}

output "address" {
  value = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "db_name" {
  value = aws_db_instance.this.db_name
}

output "master_username" {
  value = aws_db_instance.this.username
}

output "master_password" {
  description = "Senha gerada; consumida pelo módulo secrets."
  value       = random_password.master.result
  sensitive   = true
}

output "security_group_id" {
  value = aws_security_group.this.id
}
