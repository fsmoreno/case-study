# Mentoria e multiplicação

> "O que você faria para que esse profissional (DevOps Pleno) consiga operar e evoluir a solução sem depender constantemente de
> você?"

A resposta parte do que **já existe neste repositório**, mais o que eu faria nas primeiras semanas. O objetivo é que a pessoa
consiga operar sozinha e, sobretudo, **entender por que** as coisas são como são, para evoluí-las com segurança.

## 1. O que o projeto já entrega (autonomia de operação)

| Necessidade da pessoa | Onde está | Por que ajuda |
|---|---|---|
| Executar, fazer deploy, testar, reverter, destruir | **Makefile** como interface única (`make up`, `kind-up`, `deploy`, `smoke`, `rollback`, `kind-down`) | Ninguém precisa decorar comandos do Helm, do Kind ou do Terraform |
| Instalar o ambiente do zero | `scripts/bootstrap.sh` e o README (seções 2 a 4) | Reprodutível; o CD também o prova num runner limpo |
| Entender as escolhas | **DECISIONS.md** (11 ADRs) | Responde "por que X e não Y?" sem perguntar a mim, com trade-offs e consequências |
| Atender um alerta | **docs/runbook.md**, com âncoras que os alertas já apontam | O alerta leva direto ao passo a passo |
| Investigar uma degradação | **docs/incidente.md** e o dashboard **Estuda API** | Um roteiro de hipóteses e evidências, com as métricas certas |
| Ver o que já deu errado | Tabela de problemas do README e **AI_USAGE.md** | Os erros reais, com sintoma, causa e correção |
| Mudar com segurança | **CI/CD** como rede de proteção | Lint, testes, scan, assinatura, deploy e rollback ensaiado antes de chegar a qualquer ambiente |
| Mudar a infraestrutura | **Módulos Terraform** (`network`, `rds`, `secrets`, `eks`, `iam-irsa`, `ecr`) e `make tf-check` | Cada módulo tem uma responsabilidade; o `tf-check` valida e escaneia sem aplicar |
| Padrões do código | `golangci-lint`, `gofmt`, `.gitattributes`, Dependabot | O padrão é imposto pelo pipeline, não por memória |

## 2. O que eu faria na prática

### Semana 1: entender, executando
1. **Subir o ambiente seguindo só o README** e anotar tudo que travar. Cada tropeço vira uma correção na documentação (é assim
   que o roteiro ganha o passo faltante, como já aconteceu com o `tf-apply-local`).
2. **Percorrer um deploy completo acompanhando o dashboard:** `make deploy`, `make smoke`, `make traffic`, e observar as métricas.
3. **Provocar uma falha de propósito** (`kubectl scale deploy/estuda-api --replicas=0`, ou apagar os pods) e usar o runbook para
   resolver. Aprende-se mais num alerta disparado de verdade do que lendo sobre ele.
4. **Ler as ADRs em ordem** (001 a 011) com a pessoa, contestando: "o que mudaria se...?".

### Semanas 2 e 3: fazer junto
- **Pair programming** na primeira mudança real (por exemplo, o HPA ou um usuário de banco sem privilégio de *master*): ela
  digita, eu pergunto.
- **Code review como ensino:** comentários que explicam o motivo e apontam a ADR ou o runbook relevante, e não só "troque isso".
  Mudanças pequenas e frequentes, revisadas antes de entrar na `main`.
- **Primeiro plantão acompanhado:** a pessoa lidera o diagnóstico de um alerta e eu observo.

### Depois: transferir a propriedade
- A pessoa passa a **escrever a próxima ADR** (por exemplo, a de entrega progressiva) e a **atualizar o runbook** com o que aprender.
  Quem opera é quem mantém os documentos.
- Revisar juntos o AI_USAGE.md: como usar IA com **validação técnica**, não como oráculo (todos os erros ali foram achados rodando).
- Fazer um **pós-incidente sem culpados** do primeiro incidente real, com ações que tenham dono.

## 3. Como garantir que isso não depende de mim

- **Se não está escrito, não existe.** Toda decisão relevante vira ADR; todo procedimento, runbook; todo erro, uma linha na tabela de
  problemas. Uma dúvida repetida é um sinal de documentação faltando.
- **Automação em vez de instrução:** o que a pessoa precisaria lembrar de fazer vira um alvo do Makefile ou um passo do pipeline.
- **Guardas no lugar do aviso:** o pipeline barra vulnerabilidades, segredos e formatação no CI. Num time, eu complementaria
  com a proteção da branch `main` (exigir os checks e impedir o empurrão direto), que **não está configurada neste case**. O
  sistema ensina o limite sem uma pessoa precisando vigiar.
- **Medir a autonomia:** se, num mês, a pessoa resolveu alertas e entregou mudanças sem me consultar, a transferência funcionou; se não,
  descobrimos o que faltava documentar.

## 4. Lacunas conhecidas (o que eu entregaria à pessoa como trabalho)

Para ela evoluir a solução, estas são as pendências que listo explicitamente, em vez de escondê-las:

- HPA e o metrics-server; NetworkPolicy; usuário de banco com privilégios mínimos e TLS entre a aplicação e o RDS.
- Alertmanager e armazenamento persistente do Prometheus; um *Reloader* para reiniciar os pods quando um segredo mudar.
- Teste de integração do pacote `store` contra um MySQL real; teste de carga no pipeline.
- Entrega progressiva (canário ou *blue/green*) e fixar as actions por SHA.
- Habilitar o `cd-aws` quando houver uma conta AWS (a produção é hipotética hoje).
