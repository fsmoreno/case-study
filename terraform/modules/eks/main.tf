# Cluster EKS com nós gerenciados em subnets privadas, secrets criptografados com KMS e OIDC para IRSA.
# Nunca aplicado neste projeto: validado (fmt/validate/tflint) e escaneado (Checkov). Ver DECISIONS.md (ADR-003/008).

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Chave própria para criptografar os Secrets do Kubernetes (envelope encryption) no etcd.
resource "aws_kms_key" "secrets" {
  #checkov:skip=CKV2_AWS_64:Usa a política de chave padrão da AWS (administração via IAM da conta); política customizada é evolução
  description         = "${var.name}: criptografia de Secrets do Kubernetes"
  enable_key_rotation = true
  tags                = var.tags
}

resource "aws_cloudwatch_log_group" "cluster" {
  #checkov:skip=CKV_AWS_158:Logs criptografados com a chave padrão do CloudWatch; CMK para logs é evolução (exige política de chave para o serviço Logs)
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_eks_cluster" "this" {
  #checkov:skip=CKV_AWS_38:O acesso público à API é restrito por public_access_cidrs (variável obrigatória, sem padrão aberto)
  #checkov:skip=CKV_AWS_39:Endpoint público restrito a CIDRs informados; para somente-privado use endpoint_public_access=false com VPN/bastion
  name     = var.name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access ? var.public_access_cidrs : null
  }

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.secrets.arn
    }
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# --- Nós gerenciados ------------------------------------------------------------------------------------
data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name}-eks-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids

  instance_types = var.node_instance_types
  capacity_type  = var.node_capacity_type

  scaling_config {
    min_size     = var.node_min_size
    desired_size = var.node_desired_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy_attachment.node]

  # O autoscaling (Cluster Autoscaler/Karpenter) altera o desired_size fora do Terraform.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

resource "aws_eks_addon" "this" {
  for_each     = toset(["vpc-cni", "coredns", "kube-proxy"])
  cluster_name = aws_eks_cluster.this.name
  addon_name   = each.value
  tags         = var.tags

  depends_on = [aws_eks_node_group.this]
}

# --- OIDC: base do IRSA (cada ServiceAccount assume uma role IAM própria, sem chaves estáticas) ---------
resource "aws_iam_openid_connect_provider" "this" {
  url            = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]
  tags           = var.tags
}
