# Interface única de operação. Etapa atual: Kind + ingress + platform + app (sem ESO/Floci/Prometheus ainda).
SHELL := /bin/bash

CLUSTER ?= estuda
NS ?= estuda
IMAGE ?= estuda-api
MIGRATIONS_IMAGE ?= estuda-api-migrations
# Tag única por build: com imagens carregadas via `kind load` e pullPolicy IfNotPresent, reutilizar a mesma
# tag não atualizaria os pods.
# Avaliada UMA vez (":="): com "?=" o `date` rodaria a cada uso e API/migrations ficariam com tags diferentes.
ifeq ($(origin TAG),undefined)
TAG := dev-$(shell date +%s)
endif

# Contexto fixo: nunca opera em outro cluster que esteja no kubeconfig.
KCTX := kind-$(CLUSTER)
KUBECTL := kubectl --context $(KCTX)
HELM := helm --kube-context $(KCTX)

# Floci: emulador local da AWS (VPC, RDS, Secrets Manager). Fixar a versão da imagem após o spike.
FLOCI_IMAGE ?= floci/floci:latest
FLOCI_PORT ?= 4566
# MONITORING=false (CI): não instala o kube-prometheus-stack e desliga ServiceMonitor/PrometheusRule/dashboard do chart.
MONITORING ?= true
ifeq ($(MONITORING),false)
APP_EXTRA := --set observability.enabled=false
else
APP_EXTRA :=
endif

.PHONY: up down test lint vuln floci-up floci-down floci-status kind-up monitoring-up grafana-password grafana-forward prometheus-forward traffic check-cluster floci-creds deploy smoke rollback tf-check tf-apply-local tf-destroy-local kind-down

up:            ## Dev local: app + MySQL (+ migrations)
	docker compose up --build -d

down:
	docker compose down -v

test:
	cd application && CGO_ENABLED=1 go test ./... -race -cover   # -race exige cgo e gcc (build-essential)

lint:
	cd application && go vet ./... && golangci-lint run

vuln:          ## Vulnerabilidades da stdlib e das dependências (o mesmo govulncheck do CI)
	cd application && go run golang.org/x/vuln/cmd/govulncheck@latest ./...

floci-up:      ## Sobe o Floci (idempotente). Monta o docker.sock: ele cria contêineres (ex.: RDS) na VM de desenvolvimento.
	@if [ -n "$$(docker ps -aq -f name=^floci$$)" ]; then \
	  docker start floci >/dev/null && echo "floci: contêiner existente iniciado"; \
	else \
	  docker run -d --name floci -p $(FLOCI_PORT):4566 \
	    -v /var/run/docker.sock:/var/run/docker.sock $(FLOCI_IMAGE) >/dev/null && echo "floci: criado"; \
	fi
	@echo "Endpoint: http://localhost:$(FLOCI_PORT)  (use credenciais FICTÍCIAS: AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test)"

floci-status:
	@docker ps -a --filter name=^floci$$ --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
	@AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1 \
	  aws --endpoint-url http://localhost:$(FLOCI_PORT) secretsmanager list-secrets >/dev/null \
	  && echo "floci: API respondendo" || echo "floci: API NÃO respondeu"

floci-down:    ## Remove o Floci. Contêineres criados por ele (ex.: RDS) podem permanecer: confira com `docker ps -a`.
	-docker rm -f floci

kind-up: floci-up  ## Cluster Kind + ingress-nginx + ESO (TODO: kube-prometheus-stack). Floci conectado à rede "kind".
	kind create cluster --name $(CLUSTER) --config kubernetes/kind/cluster.yaml
	@# Os pods alcançam o Floci (e o RDS emulado) pelo nome "floci" na rede do Kind.
	docker network connect kind floci 2>/dev/null || true
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
	helm repo add external-secrets https://charts.external-secrets.io
	helm repo update
	$(HELM) upgrade --install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace \
	  -f kubernetes/kind/ingress-nginx-values.yaml --wait --timeout 10m
	$(HELM) upgrade --install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace \
	  -f kubernetes/kind/eso-values.yaml --wait --timeout 10m   # 1º pull das imagens é lento na VM de dev
	@if [ "$(MONITORING)" != "false" ]; then $(MAKE) monitoring-up; else echo "MONITORING=false: monitoring-up ignorado"; fi

monitoring-up: check-cluster  ## kube-prometheus-stack (Prometheus + Grafana). Senha do Grafana aleatória, fora do Git.
	$(KUBECTL) create namespace monitoring --dry-run=client -o yaml | $(KUBECTL) apply -f -
	@$(KUBECTL) -n monitoring get secret grafana-admin >/dev/null 2>&1 || \
	  $(KUBECTL) -n monitoring create secret generic grafana-admin \
	    --from-literal=admin-user=admin \
	    --from-literal=admin-password="$$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo update
	$(HELM) upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring \
	  -f kubernetes/kind/kube-prometheus-stack-values.yaml --wait --timeout 15m   # imagens grandes: 1º pull lento

