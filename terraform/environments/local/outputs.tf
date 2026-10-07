output "rds_endpoint" {
  description = "Endpoint informado pelo Floci. Os pods do Kind usam floci:7001 (ver helm/app/values-local.yaml)."
  value       = module.rds.endpoint
}

output "secret_name" {
  description = "Segredo lido pelo ESO (ExternalSecret remoteRef.key)."
  value       = module.secrets.name
}
