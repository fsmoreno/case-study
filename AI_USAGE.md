# Uso de IA

## 1. Ferramentas

Usei **somente o Claude**, em uma única conversa contínua no Claude Code (extensão do VS Code). Todo o trabalho foi
conduzido e discutido ali. (Instalei também o Claude CLI na VM de testes, mas o projeto foi construído e conversado na sessão
principal; a VM serviu para **executar** e validar.)

## 2. Como foram utilizadas

Divisão de trabalho: o Claude escreveu e revisou arquivos numa máquina Windows **sem Go, Docker, Kubernetes nem Helm
instalados**, então quase nada do que ele gerou pôde ser executado por ele. **Eu executava tudo numa VM Debian 13** (4 vCPUs,
4 GB de RAM) e colava as saídas e os erros na conversa; o Claude diagnosticava e corrigia. Usos concretos:

- **Arquitetura e decisões:** discussão do desenho em três contextos (compose, Kind com Floci, produção hipotética), escolha de
  Go, Kind e Helm, EKS em produção, RDS, ESO, migrations por hook, e a redação das 11 ADRs.
- **Código da aplicação:** API REST em Go (handlers, métricas, shutdown gracioso, health checks), testes unitários e as
  migrations SQL.
- **Contêineres:** Dockerfile multi-stage com distroless, `Dockerfile.migrations`, `docker-compose.yml`.
- **Kubernetes:** os charts Helm (`app` e `platform`), configuração do Kind, ingress, ESO, kube-prometheus-stack, dashboard do
  Grafana e as regras de alerta.
- **Infraestrutura como código:** módulos Terraform (`network`, `rds`, `secrets`, `eks`, `iam-irsa`, `ecr`) e os ambientes
  `local` e `prod`.
- **Automação:** Makefile, scripts (`bootstrap.sh`, `smoke.sh`, `traffic.sh`) e os workflows do GitHub Actions.
- **Documentação:** README, runbook, cenário de incidente, custos, mentoria e este arquivo.
- **Diagnóstico de erros:** interpretação dos logs, eventos e relatórios que eu colava (kubelet, Helm, Trivy, `govulncheck`,
  Checkov, GitHub Actions).
- **Pesquisa pontual:** o Claude consultou a web e a API do GitHub quando a resposta não podia vir de memória (por exemplo, se o
  Floci emula EKS e quais tags do `trivy-action` existem).

## 3. Validação

**Regra que segui:** tudo que o Claude gerou sem poder executar foi tratado como **rascunho** até eu rodar. A confiança veio da
execução, não da explicação.

**O que validei, e como**

| O quê | Como |
|---|---|
| Aplicação e testes | `make test` (`-race`), `make lint` (golangci-lint), `govulncheck`, `make up` com `curl` real |
| Kubernetes | `make deploy` e `make smoke` no Kind; rollback (`helm history`); apagar os pods e observar a recriação |
| Segredos e banco | ExternalSecret `SecretSynced`, owner reference do Secret, conexão de um pod ao RDS do Floci |
| Observabilidade | Targets `UP` no Prometheus, dashboard com tráfego gerado, alerta em `Pending` e, depois, normal |
| Terraform | `make tf-check` (fmt, validate, tflint, Checkov), `make tf-apply-local` (21 recursos) e um segundo apply sem mudanças |
| Pipeline | CI e CD rodando no GitHub: lint, testes, segurança, build, scan, push, assinatura, verificação, deploy, smoke e rollback |
| Afirmações do Claude | Conferi pelas saídas (eventos do pod, relatórios), e várias afirmações se mostraram erradas (ver a tabela abaixo) |

**O que o Claude sugeriu e eu aceitei:** a arquitetura em três contextos, Go, Kind com Helm, ESO com Floci, migrations por hook,
kube-prometheus-stack com o dashboard e os alertas dentro do chart, o Terraform com módulos compartilhados aplicados no Floci, e
a cadeia de entrega (Trivy, SBOM, cosign).

**O que eu alterei ou decidi diferente**
- **Floci só para VPC, RDS e Secrets Manager.** O Claude tratou o Floci só como Secrets Manager e mantinha o MySQL como
  StatefulSet; eu propus usar o RDS do Floci e deixar o Kind como Kubernetes (e registrar que em produção seria EKS).
- **EKS em produção.** Eu observei que o ECS seria o melhor para uma aplicação simples; o Claude mostrou as duas opções e eu escolhi
  manter o EKS e usar a ADR para descrever o caminho de redução de custo.
- **Remoção do plano B** (MySQL no cluster): decisão minha, e o MySQL do compose ficou só para desenvolvimento.
- **Senha do Grafana no Secrets Manager:** ideia minha; o Claude a implementou depois (segredo `estuda/grafana` no Terraform e
  um segundo release do chart `platform` no namespace `monitoring`).
- **O comando de subir o Floci**, o **alvo no Makefile** e as informações do ambiente (VM Debian 13, 4 GB) vieram de mim.

