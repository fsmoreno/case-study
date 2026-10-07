# Decisões arquiteturais

Cada ADR segue: Contexto, Alternativas, Decisão, Motivos, Trade-offs e Consequências. Quando uma decisão nasceu de um
problema real durante a construção, ele é citado (as evidências estão em [AI_USAGE.md](AI_USAGE.md)).

| ADR | Decisão |
|---|---|
| [001](#adr-001-go-como-linguagem-da-aplicação) | Go como linguagem da aplicação |
| [002](#adr-002-kind-e-helm-para-validar-o-kubernetes) | Kind e Helm para validar o Kubernetes |
| [003](#adr-003-eks-em-produção-e-o-caminho-de-redução-de-custo) | EKS em produção e o caminho de redução de custo |
| [004](#adr-004-banco-rds-na-validação-e-em-produção-mysql-do-compose-só-em-desenvolvimento) | Banco: RDS (Floci na validação); MySQL do compose só em desenvolvimento |
| [005](#adr-005-rds-em-single-az) | RDS em Single-AZ |
| [006](#adr-006-segredos-external-secrets-operator-com-floci-no-kind-e-irsa-em-produção) | Segredos: External Secrets Operator (Floci no Kind, IRSA em produção) |
| [007](#adr-007-migrations-como-helm-hook-retrocompatíveis) | Migrations como Helm hook, retrocompatíveis |
| [008](#adr-008-kind-como-kubernetes-de-validação-eks-é-só-alvo-de-produção) | Kind como Kubernetes de validação; EKS só em produção |
| [009](#adr-009-observabilidade-kube-prometheus-stack-e-alertas-por-rota) | Observabilidade: kube-prometheus-stack e alertas por rota |
| [010](#adr-010-cadeia-de-entrega-ghcr-trivy-cosign-e-migrate-compilado) | Cadeia de entrega: GHCR, Trivy, cosign e `migrate` compilado |
| [011](#adr-011-terraform-módulos-compartilhados-aplicados-no-floci-produção-só-validada) | Terraform: módulos compartilhados, aplicados no Floci; produção só validada |

---

## ADR-001: Go como linguagem da aplicação

**Contexto.** API REST simples (criar e listar usuários) com MySQL, que precisa de imagem pequena e segura, métricas,
shutdown gracioso e boa densidade em Kubernetes.

**Alternativas.** Python (FastAPI), Node.js (Express), Java (Spring Boot), Go.

**Decisão.** Go, com a biblioteca padrão (`net/http`, `log/slog`) mais o driver MySQL, o cliente Prometheus e bcrypt.

**Motivos.**
- Binário estático: a imagem final é distroless, sem shell nem runtime, com superfície de ataque mínima.
- Baixo consumo e partida rápida: o Deployment roda com limite de 128 Mi e as probes respondem em segundos.
- A stdlib cobre o necessário (roteamento por método, timeouts, shutdown), então há poucas dependências para vigiar.
- Ferramentas do ecossistema que entram no pipeline: detector de race (`-race`), `govulncheck`, `golangci-lint`.

**Trade-offs.** Validação e mapeamento de erros são manuais (não há framework que os faça). Uma equipe sem familiaridade com
Go tem curva de aprendizado. O bcrypt é CPU-bound: o `POST /users` custou ~0,5 s na VM de desenvolvimento.

**Consequências.** Dockerfile multi-stage com usuário não-root; como a imagem não tem `curl`, o health check é um
subcomando do próprio binário (`/app healthcheck`). A versão do Go precisa ser mantida: o `govulncheck` apontou 20
vulnerabilidades na stdlib do Go 1.26.0, e o `go.mod` e o Dockerfile passaram a exigir um patch corrigido.

---

## ADR-002: Kind e Helm para validar o Kubernetes

**Contexto.** O enunciado pede configuração para Kubernetes e aceita Minikube, Kind ou um serviço gerenciado. É
necessário um ambiente barato, descartável e que rode igual na máquina local e no CI.

**Alternativas.** Minikube, k3d, apenas docker compose, um EKS efêmero na AWS, Kind.

**Decisão.** Kind (Kubernetes em contêineres Docker) como cluster de validação, e um **chart Helm** como artefato de
deploy, com `values-local.yaml` e `values-aws.yaml`.

**Motivos.**
- O Kind é um cluster conformante, sobe no runner do GitHub e na VM com os mesmos comandos, e é citado no enunciado.
- O Helm entrega o mesmo artefato nos dois ambientes (só os values mudam), além de hooks (migration), histórico de
  revisões e `rollback` nativo.
- Um EKS efêmero custaria dinheiro e tempo a cada execução e exigiria credenciais da AWS no pipeline.

**Trade-offs.** O Kind não é o EKS (ver ADR-008). Numa VM de 4 GB ele fica com pouca folga e os primeiros boots são lentos. A
sintaxe de templates do Helm conflita com a dos alertas do Prometheus (`{{ }}`), exigindo escape.

**Consequências.** O repositório usa `helm/` e `kubernetes/kind/` no lugar do `kubernetes/` com manifests crus sugerido
no enunciado: o chart substitui os manifests. Os alvos do Makefile fixam o contexto `kind-estuda` para nunca operar em
outro cluster.

---

## ADR-003: EKS em produção e o caminho de redução de custo

**Contexto.** O enunciado exige configuração para Kubernetes e prevê crescimento futuro. Em produção é preciso decidir
onde o contêiner roda.

**Alternativas.** VM com Docker, ECS Fargate, EKS.

**Decisão.** **EKS** em produção, com um único artefato de deploy (o chart Helm) usado no Kind e na AWS.

**Motivos.**
- O chart validado localmente é o mesmo que sobe em produção: não existem duas definições da mesma aplicação.
- Portabilidade e um ecossistema pronto: AWS Load Balancer Controller, ESO, IRSA e kube-prometheus-stack.
- Atende o item de Kubernetes do enunciado com o alvo real, e não com uma versão "de vitrine".

**Trade-offs.** Para uma aplicação isolada, o **ECS Fargate é mais barato e mais simples de operar**. O EKS tem custo
fixo do control plane (da ordem de US$ 70 por mês), além de nós, NAT Gateway e ALB, e uma operação mais pesada
(upgrades de versão, add-ons).

**Caminho de redução de custo (orçamento −50%).**

| Prioridade | Ação | Efeito |
|---|---|---|
| 1 | Migrar de EKS para ECS Fargate | Elimina o control plane e os nós; o contêiner, as métricas e o `/healthz` não mudam, só o orquestrador |
| 2 | Um único NAT Gateway (já é o padrão) ou VPC endpoints | Corta custo fixo e de tráfego |
| 3 | Reduzir a classe do RDS e o storage | Redução proporcional |
| 4 | Nós Spot ou Graviton, se permanecer no EKS | Desconto na computação |
| 5 | Desligar ambientes não produtivos fora do horário | Economia nos ambientes de teste |

Os valores em dólar ficam em `docs/custos.md`, como estimativa a confirmar no AWS Pricing Calculator.

**Consequências.** A migração para ECS exigiria um novo módulo Terraform (service, task definition, ALB, IAM) e adaptar o
deploy do CI. O Helm deixaria de ser o artefato de produção, mas continuaria válido para o Kind.

---

## ADR-004: Banco: RDS na validação e em produção; MySQL do compose só em desenvolvimento

**Contexto.** A aplicação persiste em MySQL. É preciso decidir onde o banco roda em cada contexto.

**Alternativas.** MySQL em StatefulSet no cluster, RDS (gerenciado), MySQL em VM.

**Decisão.**
- **Produção:** RDS MySQL gerenciado.
- **Validação no Kind:** o **RDS emulado pelo Floci**, criado com os mesmos módulos Terraform de produção (ADR-011).
- **Desenvolvimento local (docker compose):** MySQL em contêiner com volume.

**Motivos.**
- Backups, patches, criptografia e failover (se Multi-AZ) ficam a cargo do serviço gerenciado, e não de quem opera o cluster.
- Banco em Kubernetes exige cuidar de volumes, backup e restauração: risco e trabalho que o RDS elimina.
- Usar o mesmo caminho (RDS + Secrets Manager + ESO) na validação e em produção reduz a diferença entre os ambientes: só o
  `DB_HOST` e a autenticação do ESO mudam.

**Trade-offs.** O RDS emulado tem fidelidade limitada: sobe como MySQL 8.0.36 (produção usa 8.4) e pode reportar `available`
antes de aceitar conexões. O MySQL do compose não exercita o fluxo de segredos.

**Consequências.** O hook de migration tem `backoffLimit: 5` por causa do RDS emulado lento. **Houve um plano B**, o MySQL em
StatefulSet no cluster. Foi **retirado**: um fallback que ninguém exercita dá falsa segurança, e o fluxo do Floci está
validado na VM e no CI. Os problemas que o StatefulSet teve (liveness matando a inicialização lenta do MySQL) ficam no
histórico do AI_USAGE.md.

---

## ADR-005: RDS em Single-AZ

**Contexto.** O RDS pode ser Single-AZ ou Multi-AZ. O custo é o principal argumento contra o Multi-AZ.

**Alternativas.** Single-AZ, Multi-AZ com instância standby, Multi-AZ com cluster de 2 leitores.

**Decisão.** **Single-AZ**, com a escolha exposta como variável (`multi_az`, padrão `false`) e a recomendação de Multi-AZ
para uma produção real documentada.

**Motivos.** O Multi-AZ dobra aproximadamente o custo da instância. Para o escopo do case (carga pequena, sem requisito de
disponibilidade declarado), o risco é aceitável desde que esteja explícito. Os backups automáticos (7 dias) limitam a
perda de dados.

**Trade-offs.** Sem failover automático: uma falha da zona ou da instância e as janelas de manutenção geram indisponibilidade
(de minutos a dezenas de minutos até a restauração ou o reinício).

**Consequências.** O Checkov recebe uma supressão justificada (`CKV_AWS_157`) apontando para esta ADR. Em produção real,
ligar `rds_multi_az = true` é uma mudança de uma linha. O runbook deve descrever a restauração a partir do backup.

---

## ADR-006: Segredos: External Secrets Operator com Floci no Kind e IRSA em produção

**Contexto.** A senha do banco não pode estar no código nem no Git, e a aplicação precisa recebê-la em Kubernetes.

**Alternativas.** Secret do Kubernetes criado pelo pipeline, SOPS/Sealed Secrets, Secrets Store CSI Driver, a aplicação
ler direto do Secrets Manager por SDK, External Secrets Operator (ESO).

**Decisão.** **ESO**: um `SecretStore` e um `ExternalSecret` leem `estuda/db` do Secrets Manager e criam o Secret
`estuda-db`. No Kind o Secrets Manager é o do Floci (credenciais fictícias); em produção, o real, com **IRSA** (a
identidade do próprio controller do ESO, sem credenciais no cluster).

**Motivos.**
- Fonte única de verdade no Secrets Manager, criada pelo Terraform; o Git nunca vê o valor.
- A mesma mecânica no Kind e em produção: só mudam o endpoint e a autenticação.
- Privilégio mínimo: o `ExternalSecret` busca só `DB_NAME`, `DB_USER` e `DB_PASSWORD` (a senha root nunca entra no cluster) e
  a role IRSA lê só o segredo `estuda/db`.

**Trade-offs.** O Secret existe no etcd (no EKS, criptografado com KMS). A rotação exige reiniciar os pods (as variáveis são lidas
na partida; um Reloader resolveria). O ESO só permite trocar o endpoint por variável de ambiente do controller. O Floci usa
credenciais fictícias estáticas, o que é aceitável só local.

**Consequências.** O `SecretStore`/`ExternalSecret` ficam no chart `platform`, e não no `app`, porque o hook de migration roda
antes dos demais recursos do release e já precisa do Secret. A aplicação usa o usuário master do RDS; o ideal em produção é um
usuário de aplicação com privilégios mínimos (evolução registrada).

---

## ADR-007: Migrations como Helm hook, retrocompatíveis

**Contexto.** Com várias réplicas, rodar migrations na partida da aplicação cria corrida entre instâncias.

**Alternativas.** Migrar no boot da aplicação, init container, Job manual ou etapa separada do CD, Helm hook.

**Decisão.** Um **Job como Helm hook** (`pre-install` e `pre-upgrade`) executando o **golang-migrate**, que tem lock próprio. O
Job usa uma imagem dedicada (ver ADR-010). **Uma falha do hook bloqueia o deploy.**

**Motivos.** Roda uma única vez por release, antes das réplicas novas, e uma migration quebrada impede a versão nova de subir
(o comportamento desejado). A ferramenta é padrão e idempotente.

**Trade-offs.** **O `helm rollback` volta o Deployment, mas não desfaz o schema.** Por isso a regra: toda migration deve ser
**retrocompatível (expand/contract)**, para que a versão anterior continue funcionando com o schema novo. O hook depende de o
banco e o Secret já existirem, o que levou a dois releases (ADR-006). Um RDS recém-criado pode demorar a aceitar conexões
(`backoffLimit: 5`).

**Consequências.** O runbook de rollback traz esse aviso. Mudanças destrutivas de schema exigem duas versões (expandir, migrar
os dados, depois contrair).

---

## ADR-008: Kind como Kubernetes de validação; EKS é só alvo de produção

**Contexto.** O enunciado aceita Kind ou Minikube. Em produção o alvo é o EKS (ADR-003). O Floci, emulador local da AWS, também
oferece EKS (k3s em Docker, segundo a documentação do projeto; não testado aqui).

**Alternativas.**
1. Kind como cluster de validação; Floci apenas para VPC, RDS e Secrets Manager.
2. EKS emulado pelo Floci como cluster de validação.
3. Kind e EKS emulado, em paralelo.

**Decisão.** Alternativa 1.

**Motivos.**
- Tudo que o chart usa (Ingress, ESO, ServiceMonitor, hooks) é Kubernetes puro e funciona igual em qualquer cluster
  conformante; trocar o Kind pelo EKS emulado não valida nada a mais sobre o chart.
- O EKS emulado não implementa o ALB Controller nem o IRSA, a peça central da estratégia de segredos em produção; passaria
  falsa sensação de validação.
- Uma camada a mais (Floci orquestrando k3s) para depurar, num prazo curto e com RAM limitada.
- O Kind é padrão da indústria e citado pelo enunciado.

**Trade-offs.** Não exercita comportamentos específicos do EKS (ALB Controller, IRSA, add-ons gerenciados). Isso fica
documentado como diferença conhecida entre validação e produção, coberta apenas por `values-aws.yaml` e pelo Terraform
validado (não aplicado).

**Consequências.** O Ingress NGINX é usado no Kind; em produção seria o AWS Load Balancer Controller, configurado somente em
`values-aws.yaml`. O README informa explicitamente que o Kind é só validação e que produção seria EKS.

---

## ADR-009: Observabilidade: kube-prometheus-stack e alertas por rota

**Contexto.** O enunciado exige Prometheus e Grafana e métricas que respondam: quantas requisições, qual endpoint tem mais
volume, taxa de erro, latência e degradação.

**Alternativas.** Prometheus e Grafana instalados à mão, kube-prometheus-stack, serviço gerenciado (Amazon Managed
Prometheus/Grafana, Datadog, CloudWatch).

**Decisão.** **kube-prometheus-stack** (Prometheus Operator). A aplicação expõe `/metrics`, e o **chart `app` traz** o
ServiceMonitor, a PrometheusRule (3 alertas) e o dashboard (ConfigMap carregado pelo sidecar do Grafana).

**Motivos.** Observabilidade como código, versionada junto com a aplicação e implantada pelo mesmo `helm upgrade`. O padrão de
mercado em Kubernetes e funciona igual no Kind e no EKS. O rótulo `route` usa o **padrão da rota** (`/users`), nunca o caminho
bruto, para manter a cardinalidade limitada.

**Alertas por rota.** O alerta de latência mede p95 **por rota e método**, com limite de 0,5 s para leituras e 1,5 s para escritas.
Um p95 agregado misturaria leituras rápidas com o `POST /users`, que inclui bcrypt e é lento de propósito (~0,5 s na VM); foi um
erro de calibragem achado com carga real e corrigido. As probes (`/healthz`, `/readyz`) e o `/metrics` ficam fora das contas.

**Trade-offs.** Sem Alertmanager no Kind (economia de RAM): um alerta `Firing` só aparece na tela do Prometheus. Sem volume
persistente para o Prometheus no Kind. Em produção entram o Alertmanager com roteamento e armazenamento persistente.

**Consequências.** Cada alerta aponta para uma âncora do `docs/runbook.md`. O CI usa `MONITORING=false` para não instalar o
stack no runner.

---

## ADR-010: Cadeia de entrega: GHCR, Trivy, cosign e `migrate` compilado

**Contexto.** O pipeline precisa produzir artefatos versionados, verificáveis e seguros, sem guardar credenciais de nuvem, e o
projeto não tem uma conta AWS real.

**Alternativas de registro.** ECR no CI, GHCR no CI. **De verificação.** Só scan, scan mais assinatura.

**Decisão.**
- **GHCR** como registro do CI (sem conta AWS); em produção as imagens seriam copiadas para o **ECR** com o mesmo digest
  (tags imutáveis), no `cd-aws` desabilitado.
- Tags `sha-<7>` (e `vX.Y.Z`), nunca `latest`.
- **Trivy antes do push**, falhando em HIGH/CRITICAL com correção disponível; SBOM e proveniência anexados; **assinatura
  cosign keyless** (identidade OIDC do workflow) e **verificação da assinatura** no CD antes de implantar.
- **`govulncheck`** nas dependências, **gitleaks** no histórico completo e **Checkov** no Terraform e nos charts.
- O `migrate` é **compilado no próprio Dockerfile** (`Dockerfile.migrations`), em vez de usar a imagem oficial.

**Motivos.** O CD implanta exatamente a imagem que o CI construiu, escaneou e assinou. A imagem oficial `migrate/migrate` foi
reprovada pelo Trivy (50 vulnerabilidades no binário, com Go e dependências antigas de drivers de outros bancos, mais Alpine fora
de suporte); compilar com o Go atual e só o driver MySQL, sobre distroless, zerou os achados.

**Trade-offs.** O pipeline é mais longo e o Dockerfile de migrations compila uma ferramenta de terceiros (versão fixada). As
actions são fixadas por tag, que é mutável; fixar por SHA, mantido pelo Dependabot, é a evolução recomendada. O `gitleaks` roda
via Docker porque a action oficial falha no primeiro push de um repositório.

**Consequências.** Os problemas reais que moldaram essa cadeia estão no AI_USAGE.md (versão do Go, tag da action do Trivy,
gitleaks no primeiro push, imagem de migrations).

---

## ADR-011: Terraform: módulos compartilhados, aplicados no Floci; produção só validada

**Contexto.** O enunciado pede Terraform para provisionar a infraestrutura. Não há conta AWS para aplicar em produção, mas o
código precisa ser provado de alguma forma.

**Alternativas.** Terraform só escrito e validado, Terraform aplicado em uma conta AWS real, **Terraform aplicado em um emulador**
(Floci) com os mesmos módulos.

**Decisão.** Módulos `network`, `rds` e `secrets` **compartilhados** entre `environments/local` e `environments/prod`. O
`local` é **aplicado de verdade no Floci** (`make tf-apply-local`) e produz o RDS e o segredo que a aplicação usa; o `prod`
adiciona `eks`, `iam-irsa` e `ecr` e **nunca é aplicado**: é validado e escaneado (`make tf-check`).

**Motivos.** Aplicar os módulos compartilhados num emulador prova que eles funcionam (21 recursos criados, e um segundo
`apply` sem mudanças), e deixa o fluxo local idêntico ao de produção. A senha do banco é gerada pelo Terraform
(`random_password`) e vai direto ao Secrets Manager, sem passar por arquivo nem Git. O state de produção seria remoto (S3
criptografado, com lock nativo).

**Trade-offs.** O emulador não prova tudo: os módulos `eks`, `iam-irsa` e `ecr` só são validados, não aplicados. O Checkov
**ignora `environments/local`**, que desliga proteções de propósito (deletion protection, logs, IAM auth) por causa do
emulador; o alvo de segurança é a produção. Há supressões justificadas dentro do código (Multi-AZ, rotação do segredo,
endpoint público do EKS restrito por CIDR, entre outras).

**Consequências.** `tf-check` e o workflow `terraform.yml` nunca aplicam. A aplicação usa o usuário master do RDS; um usuário de
aplicação com privilégios mínimos é evolução registrada. A rotação automática do segredo exige uma Lambda e ficou fora do escopo.
