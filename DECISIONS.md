# Decisões arquiteturais

Formato: Contexto, Alternativas, Decisão, Motivos, Trade-offs, Consequências.

- ADR-001 Go como linguagem (a escrever)
- ADR-002 Kind + Helm para validação local (ver ADR-008)
- ADR-003 EKS em produção e caminho de redução de custo (rascunho na conversa)
- ADR-004 RDS em produção e na validação (via Floci); MySQL StatefulSet só como plano B (a escrever)
- ADR-005 RDS single-AZ, com Multi-AZ recomendado e seu custo (a escrever)
- ADR-006 ESO com Floci local e IRSA em produção (a escrever)
- ADR-007 Migrations via Helm hook, retrocompatíveis, golang-migrate (a escrever)

---

## ADR-008: Kind como Kubernetes de validação; EKS é só alvo de produção

**Contexto.** O case exige configuração para Kubernetes e aceita Kind ou Minikube. Em produção o alvo é o EKS (ADR-003).
O Floci, emulador local da AWS, também oferece EKS (k3s em Docker, segundo a documentação do projeto; não testado aqui).

**Alternativas.**
1. Kind como cluster de validação; Floci apenas para VPC, RDS e Secrets Manager.
2. EKS emulado pelo Floci como cluster de validação.
3. Kind e EKS emulado, em paralelo.

**Decisão.** Alternativa 1.

**Motivos.**
- Tudo que o chart usa (Ingress, ESO, ServiceMonitor, hooks) é Kubernetes puro e funciona igual em qualquer cluster
  conformante; trocar o Kind pelo EKS emulado não valida nada a mais sobre o chart.
- O EKS emulado não implementa ALB Controller nem IRSA, a peça central da estratégia de segredos em produção;
  passaria falsa sensação de validação.
- Uma camada a mais (Floci orquestrando k3s) para depurar, num prazo curto e com RAM limitada.
- O Kind é padrão da indústria e citado pelo enunciado.

**Trade-offs.** Não exercita comportamentos específicos do EKS (ALB Controller, IRSA, add-ons gerenciados). Isso fica
documentado como diferença conhecida entre validação e produção, coberta apenas por `values-aws.yaml` e pelo
Terraform validado (não aplicado).

**Consequências.** O Ingress NGINX é usado no Kind; em produção seria o AWS Load Balancer Controller, configurado
somente em `values-aws.yaml`. O README informa explicitamente que o Kind é só validação e que produção seria EKS.
