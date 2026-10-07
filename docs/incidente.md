# Cenário de incidente: latência e erros 500 após um deploy

> "Após um deploy, a aplicação começa a apresentar aumento significativo de latência e erros 500."

Este documento descreve **como eu investigaria**, apoiado nas métricas, nos alertas e nos procedimentos que já existem
neste projeto. O incidente não foi simulado. Os comandos e as âncoras do [runbook](runbook.md) são os reais. Ao final há
exemplos do que o projeto já mostrou na prática.

## Princípio

Duas coisas mudaram ao mesmo tempo (o deploy e o comportamento do sistema), então **a primeira hipótese é o deploy**. Reverter
é barato (`helm rollback`) e seguro (as migrations são retrocompatíveis), então a ordem é: **proteger o usuário primeiro,
diagnosticar depois**.

## 1. Hipóteses: o que eu verificaria primeiro

Em ordem de probabilidade e de custo de verificação:

| # | Hipótese | Por que é plausível aqui |
|---|---|---|
| 1 | **Defeito na versão nova** | O deploy é o único evento conhecido; erros 500 imediatos após ele |
| 2 | **Migration incompatível ou lenta** | O hook roda antes das réplicas; um `ALTER` pesado trava a tabela e a API fica lenta ou erra |
| 3 | **Banco saturado ou inacessível** | Pool de conexões esgotado, locks, RDS sem CPU, ou o endpoint mudou |
| 4 | **Configuração ou segredo** | Senha diferente da do banco (o ESO sincronizou outra), `DB_MAX_OPEN_CONNS` mal ajustado |
| 5 | **Recursos do pod** | Limite de CPU (bcrypt é CPU-bound) ou de memória (128 Mi) mais apertado que o necessário, throttling, OOM |
| 6 | **Infraestrutura** | Nó sob pressão, Ingress/ALB, rede até o RDS |

## 2. Evidências: o que eu procuraria

**Métricas** (dashboard *Estuda API*):

| Pergunta | Onde olho | O que indica |
|---|---|---|
| Quando começou, e coincide com o deploy? | Qualquer painel com a linha do tempo, comparada ao `helm history app` | Correlação com a revisão nova |
| É em tudo ou em uma rota? | *Latência p95 por rota*, *Requisições por rota* | Uma rota aponta para o código/consulta daquela rota; tudo aponta para banco ou infraestrutura |
| São 500 de verdade? | *Respostas por status*, *Taxa de erro 5xx* | Confirma o tamanho do problema |
| O banco é o gargalo? | *Pool de conexões* (em uso x máximo, espera) e *Erros de banco* (`db_errors_total`) | Pool saturado ou erros de banco explicam latência e 500 juntos |
| Os pods estão saudáveis? | `kubectl get pods`, reinícios, `/readyz` | `0/1` prontos, `CrashLoopBackOff`, `OOMKilled` |

**Logs** (JSON estruturado, sem senhas nem corpo de requisição):
`kubectl logs deploy/estuda-api` e, se houve migration, `kubectl logs job/estuda-api-migrate`. Procuro a primeira mensagem de erro
depois do horário do deploy e o erro **repetido**, não o último. Os erros de banco aparecem com a operação (`create_user`,
`list_users`) e sem vazar detalhes ao cliente.

**Rastreamento (traces):** o projeto não tem tracing distribuído. Com uma única API e um banco, métricas e logs bastam; se a
aplicação crescesse para vários serviços, OpenTelemetry seria o próximo passo.

**Mudanças:** `helm history app`, a diferença entre as revisões (`helm get values`), e o conteúdo da migration nova.

## 3. Mitigação: como reduzir o impacto

1. **Rollback imediato** se o início coincide com o deploy e a causa não é óbvia em poucos minutos (ver item 5).
2. Se a causa é **saturação** (pool ou CPU) e não o código: aumentar réplicas (`kubectl scale`) ou o pool, para ganhar tempo.
3. Se o **banco** está indisponível: nada na API compensa; o `/readyz` em 503 já tira os pods do Service para não receberem
   tráfego com erro, e a comunicação com os usuários vira o foco.
4. **Congelar novos deploys** até estabilizar, e avisar a quem for afetado.

Por que a mitigação funciona: o Deployment usa `RollingUpdate` com `maxUnavailable: 0` e probes de readiness, então uma versão
que não fica pronta **não recebe tráfego**; o incidente que chega ao usuário é o de uma versão que fica "pronta" mas responde
mal (latência e 500), que é o cenário aqui.

