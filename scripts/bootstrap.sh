#!/usr/bin/env bash
# Instala as ferramentas necessárias para rodar o projeto em um Debian 13 (trixie).
# Uso:   ./scripts/bootstrap.sh            (como usuário normal com sudo, NÃO como root)
# Pinar: KIND_VERSION=v0.30.0 HELM_VERSION=v3.19.0 ./scripts/bootstrap.sh
# Versões vazias = última estável, resolvida na hora. O resumo final imprime o que foi instalado,
# para você copiar para este script e fixar (reprodutibilidade).
# Idempotente: ferramentas já instaladas são puladas (FORCE=1 reinstala as baixadas por binário).
set -euo pipefail

GO_VERSION="${GO_VERSION:-}"                    # ex.: 1.25.1 (sem "go")
KIND_VERSION="${KIND_VERSION:-}"                # ex.: v0.30.0
HELM_VERSION="${HELM_VERSION:-}"                # ex.: v3.19.0
KUBECTL_VERSION="${KUBECTL_VERSION:-}"          # ex.: v1.34.1
TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.15.8}"
TFLINT_VERSION="${TFLINT_VERSION:-}"            # ex.: v0.59.1
GOLANGCI_VERSION="${GOLANGCI_VERSION:-}"        # ex.: v2.5.0
FORCE="${FORCE:-0}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERRO: %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "rode como usuário normal (o script usa sudo quando precisa)."
command -v sudo >/dev/null || die "sudo não encontrado. Como root: apt-get install -y sudo && usermod -aG sudo $USER"
# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID:-}" == "debian" ]] || die "pensado para Debian (detectado: ${ID:-?})."

case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) die "arquitetura não suportada: $(uname -m)" ;;
esac

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

need() { [[ "$FORCE" == "1" ]] || ! command -v "$1" >/dev/null; }

gh_latest() { # gh_latest owner/repo -> tag (ex.: v0.30.0)
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name
}

verify() { # verify <arquivo> <sha256>
  echo "$2  $1" | sha256sum -c - >/dev/null || die "checksum inválido para $1"
}

# ---------------------------------------------------------------- pacotes base
log "Pacotes base (apt)"
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg git make unzip jq tar xz-utils build-essential \
  python3 python3-venv pipx bash-completion

# ---------------------------------------------------------------- Docker Engine
if need docker; then
  log "Docker Engine (repositório oficial)"
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker
fi
if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
  sudo usermod -aG docker "$USER"
  NEED_RELOGIN=1
fi

# Kind com muitos pods (kube-prometheus-stack) estoura limites padrão do inotify.
log "Ajuste de sysctl (inotify) para o Kind"
sudo tee /etc/sysctl.d/99-kind.conf >/dev/null <<'EOF'
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
EOF
sudo sysctl --system >/dev/null

# ---------------------------------------------------------------- Go
if need go && [[ ! -x /usr/local/go/bin/go || "$FORCE" == "1" ]]; then
  log "Go"
  json="$(curl -fsSL 'https://go.dev/dl/?mode=json')"
  if [[ -z "$GO_VERSION" ]]; then GO_VERSION="$(jq -r '.[0].version' <<<"$json" | sed 's/^go//')"; fi
  sha="$(jq -r --arg v "go${GO_VERSION}" --arg a "$ARCH" \
    '.[] | select(.version==$v) | .files[] | select(.os=="linux" and .arch==$a and .kind=="archive") | .sha256' <<<"$json")"
  [[ -n "$sha" ]] || die "Go ${GO_VERSION} não encontrado em go.dev (a lista só traz as versões recentes)."
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" -o "$TMP/go.tgz"
  verify "$TMP/go.tgz" "$sha"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "$TMP/go.tgz"
fi
sudo tee /etc/profile.d/go.sh >/dev/null <<'EOF'
export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"
EOF
export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"

# ---------------------------------------------------------------- kind
if need kind; then
  log "kind"
  KIND_VERSION="${KIND_VERSION:-$(gh_latest kubernetes-sigs/kind)}"
  base="https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}"
  curl -fsSL "${base}/kind-linux-${ARCH}" -o "$TMP/kind"
  sha="$(curl -fsSL "${base}/kind-linux-${ARCH}.sha256sum" | awk '{print $1}')"
  verify "$TMP/kind" "$sha"
  sudo install -m 0755 "$TMP/kind" /usr/local/bin/kind
fi

# ---------------------------------------------------------------- kubectl
if need kubectl; then
  log "kubectl"
  KUBECTL_VERSION="${KUBECTL_VERSION:-$(curl -fsSL https://dl.k8s.io/release/stable.txt)}"
  base="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}"
  curl -fsSL "${base}/kubectl" -o "$TMP/kubectl"
  verify "$TMP/kubectl" "$(curl -fsSL "${base}/kubectl.sha256")"
  sudo install -m 0755 "$TMP/kubectl" /usr/local/bin/kubectl
