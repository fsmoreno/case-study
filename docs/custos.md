# Custos

> **Estimativa aproximada**, não uma cotação. Os preços unitários são de lista (sob demanda, `us-east-1`) **de memória** e
> devem ser **conferidos no AWS Pricing Calculator** antes de qualquer decisão. O que importa aqui é a **ordem de grandeza**
> e **onde está o custo**. Premissas: 730 horas por mês, tráfego baixo (poucos GB), 1 segredo, 1 ambiente de produção.

## Estimativa mensal da arquitetura de produção (EKS + RDS)

| Componente | Premissa | US$/mês (aprox.) | Confirmar |
|---|---|---:|---|
| EKS (control plane) | 1 cluster, US$ 0,10/h | 73 | [ ] |
| Nós do EKS | 2 x `t3.medium` sob demanda, ~US$ 0,0416/h cada | 61 | [ ] |
| NAT Gateway | 1 (compartilhado), ~US$ 0,045/h, mais tráfego | 33 + tráfego | [ ] |
| IPv4 público (EIP do NAT) | ~US$ 0,005/h | 4 | [ ] |
| ALB | 1 balanceador, ~US$ 0,0225/h mais LCU | 20 | [ ] |
| RDS MySQL | `db.t4g.micro` Single-AZ, ~US$ 0,016/h | 12 | [ ] |
| Storage do RDS | 20 GB gp3, ~US$ 0,115/GB | 2 | [ ] |
| Secrets Manager | 1 segredo, US$ 0,40 por segredo | 0,4 | [ ] |
| KMS | 1 chave (Secrets do EKS), US$ 1 | 1 | [ ] |
| CloudWatch Logs | logs do control plane e Flow Logs (retenção de 1 ano) | 5 a 15 | [ ] |
| ECR | 2 repositórios, poucas imagens | 1 | [ ] |
| **Total** | | **~ US$ 210 a 225** | |

Não incluídos: tráfego de saída (cresce com o uso), monitoramento gerenciado, domínio e certificados ACM públicos (sem custo).
Multi-AZ no RDS acrescenta aproximadamente o valor da própria instância (~US$ 12 neste porte): ver ADR-005.

## O que tem maior impacto

1. **O Kubernetes em si: EKS + nós = ~US$ 134 (≈ 60% do total).** O control plane é custo fixo, independente de carga. Para uma API
   simples, esse é o custo desproporcional (ADR-003).
2. **NAT Gateway (~US$ 37 com o IP):** custo fixo mais cobrança por GB processado.
3. **ALB (~US$ 20)**, também fixo.
4. O **banco** custa pouco neste porte: ~US$ 14.

Quase tudo é **custo fixo**: o gasto não cai com pouco uso e não sobe muito com mais tráfego (até o limite dos nós).

## Onde existem otimizações

| Otimização | Efeito (aprox.) | Contrapartida |
|---|---|---|
| Nós **Spot** ou **Graviton** (`t4g`) | até ~30% a 60% nos nós | Spot pode ser interrompido; Graviton exige imagem `arm64` |
| **1 NAT** em vez de 1 por AZ (já é o padrão) | evita ~US$ 33 por AZ extra | Ponto único de falha de saída |
| **VPC endpoints** (ECR, S3, Secrets Manager) | reduz tráfego pelo NAT | Endpoints de interface têm custo próprio |
| Reduzir **retenção de logs** (de 365 dias) | pouco no total | Menos histórico para auditoria |
| **Savings Plans / Reserved** para nós e RDS | ~20% a 40% com compromisso | Exige previsibilidade de uso |
| **Desligar ambientes não produtivos** fora do horário | proporcional ao tempo desligado | Automação extra |
| **Lifecycle no ECR** (já mantém as 20 últimas imagens) | evita crescimento do storage | Nenhuma relevante |

## Se o orçamento fosse reduzido em 50%

Meta: de ~US$ 215 para ~US$ 105. Só ajustes finos (Spot, Savings Plans, logs) **não** chegam a 50%, porque o custo está
concentrado no EKS. O que funciona é trocar o orquestrador:

| Mudança | Antes | Depois |
|---|---:|---:|
| EKS + 2 nós `t3.medium` → **ECS Fargate** com 2 tarefas de 0,25 vCPU e 0,5 GB (~US$ 9 cada) | 134 | ~18 |
| Mantém NAT, ALB, RDS, Secrets Manager, KMS, logs e ECR | ~81 | ~81 |
| **Total** | **~215** | **~100** |

Resultado: queda de **~54%**. O que não muda: a imagem, as métricas, o `/healthz` e o banco. O que muda: o módulo Terraform
(service, task definition, ALB, IAM) e o deploy do CI; o chart Helm deixaria de ser o artefato de produção (continua valendo para o
Kind). É exatamente o caminho previsto na ADR-003.

Se a mudança de orquestrador não fosse aceitável, a redução ficaria em ~15% a 25% combinando Spot/Graviton nos nós, Savings Plans no
RDS e menos logs. Não passa disso: o custo fixo do control plane do EKS (~US$ 73) permanece.

## Custo do ambiente de validação (este projeto)

Praticamente zero: o Kind, o Floci e o CD rodam em contêineres, no runner do GitHub (gratuito em repositório público; minutos
consumidos em privado) e numa VM local. Nenhum recurso AWS foi criado: o Terraform de produção nunca foi aplicado.
