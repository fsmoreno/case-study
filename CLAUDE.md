# Contexto do projeto (ler antes de qualquer tarefa)

Case técnico de DevOps Sênior (Estuda.com). Prazo curto (~2 dias). Avaliam raciocínio, decisões documentadas,
segurança, observabilidade, custos, documentação/transferência de conhecimento e uso transparente de IA.
Não é para construir a infraestrutura mais complexa possível.

## Três contextos
| Contexto | O que roda | Executado de verdade? |
|---|---|---|
| Dev local | docker compose: app Go + MySQL | Sim |
| Validação tipo produção | Kind (Kubernetes) + Helm + ESO + kube-prometheus-stack. Floci fornece SÓ VPC, RDS MySQL e Secrets Manager, provisionados com o MESMO Terraform (módulos network, rds, secrets) via `terraform apply` apontando o provider para o Floci. FLUXO ÚNICO: não há MySQL dentro do cluster | Sim (validado na VM e no CD) |
| Produção (hipotética) | Os mesmos módulos + EKS, IAM/IRSA e ECR (módulos eks, iam-irsa, ecr, só em environments/prod) | Não: só validado e escaneado (`make tf-check`) |

Floci NÃO faz parte da produção: é a "AWS de mentira" para provar o desenho localmente. O EKS NÃO é emulado
(Floci tem EKS via k3s, avaliado e descartado: não implementa ALB Controller/IRSA e adiciona uma camada a depurar).
Kind é o Kubernetes de validação; em produção seria EKS (deixar isso explícito no README e em ADR).
Ponte entre validação e produção: o MESMO chart Helm (`helm/app`), mudando só values
(`values-local.yaml` / `values-aws.yaml`). O banco é RDS nos dois (DB_HOST muda). Em prod: ESO via IRSA e ALB Controller.

## Floci (spike concluído)
Validado: RDS e Secrets Manager do Floci alcançáveis a partir do Kind pelo nome `floci` (o contêiner é conectado à
rede docker `kind` por `make kind-up`; o RDS fica atrás do proxy `floci:7001`) e `terraform apply` local com os
mesmos módulos de produção. O antigo PLANO B (MySQL em StatefulSet no cluster) foi REMOVIDO de propósito: um
fallback não testado dá falsa segurança. O MySQL do docker compose é só para desenvolvimento local.

## Decisões fechadas (virar ADRs em DECISIONS.md, mínimo exigido: 5)
1. Go como linguagem. 2. Kind + Helm para validação local. 3. EKS em prod (ECS Fargate é mais barato para app
isolada: é o caminho de redução de custo -50%). 4. RDS em prod e na validação (via Floci); MySQL no cluster foi avaliado como plano B e retirado. 5. Single-AZ, com
Multi-AZ recomendado e custo registrado. 6. ESO + Floci local / IRSA em prod. 7. Migrations via Helm hook, retrocompatíveis (expand/contract), golang-migrate.
8. Kind como Kubernetes de validação; EKS é só alvo de produção (EKS do Floci avaliado e descartado).
Candidatas: kube-prometheus-stack, GHCR no CI, "Terraform aplicado no Floci; EKS/IRSA/ECR só validados".

## Releases Helm (dois, por causa da ordem do hook)
- `platform`: SecretStore + ExternalSecret (ESO), que criam o Secret `estuda-db` a partir do Secrets Manager. O
  banco é o RDS (Floci no Kind). O hook de migration exige que o banco e o Secret existam antes do release `app`.
  values-floci.yaml (auth static, credenciais fictícias) e values-aws.yaml (auth irsa).
- `app`: Deployment, Service, Ingress, Job de migration (hook pre-install/pre-upgrade), ServiceMonitor,
  PrometheusRule (3 alertas), ConfigMap do dashboard Grafana. Observabilidade fica DENTRO do chart.
- Job de migration: backoffLimit baixo, ttlSecondsAfterFinished, hook-delete-policy; falha bloqueia o deploy.
- Ingress NGINX por padrão; port-forward como "modo lite"; em prod o ALB só existe em values-aws.yaml.

## Ordem de subida local (cada passo = alvo do Makefile)
Floci -> terraform apply local (network, rds, secrets) -> Kind -> ingress-nginx -> ESO + SecretStore (aponta
para o Floci) -> kube-prometheus-stack -> release app -> smoke. No Makefile: `make kind-up`, `make tf-apply-local`,
`make deploy`, `make smoke` (o CD local faz exatamente essa sequência).

