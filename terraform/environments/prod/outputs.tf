output "cluster_name" {
  value = module.eks.cluster_name
}

output "rds_endpoint" {
  description = "Vai em DB_HOST no helm/app/values-aws.yaml."
  value       = module.rds.endpoint
}

output "rds_address" {
  description = "Somente o host do RDS (DB_HOST)."
  value       = module.rds.address
}

output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "ecr_migrations_repository_url" {
  value = module.ecr_migrations.repository_url
}

output "eso_role_arn" {
  description = "Anotação eks.amazonaws.com/role-arn na ServiceAccount do ESO."
  value       = module.irsa_eso.role_arn
}
