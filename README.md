# Estuda.com DevOps case

API REST de usuários (Go + MySQL) com execução em containers, Kubernetes (Helm), observabilidade e infraestrutura como código.
Decisões e alternativas: [DECISIONS.md](DECISIONS.md). Uso de IA: [AI_USAGE.md](AI_USAGE.md).

> **Estado da documentação.** Cada seção indica se o procedimento foi **validado** (executado com sucesso) ou
> **escrito, ainda não validado**. Seções marcadas *a escrever* serão preenchidas conforme o projeto avança.

## 1. Visão geral: três contextos

```mermaid
flowchart LR
  subgraph Dev["1. Dev local (executado)"]
    A1[app Go] --> M1[(MySQL)]
  end
  subgraph Val["2. Validação (Kind)"]
    A2[app Go x2] --> DB2[(MySQL)]
    F[Floci: VPC, RDS, Secrets Manager]:::emul
  end
  subgraph Prod["3. Produção hipotética (não aplicada)"]
    A3[app Go no EKS] --> R[(RDS MySQL)]
    S[Secrets Manager + IRSA]
  end
  classDef emul stroke-dasharray: 4 3
```

| Contexto | O que roda | Executado? |
|---|---|---|
| Dev local | `docker compose`: app + MySQL + migrations | Sim, **validado** |
| Validação | **Kind** + Helm + Ingress NGINX + ESO, com **Floci** (RDS e Secrets Manager): **validado** (deploy + smoke). kube-prometheus-stack e Terraform local: *em andamento* | Parcial |
| Produção | Terraform: EKS, RDS, Secrets Manager, IRSA, ECR | **Não**: só código validado e escaneado (`make tf-check`) |

### Kind em vez de EKS
Neste projeto o Kubernetes é o **Kind**, usado **apenas para validar** o chart Helm e a operação (deploy, probes,
rollback, métricas). Em **produção o alvo é o EKS**, com ALB Controller no lugar do Ingress NGINX e IRSA no lugar
de credenciais estáticas. O mesmo chart (`helm/app`) serve aos dois; só mudam os values (`values-local.yaml` /
`values-aws.yaml`). O Floci chegou a ser avaliado como EKS emulado e foi descartado (ver DECISIONS.md).

> O Terraform de produção **nunca é aplicado** contra a AWS real. "Provisionar" neste projeto significa
> `make tf-check` (fmt, validate, tflint, Checkov).

## 2. Pré-requisitos

### Ambiente em que tudo foi construído e validado

Todo o processo (compose, Kind, Helm, Floci, ESO, Prometheus/Grafana e Terraform local) foi executado em uma **VM
Debian 13 com 4 vCPUs e 4 GB de RAM**. Funciona nesse tamanho, mas com folga pequena: os primeiros boots são lentos
(imagens grandes, RDS emulado, Grafana) e por isso os timeouts do Makefile são generosos
(ver a tabela de problemas na seção 7). Com mais recursos tudo sobe mais rápido; com menos de 4 GB, não rode o
docker compose e o Kind ao mesmo tempo.

Para instalar tudo (Docker, Go, kind, kubectl, helm, Terraform, tflint,
golangci-lint, Checkov, AWS CLI):

```bash
./scripts/bootstrap.sh   # como usuário normal, com sudo; depois saia e entre de novo no SSH (grupo docker)
```

As versões instaladas são as mais recentes na data da execução; fixe-as no topo do script para reprodutibilidade.

## 3. Executar localmente (docker compose): **validado**

```bash
cp .env.example .env     # valores de desenvolvimento, não são segredos reais
make up                  # app + MySQL + migrations
curl -s -X POST localhost:8080/users -H 'Content-Type: application/json' \
  -d '{"name":"João Silva","email":"joao@example.com","password":"senha-segura"}'
curl -s localhost:8080/users
make down                # remove containers e o volume
```

Testes: `make test` (usa `-race`, que exige `gcc`; o `bootstrap.sh` instala `build-essential`).

## 4. Deploy no Kind: **validado** (deploy, smoke, rollback e recriação de pods)