## Contrato da API
- POST /users {name,email,password} -> 201 {id,name,email,created_at}; 400 payload inválido; 409 email duplicado
  (via constraint única do banco, não select antes); 500.
- GET /users -> 200, nunca devolve senha, paginação limit/offset com teto.
- GET /healthz (liveness, não toca o banco), GET /readyz (checa o banco, 200/503), GET /metrics.
- Senha com bcrypt, nunca em log/resposta. Erro padronizado `{"error":{"code","message"}}` sem vazar detalhes.
- Limite de body, timeouts HTTP, shutdown gracioso (SIGTERM). Subcomando `healthcheck` no binário (imagem distroless
  não tem shell/curl; usado no HEALTHCHECK do Dockerfile).
- Documentar que /metrics e /healthz idealmente ficam fora do Ingress público.

## Métricas (usar o padrão da rota, nunca o path bruto)
`http_requests_total{method,route,status}`, `http_request_duration_seconds` (histograma), mais métricas de pool de
conexões/erros de banco. Alertas: taxa de erro alta, p95 alto, instância fora do ar; cada um linka a seção do runbook.

## Makefile (contrato operacional)
up/down, test/lint, kind-up, deploy, smoke, rollback, tf-check, kind-down. "Provisionar" = `make tf-check`
(fmt, validate, tflint, Checkov); o README deve dizer sem rodeios que o Terraform nunca é aplicado.
Estado atual: alvos NÃO validados; `kind-up` e `smoke` são TODO.

## CI/CD (GitHub Actions)
ci.yml (lint, testes, build, scans: govulncheck/Trivy/gitleaks, imagem versionada por SHA, push GHCR),
cd-local.yml (sobe Kind no runner, deploy, smoke), cd-aws.yml (desabilitado), terraform.yml.

## Entregáveis do case
README.md (8 itens de transferência: executar, provisionar, deploy, saúde, dashboards, problemas, rollback,
destruir; + respostas de K8s, segurança e custos), AI_USAGE.md (inclui ao menos 1 erro REAL da IA),
DECISIONS.md, Dockerfile, docker-compose.yml, application/, tests/, terraform/, kubernetes/, .github/workflows/,
observability/. Em docs/: runbook, incidente (latência + 500 pós-deploy), mentoria, diagrama (Mermaid), custos.

## Pendências conhecidas (decididas, ainda não implementadas)
- Senha do Grafana no Secrets Manager (`estuda/grafana`), via ESO, em vez do Secret aleatório criado por
  `make monitoring-up`. Usar ClusterSecretStore; ordem: credenciais do Floci no ns `monitoring` -> ExternalSecret
  `Ready` -> helm install do kube-prometheus-stack. Rotação exige reiniciar o Grafana (citar Reloader no README).
- (Feito) Terraform cria VPC, RDS e o segredo estuda/db no Floci (`make tf-apply-local`); prod só validado.
  Pendente: segredo `estuda/grafana` no módulo secrets; ALB Controller + IRSA fora do Terraform (descrever em values-aws).
- docs/runbook.md com as âncoras #taxa-de-erro-alta, #latencia-p95-alta, #instancia-fora-do-ar (os alertas as usam);
  trocar `REPLACE_ME` em `observability.alerts.runbookUrl`.
- CI/CD escrito (ci.yml, cd-local.yml, terraform.yml, cd-aws.yml desabilitado, dependabot) mas AINDA NÃO EXECUTADO:
  validar com `actionlint` e no primeiro push. values-aws.yaml (app e platform) escritos, com REPLACE_ME.
  O repositório ainda não é um repo Git/GitHub (a troca de arquivos com a VM é por cópia).
- ADRs restantes, custos, incidente, mentoria, segurança, respostas de Kubernetes no README.

## Regras de trabalho
- Nada de credenciais reais; as do Floci são fictícias e isso deve estar explícito.
- Registrar em AI_USAGE.md os erros da IA na hora em que acontecem (com evidência).
- Valores de custo são aproximados: confirmar no AWS Pricing Calculator.
- Versões das ferramentas: fixar no scripts/bootstrap.sh após validar.