fi

# ---------------------------------------------------------------- helm
if need helm; then
  log "helm"
  HELM_VERSION="${HELM_VERSION:-$(gh_latest helm/helm)}"
  f="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
  curl -fsSL "https://get.helm.sh/${f}" -o "$TMP/${f}"
  sha="$(curl -fsSL "https://get.helm.sh/${f}.sha256sum" | awk '{print $1}')"
  verify "$TMP/${f}" "$sha"
  tar -C "$TMP" -xzf "$TMP/${f}"
  sudo install -m 0755 "$TMP/linux-${ARCH}/helm" /usr/local/bin/helm
fi

# ---------------------------------------------------------------- terraform
if need terraform; then
  log "terraform ${TERRAFORM_VERSION}"
  base="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}"
  f="terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip"
  curl -fsSL "${base}/${f}" -o "$TMP/${f}"
  sha="$(curl -fsSL "${base}/terraform_${TERRAFORM_VERSION}_SHA256SUMS" | awk -v f="$f" '$2==f {print $1}')"
  verify "$TMP/${f}" "$sha"
  unzip -oq "$TMP/${f}" terraform -d "$TMP"
  sudo install -m 0755 "$TMP/terraform" /usr/local/bin/terraform
fi

# ---------------------------------------------------------------- tflint
if need tflint; then
  log "tflint"
  TFLINT_VERSION="${TFLINT_VERSION:-$(gh_latest terraform-linters/tflint)}"
  base="https://github.com/terraform-linters/tflint/releases/download/${TFLINT_VERSION}"
  f="tflint_linux_${ARCH}.zip"
  curl -fsSL "${base}/${f}" -o "$TMP/${f}"
  sha="$(curl -fsSL "${base}/checksums.txt" | awk -v f="$f" '$2==f {print $1}')"
  verify "$TMP/${f}" "$sha"
  unzip -oq "$TMP/${f}" tflint -d "$TMP"
  sudo install -m 0755 "$TMP/tflint" /usr/local/bin/tflint
fi

# ---------------------------------------------------------------- golangci-lint
if need golangci-lint; then
  log "golangci-lint"
  GOLANGCI_VERSION="${GOLANGCI_VERSION:-$(gh_latest golangci/golangci-lint)}"
  v="${GOLANGCI_VERSION#v}"
  base="https://github.com/golangci/golangci-lint/releases/download/${GOLANGCI_VERSION}"
  f="golangci-lint-${v}-linux-${ARCH}.tar.gz"
  curl -fsSL "${base}/${f}" -o "$TMP/${f}"
  sha="$(curl -fsSL "${base}/golangci-lint-${v}-checksums.txt" | awk -v f="$f" '$2==f {print $1}')"
  verify "$TMP/${f}" "$sha"
  tar -C "$TMP" -xzf "$TMP/${f}"
  sudo install -m 0755 "$TMP/golangci-lint-${v}-linux-${ARCH}/golangci-lint" /usr/local/bin/golangci-lint
fi

# ---------------------------------------------------------------- Checkov e AWS CLI (pipx)
pipx ensurepath >/dev/null
export PATH="$PATH:$HOME/.local/bin"
command -v checkov >/dev/null || { log "checkov"; pipx install checkov; }
command -v aws >/dev/null     || { log "awscli (usado para semear o segredo no Floci)"; pipx install awscli; }

# ---------------------------------------------------------------- resumo
log "Resumo"
printf '%-15s %s\n' \
  docker        "$(sudo docker --version 2>/dev/null || echo n/d)" \
  compose       "$(sudo docker compose version 2>/dev/null || echo n/d)" \
  go            "$(go version 2>/dev/null || echo n/d)" \
  kind          "$(kind --version 2>/dev/null || echo n/d)" \
  kubectl       "$(kubectl version --client 2>/dev/null | head -1 || echo n/d)" \
  helm          "$(helm version --short 2>/dev/null || echo n/d)" \
  terraform     "$(terraform version 2>/dev/null | head -1 || echo n/d)" \
  tflint        "$(tflint --version 2>/dev/null | head -1 || echo n/d)" \
  golangci-lint "$(golangci-lint --version 2>/dev/null | head -1 || echo n/d)" \
  checkov       "$(checkov --version 2>/dev/null || echo n/d)" \
  aws           "$(aws --version 2>/dev/null || echo n/d)"

if [[ "${NEED_RELOGIN:-0}" == "1" ]]; then
  printf '\n\033[1;33mAtenção:\033[0m seu usuário foi adicionado ao grupo docker. Saia e entre de novo no SSH (ou rode "newgrp docker") antes de usar docker sem sudo.\n'
fi
printf '\nPronto. Abra um novo shell (ou "source /etc/profile.d/go.sh") para o PATH do Go.\n'