No Kubernetes há **um único fluxo**, o que espelha a produção: o banco é um **RDS** (emulado pelo Floci no Kind) e o
segredo vem do **Secrets Manager** via ESO. Não há MySQL dentro do cluster; o MySQL do docker compose (seção 3) é só
para desenvolvimento local. O RDS emulado pode demorar a aceitar conexões depois de `available`, por isso o hook de
migration tem `backoffLimit: 5`.

```bash
make down          # libera RAM: não rode compose e Kind juntos
make kind-up       # sobe o Floci, cria o cluster Kind, conecta o Floci à rede do Kind, instala ingress-nginx e ESO
                   # (obrigatório antes do deploy; o 1º pull das imagens é lento, os timeouts são de 10 min)
make tf-apply-local # cria no Floci a VPC, o RDS e o segredo estuda/db com os mesmos módulos de produção (seção 10)
make deploy        # build das imagens, kind load, release platform (SecretStore/ExternalSecret) e release app
                   # (hook de migration, depois Deployment). DB_HOST = floci:7001 (proxy do RDS emulado)
make smoke         # 201, 409, lista sem senha, /healthz, /readyz, /metrics, e /metrics fora do Ingress
```

Os alvos do Makefile **sempre usam o contexto `kind-estuda`**: nunca atuam em outro cluster do seu kubeconfig.
Os alvos `floci-creds`, `smoke` e `rollback` verificam antes se o cluster existe.

Por que dois releases Helm (`platform` e `app`): o hook de migration (`pre-install`/`pre-upgrade`) roda antes dos
demais recursos do release. O `SecretStore`/`ExternalSecret` ficam no `platform` para que o Secret `estuda-db` já
exista quando o Job de migration rodar.

**Como o segredo chega à aplicação (validado):** o ESO lê `estuda/db` do Secrets Manager (Floci) e cria o Secret
`estuda-db` apenas com `DB_NAME`, `DB_USER` e `DB_PASSWORD` (a senha root nunca entra no cluster). O Deployment e o
Job de migration consomem essas chaves por `secretKeyRef`. Em produção só muda a autenticação (IRSA, sem credenciais
estáticas) e o `DB_HOST` (endpoint do RDS).

**Comportamentos conhecidos do Floci:** o RDS emulado sobe como MySQL 8.0.36 e pode reportar `available` antes de
aceitar conexões (a primeira conexão pode falhar); as credenciais usadas são fictícias; a imagem sobe com o
`docker.sock` montado (é assim que ele cria o contêiner do RDS), aceitável só numa VM de desenvolvimento descartável.

## 5. Verificar a saúde: **validado**

```bash
make smoke      # 201, 409, lista sem senha, /healthz, /readyz, /metrics, e /metrics fora do Ingress
```

- `/healthz` (liveness): processo vivo, **não** toca o banco.
- `/readyz` (readiness): consulta o banco; 503 também durante o shutdown, para drenar tráfego.
- `/metrics`: Prometheus. **Não** é exposto no Ingress; acesso interno ou por port-forward.
- Nos painéis, as probes e o `/metrics` ficam fora das contas (`route!~"/healthz|/readyz|/metrics"`): elas geram volume
  que mascara o tráfego real.

## 6. Dashboards e alertas: **validado**

```bash
make monitoring-up      # kube-prometheus-stack (já incluído no make kind-up). Senha do Grafana aleatória, fora do Git
make traffic            # gera tráfego pelo Ingress para alimentar os painéis
make grafana-password   # usuário: admin
make grafana-forward    # http://localhost:3000 ; de outra máquina: ssh -L 3000:localhost:3000 usuario@vm
make prometheus-forward # http://localhost:9090 (Status > Targets, Alerts)
```

O dashboard **Estuda API** (provisionado pelo chart `app`, como ConfigMap) responde às perguntas do enunciado:
quantas requisições (req/s), qual endpoint tem mais volume (tabela de rotas), taxa de erro 5xx, latência (p50/p95/p99
e p95 por rota) e degradação (stats com limiares, pool de conexões e erros de banco).

Alertas (PrometheusRule no chart `app`, cada um com `runbook_url` para o runbook):