## 4. Correção: como identificar e corrigir a causa

1. **Reproduzir e isolar:** `git diff` entre a tag antiga e a nova, com foco no que toca a rota afetada, o banco e a configuração.
2. **Confirmar a hipótese com a evidência** antes de corrigir (ex.: a latência começa quando a nova consulta entra; o pool satura
   com a nova rota; o erro é o `Unknown column` de um schema que a versão nova esperava).
3. **Corrigir para frente** com um novo deploy testado no Kind (o `cd-local` roda a migration, o smoke e um rollback), ou ajustar a
   configuração (pool, limites), conforme a causa.
4. **Validar:** o alerta volta ao normal e o smoke passa. Só então encerrar o incidente.

## 5. Rollback: quando

**Faço rollback quando** a taxa de erro ou a latência saíram do limite logo depois do deploy **e** a causa não ficou clara em
~10 minutos. Os critérios objetivos são os dos alertas: 5xx > 5% por 5 min, p95 > 0,5 s (leitura) ou 1,5 s (escrita) por 5 min.

**O que torna o rollback seguro aqui:** as migrations são **retrocompatíveis** (expand/contract), então a versão anterior funciona
com o schema novo; o `helm rollback` volta só o Deployment.

**Quando NÃO reverter:** se uma migration **destrutiva** já rodou e a versão anterior não funciona mais com o schema, o rollback
quebra a aplicação; nesse caso corrijo para frente. Por isso toda migration passa pela regra de duas fases.

## 6. Prevenção: como evitar a recorrência

| Medida | O que evita | Estado no projeto |
|---|---|---|
| **Smoke test e rollback ensaiado no CD** antes de chegar ao ambiente final | Versão que sobe mas não responde | Feito (`cd-local`) |
| **`helm upgrade --atomic`** no deploy de produção | Deploy que falha e deixa a versão quebrada | Descrito (`cd-aws`, desabilitado) |
| **Migrations retrocompatíveis** (expand/contract) | Rollback que quebra | Regra documentada (ADR-007) |
| **Alertas por rota** com limites próprios | Alerta falso ou tardio | Feito (ADR-009) |
| **Teste de carga** no pipeline, comparando p95 com a versão anterior | Regressão de desempenho só vista em produção | Pendente (evolução) |
| **Entrega progressiva** (canário ou *blue/green*) | Impacto total de uma versão ruim | Pendente (evolução; ex.: Argo Rollouts) |
| **Anotar os deploys nos gráficos** do Grafana | Correlacionar rápido deploy e sintoma | Pendente (evolução) |
| **Revisão de migrations** e de mudanças de consulta | Consulta lenta ou lock em produção | Prática de revisão de código |
| **Limites de recurso** revistos com dados reais | Throttling e OOM | Parcial (valores iniciais, a ajustar com carga) |
| **Pós-incidente sem culpados**, com linha do tempo e ações com dono | Repetir o mesmo erro | Processo (a linha do tempo vem do runbook) |

## O que o projeto já mostrou na prática

Nenhum desses é o incidente do enunciado, mas todos foram diagnosticados com as mesmas ferramentas:

- **Latência alta que era calibragem, não defeito.** Com tráfego de teste, o p95 apareceu em 1,5 s e o alerta ficou em `Pending`. Medindo
  por rota (`curl -w '%{time_total}'`), `GET /users` levou 24 a 65 ms e `POST /users` ~0,5 s (bcrypt). A causa era o limite único do
  alerta, corrigido para limites por rota. Lição: **separar a rota antes de concluir que o sistema degradou**.
- **Probe que matava o que estava saudável.** O `liveness` reiniciou o MySQL em loop durante a inicialização lenta (a evidência
  estava nos eventos de `kubectl describe pod` e em `logs --previous`: a inicialização terminava e o contêiner era morto logo em
  seguida, `exitCode 137`, sem `OOMKilled`). O Grafana também foi reiniciado uma vez pelo `liveness` na primeira subida. Lição:
  `startupProbe` para componentes lentos, e checar `OOMKilled` antes de supor falta de memória.
- **Erro sem o dado que o explica.** O smoke do CD falhou logo após o deploy, e a mensagem não dizia o status HTTP. A hipótese mais
  provável era o NGINX ainda não ter carregado o Ingress (os eventos mostravam o sync agendado no mesmo instante); depois de o smoke
  passar a esperar a rota e a registrar status e corpo, ele passou. Lição: toda falha de verificação deve dizer **o que recebeu**.