grafana-password:  ## Mostra a senha do Grafana (usuário: admin)
	@$(KUBECTL) -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo

grafana-forward:   ## http://localhost:3000 (de fora da VM: ssh -L 3000:localhost:3000 usuario@vm)
	$(KUBECTL) -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

prometheus-forward: ## http://localhost:9090 (de fora da VM: ssh -L 9090:localhost:9090 usuario@vm)
	$(KUBECTL) -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090

traffic:           ## Gera tráfego pelo Ingress para alimentar o dashboard
	bash scripts/traffic.sh 120

check-cluster:
	@kind get clusters 2>/dev/null | grep -qx '$(CLUSTER)' || { echo "Cluster '$(CLUSTER)' não existe. Rode: make kind-up"; exit 1; }
	@$(KUBECTL) cluster-info >/dev/null 2>&1 || { echo "Cluster '$(CLUSTER)' não responde (contexto $(KCTX))."; exit 1; }

floci-creds: check-cluster  ## Credenciais FICTÍCIAS do Floci para o SecretStore (apenas local)
	$(KUBECTL) create namespace $(NS) --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) -n $(NS) create secret generic floci-aws-credentials \
	  --from-literal=access-key=test --from-literal=secret-access-key=test \
	  --dry-run=client -o yaml | $(KUBECTL) apply -f -

# Fluxo único no Kubernetes: o banco é o RDS do Floci (criado por `make tf-apply-local`) e o ESO cria o Secret
# estuda-db a partir do Secrets Manager do Floci. O MySQL do docker compose é só para desenvolvimento local.
deploy: floci-creds   ## Release platform (SecretStore/ExternalSecret) e depois release app (hook de migration)
	@# SKIP_BUILD=1: usa imagens já presentes localmente (o CD baixa a que o CI construiu, escaneou e assinou).
	@if [ "$(SKIP_BUILD)" != "1" ]; then \
	  docker build -t $(IMAGE):$(TAG) . && \
	  docker build -f Dockerfile.migrations -t $(MIGRATIONS_IMAGE):$(TAG) . ; \
	fi
	kind load docker-image $(IMAGE):$(TAG) $(MIGRATIONS_IMAGE):$(TAG) --name $(CLUSTER)
	$(HELM) upgrade --install platform helm/platform -n $(NS) -f helm/platform/values-floci.yaml --wait --timeout 10m
	$(KUBECTL) -n $(NS) wait --for=condition=Ready externalsecret/estuda-db --timeout=120s
	$(HELM) upgrade --install app helm/app -n $(NS) -f helm/app/values-local.yaml \
	  --set image.tag=$(TAG) $(APP_EXTRA) --wait --timeout 5m

smoke: check-cluster
	NS=$(NS) KUBE_CONTEXT=$(KCTX) bash scripts/smoke.sh

rollback: check-cluster  ## Volta o Deployment à revisão anterior (NÃO desfaz migrations: devem ser retrocompatíveis)
	$(HELM) rollback app -n $(NS) --wait

tf-check:      ## Produção: só valida o código (fmt, validate, tflint, Checkov). NUNCA é aplicado.
	terraform -chdir=terraform fmt -check -recursive
	for env in local prod; do \
	  terraform -chdir=terraform/environments/$$env init -backend=false -input=false && \
	  terraform -chdir=terraform/environments/$$env validate || exit 1; \
	done
	tflint --recursive --chdir=terraform
	@# O ambiente local aponta para um emulador e desliga de propósito proteções (deletion protection, logs, IAM auth).
	@# O alvo de segurança é environments/prod e os módulos que ele usa.
	checkov -d terraform --quiet --compact --skip-path terraform/environments/local

# Ambiente local: aplica DE VERDADE contra o Floci (emulador). Credenciais FICTÍCIAS, só para o emulador.
TF_LOCAL := AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1 \
  terraform -chdir=terraform/environments/local

tf-apply-local: floci-up  ## Cria VPC, RDS e o segredo estuda/db no Floci com os mesmos módulos de produção
	$(TF_LOCAL) init -input=false
	$(TF_LOCAL) apply -input=false -auto-approve

tf-destroy-local:         ## Remove o que o Terraform criou no Floci
	$(TF_LOCAL) destroy -input=false -auto-approve

kind-down:
	kind delete cluster --name $(CLUSTER)