| Alerta | Condição | Severidade |
|---|---|---|
| `EstudaApiHighErrorRate` | 5xx acima de 5% por 5 min | critical |
| `EstudaApiHighLatencyP95` | p95 **por rota**: leituras > 0,5 s, escritas > 1,5 s, por 5 min | warning |
| `EstudaApiDown` | nenhuma instância no ar por 2 min | critical |

**Por que a latência é medida por rota:** o `POST /users` inclui bcrypt, lento de propósito (~0,5 s na VM de
desenvolvimento; `GET /users` fica em 24 a 65 ms). Um p95 agregado misturaria as duas coisas e geraria alerta falso a
cada cadastro. Foi um erro de calibragem encontrado com carga real (ver AI_USAGE.md).

**Limitações deste ambiente:** não há Alertmanager (economia de RAM), então um alerta `Firing` só aparece na tela do
Prometheus e ninguém é notificado; em produção entraria o Alertmanager com roteamento. O Prometheus não tem volume
persistente no Kind: as métricas se perdem se o pod reiniciar. O primeiro boot do stack pode levar vários minutos e um
restart do Grafana na VM de desenvolvimento.

## 7. Identificar problemas básicos

Problemas **realmente encontrados** durante a construção e como resolver:

| Sintoma | Causa | Solução |
|---|---|---|
| `go: -race requires cgo; enable cgo by setting CGO_ENABLED=1` | Sem `gcc` na máquina | `sudo apt install build-essential`; `make test` já usa `CGO_ENABLED=1` |
| `no required module provides package ...` | `go.mod` sem dependências / `go.sum` ausente | `cd application && go mod tidy`; versionar `go.mod` **e** `go.sum` |
| `go.mod requires go >= 1.26.0 (running go 1.25.x)` no build da imagem | `ARG GO_VERSION` do Dockerfile menor que a diretiva `go` do `go.mod` | Alinhar o `GO_VERSION` do Dockerfile ao `go.mod` (o CI lê a versão do `go.mod`) |
| Build da imagem falha com `no required module provides package` mesmo após o `tidy` | `go.mod` foi sobrescrito por uma cópia sem dependências (ex.: sincronização de arquivos) | Rodar `go mod tidy` de novo; trocar arquivos via Git, não copiando a pasta inteira |
| `failed to download openapi ... localhost:8080 ... connection refused` no `make deploy` | O cluster Kind não existe (ou o `kubectl` não tem contexto): o `kubectl` cai no padrão `localhost:8080` | `make kind-up`. Confira com `kind get clusters` e `kubectl config current-context` |

| O Job de migration falha na 1ª tentativa (`Can't connect to MySQL server`) | O RDS emulado reporta `available` antes de aceitar conexões | O hook tem `backoffLimit: 5` e tenta de novo; se esgotar, `make deploy` de novo. Logs: `kubectl -n estuda logs job/estuda-api-migrate` |
| `make deploy` espera e falha em `externalsecret/estuda-db` | O segredo `estuda/db` ainda não existe no Floci (faltou `make tf-apply-local`) ou o Floci não está na rede `kind` | `make tf-apply-local`; `kubectl -n estuda describe externalsecret estuda-db` mostra o motivo |
| `helm upgrade --install ... --wait` termina com `context deadline exceeded` (ESO, ingress) mas os pods sobem depois | Pull lento das imagens na VM de desenvolvimento; o Helm marca o release como `failed` | Confirme os pods com `kubectl get pods -A` e rode o mesmo `helm upgrade --install` de novo (idempotente). Os timeouts do Makefile são de 10 min |
| `./scripts/smoke.sh: Permission denied` | Script copiado do Windows sem o bit de execução | O Makefile chama `bash scripts/smoke.sh`; ou `chmod +x scripts/*.sh` |

Comandos úteis no Kind:

```bash
kubectl --context kind-estuda -n estuda get pods
kubectl --context kind-estuda -n estuda logs deploy/estuda-api
kubectl --context kind-estuda -n estuda logs job/estuda-api-migrate   # falhas de migration
helm --kube-context kind-estuda -n estuda history app
```

## 8. Rollback: **validado**

```bash
make rollback      # helm rollback do release app para a revisão anterior
helm --kube-context kind-estuda -n estuda history app    # a revisão nova aparece como "Rollback to N"
make smoke         # confirma que a API segue saudável após o rollback
```