**O que foi rejeitado ou descartado**
- O **EKS emulado pelo Floci** como cluster de validação (avaliado, e a ADR-008 registra o motivo).
- O **plano B** com MySQL em StatefulSet, que o Claude havia proposto e depois foi retirado.
- A action `gitleaks-action`, a imagem oficial `migrate/migrate` e o p95 agregado de latência: o Claude as sugeriu e o pipeline ou
  os testes mostraram que não serviam (detalhes na tabela abaixo).

**O que não foi validado, e eu quero deixar claro**
- O **Terraform de produção nunca foi aplicado** (só validado e escaneado); os módulos `eks`, `iam-irsa` e `ecr` não rodaram
  contra uma conta AWS.
- Os **valores de custo** em `docs/custos.md` são estimativas de memória, a confirmar no Pricing Calculator.
- O **EKS do Floci** não foi testado por mim: a decisão se baseou na documentação do projeto.
- O workflow `cd-aws.yml` está desabilitado e nunca foi executado.

## 4. Erros da IA (registrar na hora, com evidência real)
| Data | O que a IA sugeriu | Por que estava errado | Como identifiquei |
|---|---|---|---|
| 2026-10-07 | Sugeriu `go test ./... -race` (no Makefile e nos comandos de validação) sem avisar que o detector de race exige cgo e um compilador C. | Na VM Debian recém-instalada não havia gcc, e o teste falhou com `go: -race requires cgo; enable cgo by setting CGO_ENABLED=1`. | Ao rodar os testes na VM. Correção: `build-essential` no `scripts/bootstrap.sh` e `CGO_ENABLED=1` no `make test`; o `-race` foi mantido por ser útil em API concorrente. O Dockerfile segue com `CGO_ENABLED=0` (imagem distroless). |
| 2026-10-07 | Fixou `GO_VERSION=1.25` no Dockerfile sem conferir a versão do Go instalada na VM. | O `go mod tidy` rodou com Go 1.26 e elevou o `go.mod` para `go 1.26.0`; o build da imagem falhou com `go.mod requires go >= 1.26.0 (running go 1.25.14; GOTOOLCHAIN=local)`. | Ao rodar `make up` na VM (falha em `RUN go mod download`). Correção: `GO_VERSION=1.26` no Dockerfile; no CI a versão será lida do `go.mod` (`go-version-file`) para evitar nova divergência. |
| 2026-10-07 | Escreveu os alvos `secret-local`/`deploy` do Makefile chamando `kubectl` e `helm` direto, assumindo que o cluster Kind já existia e que o contexto atual do kubeconfig era o correto. | Sem cluster, o `kubectl` caiu no padrão `localhost:8080` e falhou com `failed to download openapi ... dial tcp [::1]:8080: connection refused`, uma mensagem que não aponta a causa. Além disso, sem contexto fixo, um `make deploy` poderia atuar em outro cluster presente no kubeconfig. | Ao rodar `make deploy` na VM. Correção: alvo `check-cluster` com mensagem clara ("Cluster 'estuda' não existe. Rode: make kind-up") e `--context kind-estuda`/`--kube-context` em todos os comandos. |
| 2026-10-07 | No chart `platform`, configurou o MySQL com `livenessProbe` (initialDelay 30s) e sem `startupProbe`, e limitou a memória a 512Mi. Ao ver a falha, a primeira hipótese da IA incluiu OOM. | O 1º boot do MySQL levou ~4 min nessa VM (InnoDB init de 2m41s). O liveness matou o contêiner (SIGKILL, exit 137) logo após o servidor ficar pronto, em loop. A hipótese de OOM estava errada: `reason` era `Error`, não `OOMKilled`, e os logs mostravam a inicialização concluída. | Pelos eventos do pod (`Liveness probe failed ... Killing`), `kubectl logs --previous` (init completo) e `lastState` (exitCode 137, sem OOMKilled). Correção: `startupProbe` (até ~10 min) antes de liveness/readiness e remoção do PVC corrompido antes de reaplicar. O aumento para 1Gi de memória não era a causa e foi mantido só como margem. |
| 2026-10-07 | Definiu `TAG ?= dev-$(shell date +%s)` no Makefile para gerar uma tag única por build. | Em Make, `?=` cria variável recursiva: o `date` é reavaliado a cada uso. As imagens da API e de migrations receberam tags com 1 s de diferença (`dev-1791392845` e `dev-1791392846`) e o `kind load` falhou com `image: "estuda-api-migrations:dev-1791392846" not present locally`. Nos deploys anteriores funcionou por acaso (comandos no mesmo segundo). | Ao rodar `make deploy` na VM: a diferença de 1 s entre as duas tags na própria mensagem de erro. Correção: `ifeq ($(origin TAG),undefined)` + `TAG := ...` (avaliada uma vez), mantendo `make deploy TAG=x` como override. |
| 2026-10-07 | Definiu o alerta de latência como um único p95 agregado de todas as rotas, com limite de 500 ms; e a query de "taxa de erro" sem tratar a ausência de séries 5xx. | O p95 agregado misturava leituras rápidas com o `POST /users`, que inclui bcrypt e é lento de propósito: no teste o alerta entrou em `Pending` por causa do POST (~0,5 s; GET 24–65 ms), um falso positivo em potencial a cada cadastro. A taxa de erro mostrava `No data` quando não havia nenhum 5xx (divisão de série vazia). | Ao abrir o dashboard com carga real (p95 de 1,5 s em vermelho e o painel `No data`) e medir por rota com `curl -w '%{time_total}'`. Correção: alerta por rota com limite de leitura (0,5 s) e de escrita (1,5 s), painel de p95 por rota, e `or vector(0)` no numerador da taxa de erro. |
| 2026-10-07 | No Terraform, escreveu as supressões do Checkov (`#checkov:skip=...`) como comentários ACIMA dos blocos `resource`. Também assumiu que os módulos já passariam `fmt` sem rodar o formatador. | O Checkov só reconhece a supressão DENTRO do bloco do recurso: o relatório mostrou `Skipped checks: 0` e 16 falhas, inclusive as que eram decisões documentadas (Multi-AZ, rotação do segredo, endpoint público do EKS). | Ao rodar `make tf-check` na VM: o relatório trazia `Skipped checks: 0` apesar dos comentários. Correção: mover cada skip para dentro do bloco, com justificativa; corrigir de verdade o que era falha real (todos os log types do EKS, retenção de 1 ano, ECR com KMS); excluir o ambiente `local` (emulador) do scan. |
| 2026-10-07 | Escreveu o código Go com `defer db.Close()`, `defer rows.Close()` e `defer resp.Body.Close()` descartando o erro de retorno. | O linter do próprio projeto (`golangci-lint`, errcheck) reprovou os 3 pontos. Os testes e o build passavam: o código funcionava, mas não cumpria o padrão que o CI exige. | Ao rodar `make lint` na VM pela primeira vez (o lint nunca havia sido executado). Correção: tratar ou descartar explicitamente o erro (`_ =`), com log no fechamento do pool do banco. Lição: o lint entra no CI para pegar exatamente isso. |
| 2026-10-07 | Usou `gitleaks/gitleaks-action@v2` para varrer segredos no CI. | No primeiro push do repositório a action calcula o intervalo de commits a partir do pai do primeiro commit, que não existe: `git log 2bc66ef^..cd4fe0c` falha com `unknown revision` e o job termina com `ERROR: Unexpected exit code [1]` sem varrer nada (`scanned ~0 bytes`, `no leaks found in partial scan`). | Pelo log do job `Segurança` no primeiro run do CI. Correção: rodar o gitleaks via Docker com `detect --source` varrendo o histórico completo, que serve também para o primeiro push. |
| 2026-10-07 | Fixou versões de actions e de toolchain de memória: `aquasecurity/trivy-action@0.28.0` e `GO_VERSION=1.26.3` (e antes `go 1.26.0` no `go.mod`, deixado pelo `go mod tidy`). | O Trivy falhou com `Unable to resolve action aquasecurity/trivy-action@0.28.0, unable to find version 0.28.0` (as tags passaram a ter prefixo `v`). O `govulncheck` apontou 20 vulnerabilidades da stdlib do Go 1.26.0 (corrigidas até 1.26.3; a VM resolveu com 1.26.6). | Pelo log do CI (job `build` e job `Segurança`). Para o Trivy, consultei a API do GitHub (tags do repositório) em vez de adivinhar outra versão: a mais recente era `v0.36.0`. Correção: `@v0.36.0`; Go fixado em um patch sem vulnerabilidades conhecidas, no `go.mod` e no Dockerfile. |
| 2026-10-07 | Afirmou que, depois de entregar a senha do Grafana pelo Secrets Manager (ESO), bastava reiniciar o Grafana para a senha nova valer. | O Grafana só aplica a senha do admin ao **criar** o usuário; depois ela fica no banco dele, e o login com a senha nova falhou. O usuário apontou que reiniciar não resolve (e estava certo). | Ao tentar o login no Grafana. Correção: `grafana cli admin reset-admin-password` com o valor do Secret (validado), encapsulado em `make grafana-reset-password`, e a documentação da rotação corrigida. |
| 2026-10-07 | Escolheu a imagem oficial `migrate/migrate:v4.18.1` como base da imagem de migrations, sem avaliar a postura de segurança dela. | O scan do Trivy no CI reprovou a imagem: 50 vulnerabilidades (46 HIGH, 4 CRITICAL) no binário `migrate` (Go 1.23.1 e dependências antigas de drivers de outros bancos, como grpc e pgx) e 4 HIGH no Alpine 3.19, já fora de suporte. | Pelo relatório do Trivy no job `build` (passo de scan, antes do push). Correção: compilar o `migrate` no próprio Dockerfile com o Go 1.26.6 e só o driver MySQL (`-tags mysql`), com base distroless. Prefiri isso a `.trivyignore` em massa ou a baixar a severidade do gate. |
