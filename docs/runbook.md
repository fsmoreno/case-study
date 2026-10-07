# Runbook

Para quem opera a aplicação. Os alertas do Prometheus apontam para as âncoras abaixo (`runbook_url`). Os comandos usam
o ambiente do Kind (contexto `kind-estuda`, namespace `estuda`); em produção (EKS) troque o contexto e use o namespace
`estuda` do cluster real. Problemas de montagem do ambiente (build, Go, timeouts) estão na tabela da seção 7 do
[README](../README.md).

## Antes de tudo: orientação em 2 minutos

```bash
make smoke                                                        # a API responde? (201, 409, health, métricas)
kubectl --context kind-estuda -n estuda get pods                  # estado dos pods
kubectl --context kind-estuda -n estuda get events --sort-by=.lastTimestamp | tail -20
helm --kube-context kind-estuda -n estuda history app             # houve um deploy recente?
```

Dashboards: `make grafana-password` e `make grafana-forward` (http://localhost:3000, usuário `admin`), dashboard
**Estuda API**. Prometheus: `make prometheus-forward` (http://localhost:9090, *Alerts* e *Status → Targets*).

**Pergunta-chave de qualquer alerta: mudou algo?** Se o `helm history` mostra um deploy minutos antes do alerta, a
primeira hipótese é o próprio deploy (ver [rollback](#rollback)).

Mapa do que pode falhar, da borda para dentro:

```
cliente -> Ingress (NGINX / ALB) -> Service -> pods da API -> banco (RDS) <- Secret (ESO <- Secrets Manager)
```

---

<a id="taxa-de-erro-alta"></a>
## Taxa de erro alta (`EstudaApiHighErrorRate`)

**O que significa:** mais de 5% das respostas das rotas de negócio são 5xx há 5 minutos. Probes e `/metrics` não contam.

**Verificar, nesta ordem**

1. **Qual rota e qual status?** No dashboard, *Respostas por status* e *Latência p95 por rota*. Erro só no `POST /users` aponta
   para escrita ou banco; erro em tudo aponta para infraestrutura ou configuração.
2. **Erros de banco?** Painel *Erros inesperados de banco* (`db_errors_total`) e *Pool de conexões*.
   - `db_errors_total` subindo e `/readyz` em 503: o banco está inacessível.
   - Conexões "em uso" no máximo e "espera por conexão" subindo: pool saturado (ver [latência](#latencia-p95-alta)).
3. **Logs da API** (JSON, sem senhas nem corpo de requisição):
   ```bash
   kubectl --context kind-estuda -n estuda logs deploy/estuda-api --all-containers --tail=100
   ```
4. **Os pods estão prontos?** `kubectl get pods`: `0/1`, `CrashLoopBackOff` ou reinícios sugerem configuração ou Secret.
5. **O Secret está sincronizado?**
   ```bash
   kubectl --context kind-estuda -n estuda get externalsecret estuda-db     # SecretSynced / Ready True
   kubectl --context kind-estuda -n estuda describe externalsecret estuda-db
   ```
   Falha aqui, ou senha trocada no Secrets Manager sem reiniciar os pods, produz erros de autenticação no banco.

**Causas conhecidas e ações**

| Evidência | Causa provável | Ação |
|---|---|---|
| Erros começaram logo após um `helm upgrade` | Versão nova com defeito ou migration incompatível | [Rollback](#rollback); depois investigar |
| `readyz` 503, `db_errors_total` crescendo | Banco indisponível ou inalcançável (rede, security group, instância) | Verificar o RDS (no Kind, o Floci: `make floci-status`); mitigar conforme [instância fora do ar](#instancia-fora-do-ar) |
| Erro de autenticação no banco nos logs | Senha do Secret diferente da do banco (rotação ou apply do Terraform) | `kubectl annotate externalsecret estuda-db force-sync=$(date +%s) --overwrite` e `kubectl rollout restart deploy/estuda-api` |
| Só `POST /users` falha com 500 e a tabela não existe | Migration não rodou | `kubectl logs job/estuda-api-migrate`; reaplicar com `make deploy` |

**Mitigação rápida:** se há deploy recente e a taxa de erro segue acima do limite, volte a versão (não espere o diagnóstico
completo). Aumentar réplicas não resolve erro de aplicação ou de banco.

---

<a id="latencia-p95-alta"></a>
## Latência p95 alta (`EstudaApiHighLatencyP95`)

**O que significa:** o p95 de alguma rota passou do limite por 5 minutos: **0,5 s para leituras (GET)** e **1,5 s para
escritas (POST)**. O alerta é por rota e a mensagem diz qual. O `POST /users` é lento por natureza (bcrypt).

**Verificar**

1. **Qual rota?** Painel *Latência p95 por rota*. Se for só o `POST /users`, relacione com o volume de cadastros: o bcrypt
   consome CPU e a latência sobe com a concorrência.
2. **Pool de conexões** saturado? *em uso* no máximo e *espera por conexão* > 0 indicam que as requisições aguardam o banco.
3. **CPU dos pods** (throttling) e memória: `kubectl top pods` (exige metrics-server), ou o painel do Prometheus
   (`container_cpu_cfs_throttled_periods_total`).
4. **Houve deploy recente?** Compare o horário do deploy com o início do aumento.
5. **Banco lento?** Leituras lentas com CPU da API baixa sugerem o banco ou a rede até ele (no Kind: o proxy do Floci).

**Ações**

| Evidência | Ação |
|---|---|
| Pool saturado | Aumentar `DB_MAX_OPEN_CONNS` (`config` no values) se o banco aguenta, ou investigar consultas lentas |
| CPU dos pods no limite (bcrypt sob carga) | Escalar horizontalmente: `kubectl scale deploy/estuda-api --replicas=4` ou `--set replicaCount=4`. Em produção, HPA por CPU |
| Aumento logo após deploy | [Rollback](#rollback) |
| Só leitura lenta, API saudável | Verificar o banco (CPU, conexões, locks) |

---

<a id="instancia-fora-do-ar"></a>
## Instância fora do ar (`EstudaApiDown`)

**O que significa:** nenhuma instância respondeu ao scrape do Prometheus por 2 minutos (nenhum pod no ar).

**Verificar**

```bash
kubectl --context kind-estuda -n estuda get pods,deploy,rs
kubectl --context kind-estuda -n estuda describe deploy/estuda-api | tail -30
kubectl --context kind-estuda -n estuda get events --sort-by=.lastTimestamp | tail -20
```

| Evidência | Causa provável | Ação |
|---|---|---|
| `0` réplicas no Deployment | Escalado a zero (manual ou erro) | `kubectl scale deploy/estuda-api --replicas=2` |
| Pods `ImagePullBackOff` | Imagem inexistente ou sem acesso ao registro | Conferir a tag (`helm get values app`); no Kind, `kind load` da imagem |
| Pods `CrashLoopBackOff` | Configuração ou Secret ausente (`variável obrigatória ausente`) | `kubectl logs`; conferir o ExternalSecret |
| Pods `Pending` | Falta de recurso no nó | `kubectl describe pod`; reduzir requests ou aumentar capacidade |
| Pods `Running` mas `0/1` | `/readyz` falhando: banco inacessível | Ver [taxa de erro alta](#taxa-de-erro-alta), item do banco |
| Prometheus sem alvo, pods saudáveis | Problema de scrape (ServiceMonitor/rede) | *Status → Targets* no Prometheus |

---

## Procedimentos

<a id="rollback"></a>
### Rollback

```bash
helm --kube-context kind-estuda -n estuda history app      # escolha a revisão
make rollback                                              # volta para a revisão anterior
make smoke
```

**O rollback volta o Deployment, mas NÃO desfaz migrations.** Isso é seguro porque as migrations são retrocompatíveis
(expand/contract): a versão antiga funciona com o schema novo. Se uma migration **destrutiva** já rodou, o rollback pode
quebrar a versão anterior; nesse caso corrija para frente. Em produção o `helm upgrade --atomic` já reverte sozinho um deploy
que falha.

**Quando fazer rollback:** erro acima do limite ou latência degradada que começou com um deploy e cuja causa não ficou
óbvia em ~10 minutos. Reverter primeiro, diagnosticar depois.

### Deploy

```bash
make deploy        # build, kind load, release platform (ESO) e release app (hook de migration, depois Deployment)
make smoke
```

A migration roda como Job antes das réplicas novas; uma falha dela **bloqueia o deploy** (e deixa a versão antiga no ar).
Logs: `kubectl -n estuda logs job/estuda-api-migrate`.

### Escalar

```bash
kubectl --context kind-estuda -n estuda scale deploy/estuda-api --replicas=4        # temporário
# permanente: replicaCount no values do chart. O PodDisruptionBudget (minAvailable 1) protege as evicções voluntárias.
```

### Trocar a senha do banco

A senha é gerada pelo Terraform e fica no Secrets Manager (`estuda/db`). Ao regenerá-la: aplicar o Terraform, forçar a
sincronização do ESO e reiniciar os pods, porque a aplicação lê o Secret só na partida:

```bash
make tf-apply-local     # (local) em produção, o pipeline de infraestrutura
kubectl --context kind-estuda -n estuda annotate externalsecret estuda-db force-sync=$(date +%s) --overwrite
kubectl --context kind-estuda -n estuda rollout restart deploy/estuda-api
```

### Restaurar o banco (produção, RDS)

O RDS faz backup automático (7 dias) e mantém o *point-in-time recovery*. Restaurar cria uma **nova instância** a partir de um
momento, o que exige apontar `DB_HOST` para ela e reaplicar o chart. Como o banco é Single-AZ (ADR-005), uma falha da zona
significa indisponibilidade até a restauração. Em produção real, o Multi-AZ elimina esse cenário.

---

## Quando escalar para outra pessoa

- A causa não ficou clara em ~10 minutos **e** o rollback não resolveu.
- Há perda ou corrupção de dados (migration, restauração).
- O problema está fora do cluster (rede, conta, RDS, DNS).

Registre a linha do tempo do que foi feito: ela é a base do pós-incidente (ver [incidente.md](incidente.md)).