Validado no Kind: após `deploy` (revisão 2) e `rollback`, o histórico mostrou a revisão 3 como `Rollback to 1` e o
smoke test passou. Se um pod morre (ou é apagado), o ReplicaSet cria outro em segundos e o Service só envia tráfego
a pods com `/readyz` ok; o MySQL não é afetado.

**Atenção:** o rollback volta o Deployment, mas **não desfaz migrations**. Por isso as migrations devem ser
retrocompatíveis (expand/contract): a versão anterior precisa continuar funcionando com o schema novo.

## 9. Destruir o ambiente de teste

```bash
make kind-down     # remove o cluster Kind
make down          # remove o compose e o volume
```

## 10. Provisionar a infraestrutura (Terraform): **validado**

Os mesmos módulos servem aos dois ambientes; muda a composição e os valores:

| Módulo | Local (Floci, **aplicado**) | Produção (**nunca aplicado**) |
|---|---|---|
| `network` | VPC, 2 subnets públicas e 2 privadas, sem NAT | + NAT Gateway compartilhado e VPC Flow Logs |
| `rds` | MySQL 8.0.36 emulado, sem proteções que impeçam o destroy | MySQL 8.4 criptografado, privado, backup de 7 dias, deletion protection, Single-AZ (ADR-005) |
| `secrets` | segredo `estuda/db` (`DB_NAME`, `DB_USER`, `DB_PASSWORD`) | idem, com janela de recuperação |
| `eks`, `iam-irsa`, `ecr` | não usados | EKS com nós privados e KMS, role IRSA do ESO (somente o segredo `estuda/db`), ECR com tags imutáveis |

```bash
make tf-check           # produção: fmt, validate (local e prod), tflint e Checkov. NÃO aplica nada
make tf-apply-local     # aplica de verdade no Floci: VPC, RDS e o segredo (21 recursos)
make tf-destroy-local   # remove o que o Terraform criou no Floci
```

**Resultado validado:** `tf-check` passa limpo (151 verificações do Checkov aprovadas, 0 falhas, 9 suprimidas, cada
uma com justificativa dentro do código) e o `tf-apply-local` criou o RDS e o segredo que a aplicação usa; depois dele,
`make deploy` roda a migration no banco novo e `make smoke` passa. Um segundo `make tf-apply-local` termina com
`No changes` (idempotente).

Decisões e limites que quem assumir deve conhecer:
- **A senha do banco é gerada pelo Terraform** (`random_password`, sem caracteres especiais) e vai direto ao Secrets
  Manager; não existe em arquivo nem no Git. Ela fica no *state*: em produção o state fica em bucket S3 criptografado
  (backend S3 com lock nativo, bucket criado fora deste código).
- **Um RDS novo é um banco vazio:** depois do `tf-apply-local`, force a sincronização do ESO
  (`kubectl -n estuda annotate externalsecret estuda-db force-sync=$(date +%s) --overwrite`) e rode `make deploy`,
  que executa a migration como hook. Um simples restart dos pods não cria a tabela.
- **Se criou o RDS ou o segredo à mão no Floci**, apague-os antes do apply (senão o Terraform conflita).
- A aplicação usa o usuário *master* do RDS. Em produção real, o ideal é um usuário de aplicação com privilégios
  mínimos criado no bootstrap do banco (evolução registrada em docs/seguranca).
- O Checkov **ignora `environments/local`** (aponta para um emulador e desliga proteções de propósito); o alvo de
  segurança é a produção e os módulos que ela usa. Rotação automática do segredo exige uma Lambda e ficou fora do
  escopo.
- O ALB Controller e o seu IRSA **não** estão no Terraform: ficaram descritos em `values-aws.yaml` (a escrever).

## 10.1 CI/CD (GitHub Actions): **validado** (CI e CD local executados no GitHub; `cd-aws` desabilitado)

