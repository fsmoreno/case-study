output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_security_group_id" {
  description = "Security group do cluster, usado pelos nós gerenciados; autorizado a acessar o RDS."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.this.arn
}

output "oidc_provider_url" {
  description = "URL do OIDC sem o prefixo https:// (formato usado nas condições da trust policy)."
  value       = replace(aws_iam_openid_connect_provider.this.url, "https://", "")
}