```mermaid
flowchart LR
  C[commit / PR] --> L[lint e validações]
  L --> T[testes -race]
  T --> S[segurança: gitleaks, govulncheck, Checkov]
  S --> B[build da imagem]
  B --> X[scan Trivy HIGH/CRITICAL]
  X --> P[push GHCR + SBOM + assinatura cosign]
  P --> V[verifica assinatura]
  V --> D[deploy no Kind + Floci]
  D --> M[smoke test]
  M --> R[ensaio de rollback]
```

| Workflow | Quando | O que faz |
|---|---|---|
| `ci.yml` | push, PR e tags `v*` | lint (gofmt, vet, golangci-lint, hadolint, shellcheck, helm lint e render para local e AWS), testes com `-race` e cobertura, segurança (gitleaks no histórico, govulncheck, Checkov), build das duas imagens, scan Trivy **antes** do push, push só fora de PR, SBOM, proveniência e assinatura cosign por digest |
| `cd-local.yml` | depois do CI na `main` (ou manual) | verifica a assinatura, sobe Floci + Kind + ESO, `terraform apply` local, implanta **a imagem que o CI construiu**, roda o smoke test e ensaia um rollback; em falha, publica um artefato com pods, eventos e logs |
| `terraform.yml` | mudanças em `terraform/**` | fmt, validate (local e prod), tflint e Checkov. **Nunca aplica** |
| `cd-aws.yml` | manual, **desabilitado** (só roda com a variável do repositório `ENABLE_CD_AWS=true`) | esboço do deploy em produção: OIDC (sem chaves), aprovação manual, cópia GHCR→ECR com o mesmo digest, `helm --atomic` |

Como cada exigência do enunciado é atendida:
- **Reprodutibilidade:** a versão do Go vem do `go.mod`; as etapas chamam o mesmo `Makefile` usado localmente.
- **Artefatos versionados e rollback:** as imagens são tagueadas `sha-<7 caracteres>` (e `vX.Y.Z` em tags), nunca
  `latest`; no ECR as tags são imutáveis. O rollback é `helm rollback` (ver seção 8) e o `cd-aws` usa `--atomic`,
  que reverte sozinho se o deploy falhar.
- **Gestão segura de secrets:** o pipeline não guarda nenhuma credencial de nuvem. O GHCR usa o `GITHUB_TOKEN` com
  permissões mínimas por job, a assinatura é *keyless* (identidade OIDC do workflow, sem chave privada) e o
  `cd-aws` assume uma role por OIDC. Os segredos da aplicação vêm do Secrets Manager (ESO), não do GitHub.
- **Como as imagens são verificadas:** scan Trivy antes de publicar (falha em HIGH/CRITICAL com correção
  disponível), SBOM e proveniência anexados, assinatura cosign, e o CD só implanta depois de `cosign verify`
  confirmar que a assinatura veio do `ci.yml` deste repositório.
- **Tratamento de falhas e feedback:** o PR só entra com os checks verdes; execuções antigas do mesmo PR são
  canceladas; cobertura e digests vão para o resumo da execução; falha no CD gera artefato de diagnóstico.
- **Controle de versões:** o Dependabot propõe atualizações de actions, módulos Go, imagens base e Terraform.

Configuração necessária no repositório (não vive no código): proteção da branch `main` exigindo os checks do CI,
environment `production` com revisores obrigatórios (para o `cd-aws`) e, na habilitação, as variáveis
`AWS_DEPLOY_ROLE_ARN`, `ECR_REGISTRY` e `ENABLE_CD_AWS=true`.

**Validar o pipeline localmente antes do primeiro push:** `actionlint` (checa a sintaxe dos workflows) e `make lint`.

## 11. Respostas: Kubernetes, segurança e custos: *a escrever*

## 12. Estrutura do repositório

```
application/   código Go, migrations SQL         helm/app, helm/platform   charts (platform = SecretStore/ExternalSecret)
kubernetes/kind  cluster e values de terceiros   terraform/                módulos e ambiente prod
observability/  aponta para o chart              scripts/                  bootstrap e smoke test
docs/           runbook, incidente, mentoria     .github/workflows/        CI/CD
                (ver docs/runbook.md e docs/incidente.md)
```

A estrutura difere da sugerida no enunciado (`kubernetes/` com manifests): o chart Helm substitui os manifests
crus porque é o mesmo artefato nos dois ambientes (ver DECISIONS.md).
