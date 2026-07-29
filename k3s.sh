#!/usr/bin/env bash
# k3s.sh — Emula mgc kubernetes para clusters K3s na Magalu Cloud
# Move Tech 2026 (Magalu × Prósper Digital Skills)
#
# Uso:
#   k3s.sh kubernetes cluster create
#   k3s.sh kubernetes cluster start               --cluster-id ID
#   k3s.sh kubernetes cluster stop                --cluster-id ID
#   k3s.sh kubernetes cluster kubeconfig          --cluster-id ID > kubeconfig.yaml
#   k3s.sh kubernetes cluster list
#   k3s.sh kubernetes cluster get                 --cluster-id ID
#   k3s.sh kubernetes cluster delete              --cluster-id ID
#   k3s.sh kubernetes cluster configure-registry  --cluster-id ID
#   k3s.sh kubernetes cluster fix-traefik         --cluster-id ID           # desabilita Traefik em cluster existente
#   k3s.sh network ip-cleanup

set -euo pipefail

# ─── Auto-update ──────────────────────────────────────────────────────────────
SCRIPT_URL="https://raw.githubusercontent.com/move-tech-cloud-computing/k3s-mgc/main/k3s.sh"

_sha256() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

check_update() {
  local tmp; tmp=$(mktemp)
  curl --connect-timeout 3 -sf "${SCRIPT_URL}?$(date +%s)" -o "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }

  local local_hash remote_hash
  local_hash=$(_sha256 "$0")
  remote_hash=$(_sha256 "$tmp")

  if [[ "$local_hash" == "$remote_hash" ]]; then
    rm -f "$tmp"
    return 0
  fi

  echo -e "\n${Y}⚠${N} Uma versão mais recente do script está disponível."
  local _upd="n"
  [[ -t 0 ]] && read -rp "  Atualizar agora? [s/N] " _upd
  if [[ "$(echo "$_upd" | tr '[:upper:]' '[:lower:]')" == "s" ]]; then
    chmod +x "$tmp"
    mv "$tmp" "$0"
    echo -e "${G}✓${N} Script atualizado. Rode o comando novamente."
    exit 0
  fi
  rm -f "$tmp"
  echo ""
}

# ─── Constantes ───────────────────────────────────────────────────────────────
SG_NAME="sg-k3s-cluster"
MACHINE_TYPE="BV2-2-40"
IMAGE_NAME="cloud-ubuntu-24.04 LTS"
VM_USER="ubuntu"
SSH_KEY_NAME="ssh-k3s-cluster"
SSH_KEY_PATH="${HOME}/.ssh/${SSH_KEY_NAME}"

# ─── Cores ────────────────────────────────────────────────────────────────────
G='\033[0;32m' Y='\033[1;33m' R='\033[0;31m'
C='\033[0;36m' B='\033[1m'   D='\033[2m' N='\033[0m'

ok()        { echo -e "${G}✓${N} $*"; }
info()      { echo -e "${C}→${N} $*"; }
warn()      { echo -e "${Y}⚠${N} $*"; }
die()       { echo -e "\n${R}✗${N} $*\n" >&2; exit 1; }
hdr()       { echo -e "\n┌ ${B}$*${N}"; }
step()      { echo -e "\n${C}→${N} $(printf '%-20s' "$1") $2"; }
step_ok()   { echo -e "${G}✓${N} $(printf '%-20s' "$1") $2"; }
step_data() { printf "    %-10s %s\n" "$1" "$2"; }

# ─── mgc wrapper que strip ANSI e força JSON ──────────────────────────────────
mgcj() { "$@" --output json 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'; }

# ─── Lookups de cluster via API ───────────────────────────────────────────────

# Retorna JSON {vm_id, name, ip} buscando pelo ID da VM, ou falha com exit 1
cluster_by_id() {
  local vm_id="$1"
  local vm_json
  vm_json=$(mgcj mgc virtual-machine instances get "$vm_id" 2>/dev/null) || return 1
  echo "$vm_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
name = d.get('name', '')
if not name.startswith('vm-k3s-cluster-'):
    sys.exit(1)
ifaces = d.get('network', {}).get('interfaces', [])
ip = ifaces[0].get('associated_public_ipv4', '') if ifaces else ''
print(json.dumps({'vm_id': d['id'], 'name': name[len('vm-k3s-cluster-'):], 'ip': ip}))
" 2>/dev/null
}

# Lista todos os clusters como linhas "vm_id|name|ip"
list_clusters() {
  mgcj mgc virtual-machine instances list | python3 -c "
import json, sys
vms = json.load(sys.stdin).get('instances', [])
prefix = 'vm-k3s-cluster-'
for v in vms:
    n = v.get('name', '')
    if not n.startswith(prefix):
        continue
    ifaces = v.get('network', {}).get('interfaces', [])
    ip = ifaces[0].get('associated_public_ipv4', '—') if ifaces else '—'
    print(v['id'] + '|' + n[len(prefix):] + '|' + ip)
" 2>/dev/null || true
}

# Conta clusters restantes, excluindo o VM ID informado
count_clusters_except() {
  local exclude_id="$1"
  mgcj mgc virtual-machine instances list | python3 -c "
import json, sys
vms = json.load(sys.stdin).get('instances', [])
print(sum(1 for v in vms
          if v.get('name', '').startswith('vm-k3s-cluster-')
          and v.get('id', '') != '$exclude_id'))
" 2>/dev/null || echo "0"
}

# Retorna o ID do SG pelo nome, ou string vazia
get_sg_id() {
  mgcj mgc network security-groups list | python3 -c "
import json, sys
sgs = json.load(sys.stdin).get('security_groups', [])
match = [s for s in sgs if s.get('name') == '${SG_NAME}']
print(match[0]['id'] if match else '')
" 2>/dev/null || echo ""
}

# ─── Pré-requisitos ───────────────────────────────────────────────────────────
check_prereqs() {
  command -v mgc     >/dev/null 2>&1 || die "mgc CLI não encontrado. Veja: https://docs.magalu.cloud/docs/cli-mgc"
  command -v ssh     >/dev/null 2>&1 || die "ssh não encontrado."
  command -v python3 >/dev/null 2>&1 || die "python3 não encontrado."
  command -v kubectl >/dev/null 2>&1 || warn "kubectl não encontrado. Instale: https://kubernetes.io/docs/tasks/tools/"
  mgcj mgc virtual-machine instances list >/dev/null 2>&1 || die "mgc não autenticado. Execute: mgc auth login"
}

# ─── Garante chave SSH dedicada ───────────────────────────────────────────────
_ssh_status=""

_gen_ssh_key() {
  mkdir -p "${HOME}/.ssh" && chmod 700 "${HOME}/.ssh"
  ssh-keygen -t ed25519 -N "" -f "${SSH_KEY_PATH}" -C "k3s-mgc" >/dev/null 2>&1
  chmod 600 "${SSH_KEY_PATH}"
}

ensure_ssh_key() {
  step "Chave SSH" "Verificando chave SSH"

  # Busca entrada registrada na MGC (id + conteúdo da chave pública)
  local mgc_raw
  mgc_raw=$(mgcj mgc profile ssh-keys list | python3 -c "
import json, sys
keys = json.load(sys.stdin).get('results', [])
match = [k for k in keys if k.get('name') == '${SSH_KEY_NAME}']
print(json.dumps(match[0]) if match else '')
" 2>/dev/null || echo "")

  local mgc_id="" mgc_pub=""
  if [[ -n "$mgc_raw" ]]; then
    mgc_id=$(echo "$mgc_raw"  | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))"  2>/dev/null || echo "")
    mgc_pub=$(echo "$mgc_raw" | python3 -c "import json,sys; print(json.load(sys.stdin).get('key',''))" 2>/dev/null || echo "")
  fi

  local local_exists=0
  [[ -f "${SSH_KEY_PATH}" ]] && local_exists=1

  if [[ "$local_exists" -eq 1 ]] && [[ -n "$mgc_id" ]]; then
    # Ambos existem — verificar se o par bate (compara tipo+material, ignora comentário)
    local derived_pub
    derived_pub=$(ssh-keygen -y -f "${SSH_KEY_PATH}" 2>/dev/null | awk '{print $1" "$2}')
    local mgc_pub_trimmed
    mgc_pub_trimmed=$(echo "$mgc_pub" | awk '{print $1" "$2}')

    if [[ "$derived_pub" == "$mgc_pub_trimmed" ]]; then
      _ssh_status="em sincronia"
    else
      warn "Chave local e MGC divergem — recadastrando com a chave local"
      mgcj mgc profile ssh-keys delete --key-id="$mgc_id" --no-confirm >/dev/null 2>&1 || true
      mgcj mgc profile ssh-keys create \
        --name="${SSH_KEY_NAME}" \
        --key="$(cat "${SSH_KEY_PATH}.pub")" >/dev/null \
        || die "Falha ao recadastrar chave SSH na Magalu Cloud"
      _ssh_status="recadastrada"
    fi

  elif [[ "$local_exists" -eq 0 ]] && [[ -n "$mgc_id" ]]; then
    # Privada local sumiu mas MGC tem a pública antiga — impossível usar o par.
    # Deleta da MGC, gera novo par e recadastra.
    warn "Chave local ausente mas '${SSH_KEY_NAME}' já está na MGC — recriando par"
    mgcj mgc profile ssh-keys delete --key-id="$mgc_id" --no-confirm >/dev/null 2>&1 || true
    _gen_ssh_key
    mgcj mgc profile ssh-keys create \
      --name="${SSH_KEY_NAME}" \
      --key="$(cat "${SSH_KEY_PATH}.pub")" >/dev/null \
      || die "Falha ao cadastrar chave SSH na Magalu Cloud"
    _ssh_status="recriada"

  elif [[ "$local_exists" -eq 1 ]] && [[ -z "$mgc_id" ]]; then
    # Chave local existe mas não está na MGC — cadastrar
    mgcj mgc profile ssh-keys create \
      --name="${SSH_KEY_NAME}" \
      --key="$(cat "${SSH_KEY_PATH}.pub")" >/dev/null \
      || die "Falha ao cadastrar chave SSH na Magalu Cloud"
    _ssh_status="cadastrada"

  else
    # Nenhuma das duas — gerar par novo e registrar
    _gen_ssh_key
    mgcj mgc profile ssh-keys create \
      --name="${SSH_KEY_NAME}" \
      --key="$(cat "${SSH_KEY_PATH}.pub")" >/dev/null \
      || die "Falha ao cadastrar chave SSH na Magalu Cloud"
    _ssh_status="gerada"
  fi

  step_ok "Chave SSH" "Chave ${_ssh_status}"
  step_data "Nome"  "${SSH_KEY_NAME}"
  step_data "Local" "${SSH_KEY_PATH}"
}

# ─── Verifica status da chave SSH (read-only, sem efeitos colaterais) ─────────
# Retorna: ok | diverge | local-missing | mgc-missing | both-missing
_check_ssh_key_status() {
  local mgc_raw
  mgc_raw=$(mgcj mgc profile ssh-keys list | python3 -c "
import json, sys
keys = json.load(sys.stdin).get('results', [])
match = [k for k in keys if k.get('name') == '${SSH_KEY_NAME}']
print(json.dumps(match[0]) if match else '')
" 2>/dev/null || echo "")

  local mgc_pub=""
  if [[ -n "$mgc_raw" ]]; then
    mgc_pub=$(echo "$mgc_raw" | python3 -c "import json,sys; print(json.load(sys.stdin).get('key',''))" 2>/dev/null || echo "")
  fi

  local local_exists=0
  [[ -f "${SSH_KEY_PATH}" ]] && local_exists=1

  if [[ "$local_exists" -eq 1 ]] && [[ -n "$mgc_pub" ]]; then
    local derived_pub mgc_pub_trimmed
    derived_pub=$(ssh-keygen -y -f "${SSH_KEY_PATH}" 2>/dev/null | awk '{print $1" "$2}')
    mgc_pub_trimmed=$(echo "$mgc_pub" | awk '{print $1" "$2}')
    [[ "$derived_pub" == "$mgc_pub_trimmed" ]] && echo "ok" || echo "diverge"
  elif [[ "$local_exists" -eq 0 ]] && [[ -n "$mgc_pub" ]]; then
    echo "local-missing"
  elif [[ "$local_exists" -eq 1 ]] && [[ -z "$mgc_pub" ]]; then
    echo "mgc-missing"
  else
    echo "both-missing"
  fi
}

# ─── SSH helper ───────────────────────────────────────────────────────────────
vm_ssh() { ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes "${VM_USER}@${1}" "${@:2}"; }

wait_ssh() {
  local ip="$1"
  step "SSH" "Aguardando conexão"
  for i in $(seq 1 60); do
    if ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
         ubuntu@"$ip" "exit 0" 2>/dev/null; then
      step_ok "SSH" "Conexão estabelecida"
      return 0
    fi
    sleep 5
  done
  die "Timeout ao aguardar SSH (300s). Verifique a VM no console da MGC."
}

# ─── Garante Security Group ───────────────────────────────────────────────────
_sg_id=""  # preenchido por ensure_sg

ensure_sg() {
  step "Security Group" "Verificando grupo de segurança"

  _sg_id=$(get_sg_id)

  if [[ -n "$_sg_id" ]]; then
    step_ok "Security Group" "Grupo já existente"
    step_data "Nome" "${SG_NAME}"
    step_data "ID"   "${_sg_id}"
    return
  fi

  local sg_json
  sg_json=$(mgcj mgc network security-groups create \
    --name="${SG_NAME}" \
    --description="K3s — Move Tech") || die "Falha ao criar Security Group"

  _sg_id=$(echo "$sg_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" || echo "")
  [[ -n "$_sg_id" ]] || die "Não foi possível obter o ID do Security Group"

  for port in 22 80 8000 6443; do
    mgcj mgc network security-groups rules create \
      --security-group-id="$_sg_id" --direction="ingress" --ethertype="IPv4" \
      --protocol="tcp" --port-range-min=$port --port-range-max=$port \
      --remote-ip-prefix="0.0.0.0/0" --wait >/dev/null
    mgcj mgc network security-groups rules create \
      --security-group-id="$_sg_id" --direction="ingress" --ethertype="IPv6" \
      --protocol="tcp" --port-range-min=$port --port-range-max=$port \
      --remote-ip-prefix="::/0" --wait >/dev/null
  done

  mgcj mgc network security-groups rules create \
    --security-group-id="$_sg_id" --direction="egress" --ethertype="IPv4" \
    --protocol="tcp" --remote-ip-prefix="0.0.0.0/0" --wait >/dev/null
  mgcj mgc network security-groups rules create \
    --security-group-id="$_sg_id" --direction="egress" --ethertype="IPv6" \
    --protocol="tcp" --remote-ip-prefix="::/0" --wait >/dev/null

  step_ok "Security Group" "Grupo criado com sucesso"
  step_data "Nome"   "${SG_NAME}"
  step_data "ID"     "${_sg_id}"
  step_data "Portas" "22 (SSH)  80 (HTTP)  8000 (API)  6443 (Kubernetes)"
}

# ─── COMANDO: create ──────────────────────────────────────────────────────────
cmd_create() {
  hdr "Novo cluster K3s"

  # ── Nome do cluster ───────────────────────────────────────────────────────
  local name=""
  while [[ -z "$name" ]]; do
    read -rp "  Nome do cluster: " name
    name="$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
    [[ -z "$name" ]] && echo "  Nome não pode ser vazio."
  done

  # ── Tipo de VM ────────────────────────────────────────────────────────────
  echo ""
  echo -e "  ${C}→${N} Selecione o tipo de VM:"
  echo ""
  echo "    [1] BV1-1-10   —  1 vCPU    1 GB RAM   10 GB"
  echo "    [2] BV1-2-10   —  1 vCPU    2 GB RAM   10 GB"
  echo "    [3] BV2-2-10   —  2 vCPUs   2 GB RAM   10 GB"
  echo -e "    [4] BV1-4-10   —  1 vCPU    4 GB RAM   10 GB   ${D}(recomendado)${N}"
  echo "    [5] BV2-4-10   —  2 vCPUs   4 GB RAM   10 GB"
  echo ""
  local machine_type=""
  while [[ -z "$machine_type" ]]; do
    read -rp "  Escolha [padrão 4]: " _vm_opt
    case "${_vm_opt:-4}" in
      1) machine_type="BV1-1-10" ;;
      2) machine_type="BV1-2-10" ;;
      3) machine_type="BV2-2-10" ;;
      4) machine_type="BV1-4-10" ;;
      5) machine_type="BV2-4-10" ;;
      *) echo "  Opção inválida." ;;
    esac
  done
  echo -e "  ${G}✓${N} Tipo selecionado: ${B}${machine_type}${N}"
  echo ""

  local vm_name="vm-k3s-cluster-${name}"

  hdr "Criando cluster '${name}' (${machine_type})"

  ensure_ssh_key
  ensure_sg
  local sg_id="$_sg_id"

  # ── VM ───────────────────────────────────────────────────────────────────
  local vm_id
  vm_id=$(mgcj mgc virtual-machine instances list | python3 -c "
import json,sys
vms=[v for v in json.load(sys.stdin).get('instances',[]) if v.get('name')=='${vm_name}']
print(vms[0]['id'] if vms else '')
" 2>/dev/null || echo "")

  if [[ -n "$vm_id" ]]; then
    step "Máquina virtual" "Verificando VM"
    step_ok "Máquina virtual" "VM já existente"
    step_data "Nome" "${vm_name}"
    step_data "ID"   "${vm_id}"
  else
    local vpc_id
    vpc_id=$(mgcj mgc network vpcs list | python3 -c "
import json,sys
vpcs=[v for v in json.load(sys.stdin).get('vpcs',[]) if v.get('name')=='vpc_default']
print(vpcs[0]['id'] if vpcs else '')
" 2>/dev/null || echo "")
    [[ -n "$vpc_id" ]] || die "vpc_default não encontrada."

    local ip_quota_ok
    ip_quota_ok=$(mgcj mgc network public-ips list | python3 -c "
import json,sys
ips = json.load(sys.stdin).get('public_ips', [])
orphans = [ip for ip in ips if ip.get('port_id') is None and ip.get('status') == 'created']
print(len(orphans))
" 2>/dev/null || echo "0")
    if [[ "$ip_quota_ok" -gt 0 ]]; then
      echo ""
      warn "Há ${ip_quota_ok} IP(s) público(s) órfão(s) que podem consumir sua cota."
      warn "Se a criação falhar, execute: ./k3s.sh network ip-cleanup"
      echo ""
    fi

    step "Máquina virtual" "Criando VM"
    local vm_json
    vm_json=$(mgcj mgc virtual-machine instances create \
      --name="${vm_name}" \
      --machine-type.name="${machine_type}" \
      --image.name="${IMAGE_NAME}" \
      --ssh-key-name="${SSH_KEY_NAME}" \
      --network.vpc.id="${vpc_id}" \
      --network.associate-public-ip=true \
      --network.interface.security-groups="[{\"id\":\"${sg_id}\"}]") || die "Falha ao criar VM"

    vm_id=$(echo "$vm_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" || echo "")
    [[ -n "$vm_id" ]] || die "Não foi possível obter o ID da VM"

    step_ok "Máquina virtual" "VM criada com sucesso"
    step_data "Nome"   "${vm_name}"
    step_data "ID"     "${vm_id}"
    step_data "Tipo"   "${machine_type}"
    step_data "Imagem" "Ubuntu 24.04 LTS"
  fi

  # ── IP público ───────────────────────────────────────────────────────────
  local vm_ip=""
  step "IP público" "Aguardando atribuição"
  for i in $(seq 1 30); do
    vm_ip=$(mgcj mgc virtual-machine instances get "$vm_id" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ifaces=d.get('network',{}).get('interfaces',[])
print(ifaces[0].get('associated_public_ipv4','') if ifaces else '')
" 2>/dev/null || echo "")
    [[ -n "$vm_ip" ]] && break
    sleep 5
  done
  [[ -n "$vm_ip" ]] || die "IP público não atribuído. Execute: ./k3s.sh network ip-cleanup"
  step_ok "IP público" "IP atribuído"
  step_data "Endereço" "${vm_ip}"

  # ── SSH ──────────────────────────────────────────────────────────────────
  wait_ssh "$vm_ip"

  # ── K3s ──────────────────────────────────────────────────────────────────
  local k3s_installed
  k3s_installed=$(vm_ssh "$vm_ip" "command -v k3s >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null || echo "no")

  if [[ "$k3s_installed" == "yes" ]]; then
    step "K3s" "Verificando instalação"
    step_ok "K3s" "K3s já instalado"
  else
    step "K3s" "Instalando K3s"
    vm_ssh "$vm_ip" \
      "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--tls-san ${vm_ip} --disable=traefik --node-external-ip=${vm_ip}' sudo -E sh - >/dev/null 2>&1"
    local k3s_version
    k3s_version=$(vm_ssh "$vm_ip" "k3s --version 2>/dev/null | head -1 | awk '{print \$3}'" 2>/dev/null || echo "desconhecida")
    step_ok "K3s" "K3s instalado com sucesso"
    step_data "Versão" "${k3s_version}"
  fi

  # Persiste config.yaml para garantir que Traefik permaneça desabilitado após reinicializações
  vm_ssh "$vm_ip" \
    "printf 'node-external-ip: ${vm_ip}\ndisable:\n  - traefik\n' | sudo tee /etc/rancher/k3s/config.yaml >/dev/null"

  # ── Aguarda K3s Ready ────────────────────────────────────────────────────
  step "Cluster" "Aguardando nó ficar pronto"
  local status=""
  for i in $(seq 1 24); do
    status=$(vm_ssh "$vm_ip" "sudo k3s kubectl get nodes --no-headers 2>/dev/null | awk '{print \$2}'" 2>/dev/null || echo "")
    [[ "$status" == "Ready" ]] && break
    sleep 5
  done
  [[ "$status" == "Ready" ]] || die "K3s não ficou Ready após 120s."
  step_ok "Cluster" "Nó pronto"

  # ── Kubeconfig ───────────────────────────────────────────────────────────
  step "kubectl" "Configurando acesso ao cluster"
  mkdir -p "${HOME}/.kube"
  vm_ssh "$vm_ip" "sudo cat /etc/rancher/k3s/k3s.yaml" \
    | sed "s/127.0.0.1/${vm_ip}/g" \
    > "${HOME}/.kube/config"
  chmod 600 "${HOME}/.kube/config"
  step_ok "kubectl" "Configurado com sucesso"
  step_data "Arquivo"  "${HOME}/.kube/config"
  step_data "Contexto" "default"

  # ── Container Registry (interativo) ──────────────────────────────────────
  if [[ -t 0 ]]; then
    echo ""
    read -rp "  Deseja configurar acesso a um Container Registry? [s/N] " _reg_ans
    if [[ "$(echo "$_reg_ans" | tr '[:upper:]' '[:lower:]')" == "s" ]]; then
      setup_registry
    fi
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${G}${B}✓ Cluster '${name}' pronto!${N}"
  echo ""
  echo -e "  ID do cluster:  ${C}${vm_id}${N}"
  echo -e "  Verificar:      ${C}kubectl get nodes${N}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ─── COMANDO: kubeconfig ──────────────────────────────────────────────────────
cmd_kubeconfig() {
  local cluster_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster-id) cluster_id="$2"; shift 2 ;;
      --cluster-id=*) cluster_id="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done

  [[ -n "$cluster_id" ]] || die "Informe o ID do cluster: --cluster-id ID"

  local cluster
  cluster=$(cluster_by_id "$cluster_id") || die "Cluster '${cluster_id}' não encontrado. Liste com: ./k3s.sh kubernetes cluster list"
  local vm_ip
  vm_ip=$(echo "$cluster" | python3 -c "import json,sys; print(json.load(sys.stdin)['ip'])")

  vm_ssh "$vm_ip" "sudo cat /etc/rancher/k3s/k3s.yaml" | sed "s/127.0.0.1/${vm_ip}/g"
}

# ─── COMANDO: list ────────────────────────────────────────────────────────────
cmd_list() {
  local clusters
  clusters=$(list_clusters)

  if [[ -z "$clusters" ]]; then
    echo "Nenhum cluster encontrado."
    return
  fi

  printf "%-38s %-20s %-10s %-16s %-10s %-12s %s\n" \
    "ID" "NOME" "TIPO" "IPv4 PUBLICO" "ZONA" "CRIADO EM" "ESTADO"
  printf "%-38s %-20s %-10s %-16s %-10s %-12s %s\n" \
    "──────────────────────────────────────" "────────────────────" "──────────" "────────────────" "──────────" "────────────" "────────"
  echo ""

  while IFS='|' read -r vm_id name ip; do
    [[ -z "$name" ]] && continue

    local vm_json
    vm_json=$(mgcj mgc virtual-machine instances get "$vm_id" 2>/dev/null) || vm_json=""

    local vm_state vm_pub_ip vm_type vm_zone vm_created
    vm_state=$(echo "$vm_json"   | python3 -c "import json,sys; print(json.load(sys.stdin).get('state','—'))" 2>/dev/null || echo "—")
    vm_type=$(echo "$vm_json"    | python3 -c "import json,sys; print(json.load(sys.stdin).get('machine_type',{}).get('name','—'))" 2>/dev/null || echo "—")
    vm_zone=$(echo "$vm_json"    | python3 -c "import json,sys; print(json.load(sys.stdin).get('availability_zone','—'))" 2>/dev/null || echo "—")
    vm_created=$(echo "$vm_json" | python3 -c "
import json,sys
d=json.load(sys.stdin).get('created_at','')
print(d[8:10]+'/'+d[5:7]+'/'+d[:4] if len(d)>=10 else '—')
" 2>/dev/null || echo "—")
    vm_pub_ip=$(echo "$vm_json"  | python3 -c "
import json,sys
d=json.load(sys.stdin)
ifaces=d.get('network',{}).get('interfaces',[])
print(ifaces[0].get('associated_public_ipv4','—') if ifaces else '—')
" 2>/dev/null || echo "—")

    local estado_label estado_color
    if [[ "$vm_state" == "running" ]]; then
      estado_label="Ligado"; estado_color="$G"
    else
      estado_label="Desligado"; estado_color="$Y"
    fi

    printf "%-38s %-20s %-10s %-16s %-10s %-12s " \
      "$vm_id" "$name" "$vm_type" "$vm_pub_ip" "$vm_zone" "$vm_created"
    echo -e "${estado_color}${estado_label}${N}"
    echo ""
  done <<< "$clusters"
}

# ─── COMANDO: get ─────────────────────────────────────────────────────────────
cmd_get() {
  local cluster_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster-id) cluster_id="$2"; shift 2 ;;
      --cluster-id=*) cluster_id="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done

  [[ -n "$cluster_id" ]] || die "Informe o ID do cluster: --cluster-id ID"

  local cluster
  cluster=$(cluster_by_id "$cluster_id") || die "Cluster '${cluster_id}' não encontrado."

  local name vm_ip
  name=$(echo "$cluster"  | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
  vm_ip=$(echo "$cluster" | python3 -c "import json,sys; print(json.load(sys.stdin)['ip'])")

  local k3s_version k3s_status
  k3s_version=$(vm_ssh "$vm_ip" "k3s --version 2>/dev/null | head -1 | awk '{print \$3}'" 2>/dev/null || echo "—")
  k3s_status=$(vm_ssh "$vm_ip" "sudo k3s kubectl get nodes --no-headers 2>/dev/null | awk '{print \$2}'" 2>/dev/null || echo "—")

  echo ""
  echo -e "${B}Cluster: ${name}${N}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "  %-18s %s\n" "Nome:"       "${name}"
  printf "  %-18s %s\n" "ID:"         "${cluster_id}"
  printf "  %-18s %s\n" "Status:"     "${k3s_status}"
  printf "  %-18s %s\n" "IP:"         "${vm_ip}"
  printf "  %-18s %s\n" "Versão K3s:" "${k3s_version}"
  echo ""
}

# ─── COMANDO: delete ──────────────────────────────────────────────────────────
cmd_delete() {
  local cluster_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster-id) cluster_id="$2"; shift 2 ;;
      --cluster-id=*) cluster_id="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done

  [[ -n "$cluster_id" ]] || die "Informe o ID do cluster: --cluster-id ID"

  local cluster
  cluster=$(cluster_by_id "$cluster_id") || die "Cluster '${cluster_id}' não encontrado."

  local name vm_ip
  name=$(echo "$cluster"  | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
  vm_ip=$(echo "$cluster" | python3 -c "import json,sys; print(json.load(sys.stdin)['ip'])")

  hdr "Deletando cluster '${name}'"
  echo ""
  local confirm="n"
  [[ -t 0 ]] && read -rp "  Confirmar exclusão de '${name}' (${vm_ip})? [s/N] " confirm
  [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" == "s" ]] || { echo "Cancelado."; exit 0; }

  step "Máquina virtual" "Deletando VM"
  if mgcj mgc virtual-machine instances delete "$cluster_id" --no-confirm --delete-public-ip >/dev/null; then
    step_ok "Máquina virtual" "VM deletada"
    step_data "IP liberado" "${vm_ip}"
  else
    warn "Falha ao deletar VM"
  fi

  local remaining
  remaining=$(count_clusters_except "$cluster_id")

  if [[ "$remaining" -eq 0 ]]; then
    local sg_id
    sg_id=$(get_sg_id)
    if [[ -n "$sg_id" ]]; then
      step "Security Group" "Deletando grupo de segurança"
      if mgcj mgc network security-groups delete --security-group-id "$sg_id" --no-confirm >/dev/null 2>&1; then
        step_ok "Security Group" "Grupo deletado"
      else
        warn "Falha ao deletar Security Group (pode já ter sido removido)"
      fi
    fi
  else
    warn "Security Group mantido — ainda há ${remaining} cluster(s) usando."
  fi

  echo ""
  ok "Cluster '${name}' removido."
}

# ─── COMANDO: stop ────────────────────────────────────────────────────────────
cmd_stop() {
  local cluster_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster-id) cluster_id="$2"; shift 2 ;;
      --cluster-id=*) cluster_id="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done
  [[ -n "$cluster_id" ]] || die "Informe o ID do cluster: --cluster-id ID"

  local cluster
  cluster=$(cluster_by_id "$cluster_id") || die "Cluster '${cluster_id}' não encontrado. Liste com: ./k3s.sh kubernetes cluster list"
  local name
  name=$(echo "$cluster" | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")

  hdr "Parando cluster '${name}'"

  step "Máquina virtual" "Parando VM"
  mgcj mgc virtual-machine instances stop "$cluster_id" >/dev/null || die "Falha ao parar VM"
  step_ok "Máquina virtual" "VM parada"

  echo ""
  ok "Cluster '${name}' parado."
}

# ─── COMANDO: start ───────────────────────────────────────────────────────────
cmd_start() {
  local cluster_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster-id) cluster_id="$2"; shift 2 ;;
      --cluster-id=*) cluster_id="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done
  [[ -n "$cluster_id" ]] || die "Informe o ID do cluster: --cluster-id ID"

  local cluster
  cluster=$(cluster_by_id "$cluster_id") || die "Cluster '${cluster_id}' não encontrado. Liste com: ./k3s.sh kubernetes cluster list"
  local name vm_ip_anterior
  name=$(echo "$cluster"         | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
  vm_ip_anterior=$(echo "$cluster" | python3 -c "import json,sys; print(json.load(sys.stdin)['ip'])")

  hdr "Iniciando cluster '${name}'"

  step "Máquina virtual" "Iniciando VM"
  mgcj mgc virtual-machine instances start "$cluster_id" >/dev/null || die "Falha ao iniciar VM"
  step_ok "Máquina virtual" "VM iniciada"

  step "IP público" "Aguardando IP"
  local vm_ip=""
  for i in $(seq 1 30); do
    vm_ip=$(mgcj mgc virtual-machine instances get "$cluster_id" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ifaces=d.get('network',{}).get('interfaces',[])
print(ifaces[0].get('associated_public_ipv4','') if ifaces else '')
" 2>/dev/null || echo "")
    [[ -n "$vm_ip" ]] && break
    sleep 5
  done
  [[ -n "$vm_ip" ]] || die "IP público não disponível após iniciar VM."

  if [[ "$vm_ip" != "$vm_ip_anterior" ]]; then
    step_ok "IP público" "IP atribuído (alterado: ${vm_ip_anterior} → ${vm_ip})"
  else
    step_ok "IP público" "IP atribuído (${vm_ip})"
  fi

  wait_ssh "$vm_ip"

  # Garante que config.yaml sempre desabilita Traefik e reflete o IP atual
  step "K3s" "Verificando configuração"
  local needs_update=0
  if [[ "$vm_ip" != "$vm_ip_anterior" ]]; then
    needs_update=1
  else
    local has_traefik_disabled
    has_traefik_disabled=$(vm_ssh "$vm_ip" "grep -q 'traefik' /etc/rancher/k3s/config.yaml 2>/dev/null && echo yes || echo no" 2>/dev/null || echo "no")
    [[ "$has_traefik_disabled" == "no" ]] && needs_update=1
  fi

  if [[ "$needs_update" -eq 1 ]]; then
    vm_ssh "$vm_ip" \
      "printf 'node-external-ip: ${vm_ip}\ndisable:\n  - traefik\n' | sudo tee /etc/rancher/k3s/config.yaml >/dev/null && sudo systemctl restart k3s" \
      2>/dev/null || warn "Não foi possível atualizar configuração do K3s"
    sleep 5
    if [[ "$vm_ip" != "$vm_ip_anterior" ]]; then
      step_ok "K3s" "IP externo atualizado (${vm_ip_anterior} → ${vm_ip})"
    else
      step_ok "K3s" "Traefik desabilitado via config.yaml"
    fi
  else
    step_ok "K3s" "Configuração já está correta"
  fi

  step "kubectl" "Atualizando acesso ao cluster"
  mkdir -p "${HOME}/.kube"
  vm_ssh "$vm_ip" "sudo cat /etc/rancher/k3s/k3s.yaml" \
    | sed "s/127.0.0.1/${vm_ip}/g" \
    > "${HOME}/.kube/config"
  chmod 600 "${HOME}/.kube/config"
  step_ok "kubectl" "Configurado"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${G}${B}✓ Cluster '${name}' disponível!${N}"
  echo ""
  echo -e "  Verificar:  ${C}kubectl get nodes${N}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ─── Helper: configurar Container Registry no cluster ────────────────────────
setup_registry() {
  info "Buscando Container Registries disponíveis"
  local reg_json
  reg_json=$(mgcj mgc container-registry registries list 2>/dev/null) || { warn "Falha ao listar registries."; return; }

  local registries
  registries=$(echo "$reg_json" | python3 -c "
import json,sys
results = json.load(sys.stdin).get('results', [])
for r in results:
    print(r['id'] + '|' + r['name'])
" 2>/dev/null || echo "")

  local reg_id="" reg_name=""

  if [[ -n "$registries" ]]; then
    echo ""
    local i=1
    while IFS='|' read -r rid rname; do
      echo -e "  [${i}] ${rname}"
      i=$((i+1))
    done <<< "$registries"
    echo -e "  [${i}] Criar novo registry"
    echo -e "  [0] Pular"
    echo ""
    read -rp "  Escolha: " _choice

    if [[ "$_choice" == "0" ]]; then
      warn "Registry não configurado. Para configurar depois: ./k3s.sh kubernetes cluster configure-registry --cluster-id ID"
      return
    fi

    local count; count=$(echo "$registries" | wc -l | tr -d ' ')
    if [[ "$_choice" -le "$count" ]] 2>/dev/null; then
      local line; line=$(echo "$registries" | sed -n "${_choice}p")
      reg_id="${line%%|*}"
      reg_name="${line##*|}"
    else
      read -rp "  Nome do novo registry: " reg_name
      [[ -n "$reg_name" ]] || { warn "Nome inválido. Pulando."; return; }
      info "Criando registry '${reg_name}'"
      mgcj mgc container-registry registries create --name="$reg_name" >/dev/null \
        || { warn "Falha ao criar registry."; return; }
      ok "Registry '${reg_name}' criado"
    fi
  else
    echo ""
    echo -e "  Nenhum Container Registry encontrado."
    echo -e "  [1] Criar novo registry"
    echo -e "  [0] Pular"
    echo ""
    read -rp "  Escolha: " _choice
    if [[ "$_choice" != "1" ]]; then
      warn "Registry não configurado. Para configurar depois: ./k3s.sh kubernetes cluster configure-registry --cluster-id ID"
      return
    fi
    read -rp "  Nome do novo registry: " reg_name
    [[ -n "$reg_name" ]] || { warn "Nome inválido. Pulando."; return; }
    info "Criando registry '${reg_name}'"
    mgcj mgc container-registry registries create --name="$reg_name" >/dev/null \
      || { warn "Falha ao criar registry."; return; }
    ok "Registry '${reg_name}' criado"
  fi

  info "Obtendo credenciais do Container Registry"
  local creds
  creds=$(mgcj mgc container-registry credentials get 2>/dev/null) || { warn "Falha ao obter credenciais."; return; }
  local cr_user cr_pass
  cr_user=$(echo "$creds" | python3 -c "import json,sys; print(json.load(sys.stdin).get('username',''))" 2>/dev/null)
  cr_pass=$(echo "$creds" | python3 -c "import json,sys; print(json.load(sys.stdin).get('password',''))" 2>/dev/null)
  [[ -n "$cr_user" && -n "$cr_pass" ]] || { warn "Credenciais vazias."; return; }

  kubectl create secret docker-registry mgc-registry-secret \
    --docker-server="container-registry.br-se1.magalu.cloud" \
    --docker-username="$cr_user" \
    --docker-password="$cr_pass" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

  kubectl patch serviceaccount default \
    -p '{"imagePullSecrets": [{"name": "mgc-registry-secret"}]}' >/dev/null 2>&1

  ok "Registry '${reg_name:-container-registry}' configurado (mgc-registry-secret)"
}

# Vincula automaticamente o primeiro registry disponível, ou cria um novo
_ensure_registry() {
  step "Registry" "Verificando Container Registry"

  local reg_json
  reg_json=$(mgcj mgc container-registry registries list 2>/dev/null) || { warn "Falha ao listar registries."; return; }

  local reg_name
  reg_name=$(echo "$reg_json" | python3 -c "
import json,sys
results = json.load(sys.stdin).get('results', [])
print(results[0]['name'] if results else '')
" 2>/dev/null || echo "")

  if [[ -z "$reg_name" ]]; then
    reg_name="registry-k3s"
    step "Registry" "Criando registry '${reg_name}'"
    mgcj mgc container-registry registries create --name="$reg_name" >/dev/null \
      || { warn "Falha ao criar registry."; return; }
    step_ok "Registry" "Criado"
  else
    step_ok "Registry" "Usando '${reg_name}'"
  fi

  local creds
  creds=$(mgcj mgc container-registry credentials get 2>/dev/null) || { warn "Falha ao obter credenciais."; return; }
  local cr_user cr_pass
  cr_user=$(echo "$creds" | python3 -c "import json,sys; print(json.load(sys.stdin).get('username',''))" 2>/dev/null)
  cr_pass=$(echo "$creds" | python3 -c "import json,sys; print(json.load(sys.stdin).get('password',''))" 2>/dev/null)
  [[ -n "$cr_user" && -n "$cr_pass" ]] || { warn "Credenciais vazias."; return; }

  kubectl create secret docker-registry mgc-registry-secret \
    --docker-server="container-registry.br-se1.magalu.cloud" \
    --docker-username="$cr_user" \
    --docker-password="$cr_pass" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

  kubectl patch serviceaccount default \
    -p '{"imagePullSecrets": [{"name": "mgc-registry-secret"}]}' >/dev/null 2>&1

  step_ok "Registry" "Vinculado ao cluster (mgc-registry-secret)"
}

# ─── COMANDO: cluster configure-registry ─────────────────────────────────────
cmd_configure_registry() {
  local cluster_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster-id) cluster_id="$2"; shift 2 ;;
      --cluster-id=*) cluster_id="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done
  [[ -n "$cluster_id" ]] || die "Informe o ID do cluster: --cluster-id ID"
  cluster_by_id "$cluster_id" >/dev/null || die "Cluster '${cluster_id}' não encontrado."
  setup_registry
}

# ─── COMANDO: fix-traefik ────────────────────────────────────────────────────
# Aplica o fix de Traefik diretamente em um IP de VM acessível
_apply_traefik_fix() {
  local vm_ip="$1"

  step "Traefik" "Removendo HelmCharts do Traefik"
  vm_ssh "$vm_ip" \
    "sudo k3s kubectl delete helmchart traefik traefik-crd -n kube-system --ignore-not-found=true 2>/dev/null; true" \
    >/dev/null 2>&1 || true
  step_ok "Traefik" "HelmCharts removidos"

  step "K3s" "Atualizando config.yaml e reiniciando"
  vm_ssh "$vm_ip" \
    "printf 'node-external-ip: ${vm_ip}\ndisable:\n  - traefik\n' | sudo tee /etc/rancher/k3s/config.yaml >/dev/null && sudo systemctl restart k3s"
  sleep 5

  step "Cluster" "Aguardando nó ficar pronto"
  local traefik_node_status=""
  for i in $(seq 1 24); do
    traefik_node_status=$(vm_ssh "$vm_ip" "sudo k3s kubectl get nodes --no-headers 2>/dev/null | awk '{print \$2}'" 2>/dev/null || echo "")
    [[ "$traefik_node_status" == "Ready" ]] && break
    sleep 5
  done
  [[ "$traefik_node_status" == "Ready" ]] || die "K3s não ficou Ready após reinicialização."
  step_ok "Cluster" "Nó pronto"
  ok "Traefik desabilitado. A porta 80 está livre para seus workloads."
}


# ─── COMANDO: network ip-cleanup ─────────────────────────────────────────────
cmd_ip_cleanup() {
  hdr "IPs públicos órfãos"

  local list
  list=$(mgcj mgc network public-ips list 2>/dev/null) || die "Falha ao listar IPs públicos"

  local orphans
  orphans=$(echo "$list" | python3 -c "
import json,sys
ips = json.load(sys.stdin).get('public_ips', [])
orphans = [ip for ip in ips if ip.get('port_id') is None and ip.get('status') == 'created']
import json as j
print(j.dumps(orphans))
" 2>/dev/null || echo "[]")

  local count
  count=$(echo "$orphans" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

  if [[ "$count" -eq 0 ]]; then
    ok "Nenhum IP público órfão encontrado."
    return
  fi

  echo ""
  echo -e "${Y}${count} IP(s) público(s) sem VM associada:${N}"
  echo "$orphans" | python3 -c "
import json,sys
for ip in json.load(sys.stdin):
    print(f\"  {ip['public_ip']}  (id: {ip['id']})\")
"
  echo ""
  read -rp "  Deletar todos? [s/N] " confirm
  [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" == "s" ]] || { echo "Cancelado."; return; }

  echo "$orphans" | python3 -c "
import json,sys
for ip in json.load(sys.stdin):
    print(ip['id'])
" | while read -r ip_id; do
    mgcj mgc network public-ips delete --public-ip-id "$ip_id" --no-confirm >/dev/null 2>&1 \
      && ok "Deletado: ${ip_id}" \
      || warn "Não foi possível deletar ${ip_id}"
  done
}

# ─── DIAGNOSE helpers ────────────────────────────────────────────────────────
# printf '%-Ns' conta bytes, não chars — chars multibyte (ã, ç, ú…) têm 2 bytes
# mas ocupam 1 coluna, causando desalinhamento. _dpad compensa esse delta.
_dpad() {
  local label="$1" width="$2"
  local bytes char_len extra
  bytes=$(printf '%s' "$label" | wc -c | tr -d ' ')
  char_len=${#label}
  extra=$(( bytes - char_len ))
  printf "%-$(( width + extra ))s" "$label"
}
diag_section()         { echo ""; echo -e "  ${B}$1${N}"; }
diag_parent_ok()       { echo -e "  ${G}✓${N} ${B}$1${N}"; }
diag_parent_fail()     { echo -e "  ${R}✗${N} ${B}$1${N}"; }
diag_parent_skip()     { echo -e "  ${D}—${N} ${B}$1${N}"; }
diag_sub_ok()          { echo -e "    ${G}✓${N} $(_dpad "$1" 22) $2"; }
diag_sub_fail()        { echo -e "    ${R}✗${N} $(_dpad "$1" 22) $2"; }
diag_sub_skip()        { echo -e "    ${D}—${N} $(_dpad "$1" 22) ${D}não testado${N}"; }
diag_sub_parent_ok()   { echo -e "    ${G}✓${N} ${B}$1${N}"; }
diag_sub_parent_fail() { echo -e "    ${R}✗${N} ${B}$1${N}"; }
diag_sub_parent_skip() { echo -e "    ${D}—${N} ${B}$1${N}"; }
diag_subsub_ok()       { echo -e "      ${G}✓${N} $(_dpad "$1" 20) $2"; }
diag_subsub_fail()     { echo -e "      ${R}✗${N} $(_dpad "$1" 20) $2"; }
diag_subsub_skip()     { echo -e "      ${D}—${N} $(_dpad "$1" 20) ${D}não testado${N}"; }

# Retorna: open | restricted:CIDR,... | no-rule
_sg_port_status() {
  printf '%s\n' "$1" | python3 -c "
import json, sys
port = $2
data = json.load(sys.stdin)
rules = data.get('security_group_rules', data.get('rules', []))
port_rules = [r for r in rules if
    r.get('direction') == 'ingress' and
    str(r.get('protocol','')) == 'tcp' and
    r.get('port_range_min') is not None and
    int(r.get('port_range_min',-1)) <= port <= int(r.get('port_range_max', port))]
if not port_rules:
    print('no-rule'); sys.exit()
for r in port_rules:
    prefix = r.get('remote_ip_prefix','') or ''
    if prefix in ('0.0.0.0/0', '::/0', ''):
        print('open'); sys.exit()
prefixes = list(set(r.get('remote_ip_prefix','') for r in port_rules if r.get('remote_ip_prefix')))
print('restricted:' + ','.join(prefixes))
" 2>/dev/null || echo "no-rule"
}

# Retorna: yes | no
_ip_in_cidrs() {
  python3 -c "
import ipaddress
try:
    ip = ipaddress.ip_address('$1')
    cidrs = '$2'.split(',')
    print('yes' if any(ip in ipaddress.ip_network(c.strip(), strict=False) for c in cidrs if c.strip()) else 'no')
except:
    print('no')
" 2>/dev/null || echo "no"
}

_diagnose_cluster() {
  local vm_id="$1"
  local cluster
  cluster=$(cluster_by_id "$vm_id") || { warn "Cluster '${vm_id}' não encontrado."; return; }

  local name vm_ip
  name=$(echo "$cluster"  | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
  vm_ip=$(echo "$cluster" | python3 -c "import json,sys; print(json.load(sys.stdin)['ip'])")

  hdr "Diagnóstico do cluster '${name}'"

  # Coleta prévia: SG rules + IP público local (para validação de regras restritas)
  local sg_id sg_rules_json="" local_ip=""
  sg_id=$(get_sg_id)
  if [[ -n "$sg_id" ]]; then
    sg_rules_json=$(mgcj mgc network security-groups rules list --security-group-id="$sg_id" 2>/dev/null) || sg_rules_json=""
  fi
  if [[ -n "$sg_rules_json" ]]; then
    local_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
  fi

  # ═══════════════════════════════════════════════════════════════════════════
  diag_section "Recursos"

  # ── Virtual Machine ───────────────────────────────────────────────────────
  local vm_json vm_state="desconhecido"
  vm_json=$(mgcj mgc virtual-machine instances get "$vm_id" 2>/dev/null) || vm_json=""
  if [[ -n "$vm_json" ]]; then
    vm_state=$(echo "$vm_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('state','desconhecido'))" 2>/dev/null || echo "desconhecido")
  fi

  local vm_estado_ok=0 vm_ip_ok=0
  [[ "$vm_state" == "running" ]] && vm_estado_ok=1
  [[ -n "$vm_ip" && "$vm_ip" != "—" ]] && vm_ip_ok=1

  if [[ "$vm_estado_ok" -eq 1 && "$vm_ip_ok" -eq 1 ]]; then diag_parent_ok "Virtual Machine"
  else diag_parent_fail "Virtual Machine"; fi

  if [[ "$vm_estado_ok" -eq 1 ]]; then diag_sub_ok "Estado" "ligada"
  else diag_sub_fail "Estado" "${vm_state}"; fi

  if [[ "$vm_ip_ok" -eq 1 ]]; then diag_sub_ok "IP Público" "${vm_ip}"
  else diag_sub_fail "IP Público" "não atribuído — rode: fix --cluster-id ${vm_id}"; fi

  # ── Container Registry (MGC) ──────────────────────────────────────────────
  local cr_json="" cr_name="" cr_registry_ok=0 cr_cred_ok=0
  cr_json=$(mgcj mgc container-registry registries list 2>/dev/null) || cr_json=""
  if [[ -n "$cr_json" ]]; then
    cr_name=$(echo "$cr_json" | python3 -c "
import json,sys
results = json.load(sys.stdin).get('results', [])
print(results[0]['name'] if results else '')
" 2>/dev/null || echo "")
  fi
  [[ -n "$cr_name" ]] && cr_registry_ok=1

  if [[ "$cr_registry_ok" -eq 1 ]]; then
    local creds_json="" cr_user=""
    creds_json=$(mgcj mgc container-registry credentials get 2>/dev/null) || creds_json=""
    if [[ -n "$creds_json" ]]; then
      cr_user=$(echo "$creds_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('username',''))" 2>/dev/null || echo "")
    fi
    [[ -n "$cr_user" ]] && cr_cred_ok=1
  fi

  if [[ "$cr_registry_ok" -eq 1 && "$cr_cred_ok" -eq 1 ]]; then diag_parent_ok "Container Registry"
  else diag_parent_fail "Container Registry"; fi

  if [[ "$cr_registry_ok" -eq 1 ]]; then diag_sub_ok "Registry" "${cr_name}"
  else diag_sub_fail "Registry" "nenhum registry encontrado — rode: fix --cluster-id ${vm_id}"; fi

  if [[ "$cr_registry_ok" -eq 1 ]]; then
    if [[ "$cr_cred_ok" -eq 1 ]]; then diag_sub_ok "Credencial" "acessível"
    else diag_sub_fail "Credencial" "falha ao obter credenciais"; fi
  else
    diag_sub_skip "Credencial"
  fi

  # ═══════════════════════════════════════════════════════════════════════════
  diag_section "Conectividade"

  # ── SSH ───────────────────────────────────────────────────────────────────
  local ssh_key_status ssh_key_ok=0
  ssh_key_status=$(_check_ssh_key_status)
  [[ "$ssh_key_status" == "ok" ]] && ssh_key_ok=1

  local sg_22="" ssh_sg_ok=0 ssh_sg_disp=""
  if [[ -n "$sg_rules_json" ]]; then
    sg_22=$(_sg_port_status "$sg_rules_json" 22)
    if [[ "$sg_22" == "open" ]]; then
      ssh_sg_ok=1; ssh_sg_disp="porta 22 aberta"
    elif [[ "$sg_22" == "no-rule" ]]; then
      ssh_sg_disp="sem regra para porta 22"
    else
      local cidrs_22="${sg_22#restricted:}"
      if [[ -n "$local_ip" ]] && [[ "$(_ip_in_cidrs "$local_ip" "$cidrs_22")" == "yes" ]]; then
        ssh_sg_ok=1; ssh_sg_disp="restrita — IP local autorizado"
      else
        ssh_sg_disp="IP ${local_ip:-desconhecido} não autorizado (${cidrs_22})"
      fi
    fi
  fi

  local ssh_port_ok=0 ssh_conn_ok=0
  if [[ "$vm_ip_ok" -eq 1 ]]; then
    if bash -c "(echo >/dev/tcp/${vm_ip}/22) >/dev/null 2>&1"; then ssh_port_ok=1; fi
  fi
  if [[ "$ssh_port_ok" -eq 1 && "$ssh_key_ok" -eq 1 ]]; then
    if ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
         -o BatchMode=yes "${VM_USER}@${vm_ip}" "exit 0" 2>/dev/null; then
      ssh_conn_ok=1
    fi
  fi

  local ssh_all_ok=0
  if [[ "$ssh_key_ok" -eq 1 && "$ssh_sg_ok" -eq 1 && "$ssh_conn_ok" -eq 1 ]]; then ssh_all_ok=1; fi
  if [[ "$ssh_all_ok" -eq 1 ]]; then diag_parent_ok "SSH"
  else diag_parent_fail "SSH"; fi

  case "$ssh_key_status" in
    ok)            diag_sub_ok   "Chave" "sincronizada" ;;
    diverge)       diag_sub_fail "Chave" "diverge do MGC — rode: fix --cluster-id ${vm_id}" ;;
    local-missing) diag_sub_fail "Chave" "ausente localmente — rode: fix --cluster-id ${vm_id}" ;;
    mgc-missing)   diag_sub_fail "Chave" "não cadastrada no MGC — rode: fix --cluster-id ${vm_id}" ;;
    both-missing)  diag_sub_fail "Chave" "ausente local e no MGC — rode: fix --cluster-id ${vm_id}" ;;
  esac

  if [[ -z "$sg_rules_json" ]]; then diag_sub_skip "Grupo de Segurança"
  elif [[ "$ssh_sg_ok" -eq 1 ]]; then diag_sub_ok "Grupo de Segurança" "$ssh_sg_disp"
  else diag_sub_fail "Grupo de Segurança" "$ssh_sg_disp"; fi

  if [[ "$vm_ip_ok" -eq 1 && "$ssh_key_ok" -eq 1 ]]; then
    if [[ "$ssh_conn_ok" -eq 1 ]]; then diag_sub_ok "Conexão" "autenticada"
    else diag_sub_fail "Conexão" "falhou — rode: fix --cluster-id ${vm_id}"; fi
  else
    diag_sub_skip "Conexão"
  fi

  # ── kubectl ───────────────────────────────────────────────────────────────
  local kc_file_ok=0
  if [[ -f "${HOME}/.kube/config" ]] && grep -q "$vm_ip" "${HOME}/.kube/config" 2>/dev/null; then
    kc_file_ok=1
  fi

  local sg_6443="" kc_sg_ok=0 kc_sg_disp=""
  if [[ -n "$sg_rules_json" ]]; then
    sg_6443=$(_sg_port_status "$sg_rules_json" 6443)
    if [[ "$sg_6443" == "open" ]]; then
      kc_sg_ok=1; kc_sg_disp="porta 6443 aberta"
    elif [[ "$sg_6443" == "no-rule" ]]; then
      kc_sg_disp="sem regra para porta 6443"
    else
      local cidrs_6443="${sg_6443#restricted:}"
      if [[ -n "$local_ip" ]] && [[ "$(_ip_in_cidrs "$local_ip" "$cidrs_6443")" == "yes" ]]; then
        kc_sg_ok=1; kc_sg_disp="restrita — IP local autorizado"
      else
        kc_sg_disp="IP ${local_ip:-desconhecido} não autorizado (${cidrs_6443})"
      fi
    fi
  fi

  local kc_conn_ok=0
  if kubectl get nodes --no-headers 2>/dev/null | grep -q "Ready"; then kc_conn_ok=1; fi

  local kc_all_ok=0
  if [[ "$kc_file_ok" -eq 1 && "$kc_sg_ok" -eq 1 && "$kc_conn_ok" -eq 1 ]]; then kc_all_ok=1; fi
  if [[ "$kc_all_ok" -eq 1 ]]; then diag_parent_ok "kubectl"
  else diag_parent_fail "kubectl"; fi

  if [[ "$kc_file_ok" -eq 1 ]]; then diag_sub_ok "Kubeconfig" "configurado"
  else diag_sub_fail "Kubeconfig" "não configurado — rode: fix --cluster-id ${vm_id}"; fi

  if [[ -z "$sg_rules_json" ]]; then diag_sub_skip "Grupo de Segurança"
  elif [[ "$kc_sg_ok" -eq 1 ]]; then diag_sub_ok "Grupo de Segurança" "$kc_sg_disp"
  else diag_sub_fail "Grupo de Segurança" "$kc_sg_disp"; fi

  if [[ "$kc_conn_ok" -eq 1 ]]; then diag_sub_ok "Conexão" "API Server respondendo"
  else diag_sub_fail "Conexão" "não responde — rode: fix --cluster-id ${vm_id}"; fi

  # ═══════════════════════════════════════════════════════════════════════════
  diag_section "Kubernetes"

  local k3s_node_ok=0 k3s_traefik_ok=0 k3s_secret_ok=0 k3s_sa_ok=0 k3s_node_status=""

  if [[ "$ssh_conn_ok" -eq 1 ]]; then
    k3s_node_status=$(vm_ssh "$vm_ip" "sudo k3s kubectl get nodes --no-headers 2>/dev/null | awk '{print \$2}'" 2>/dev/null || echo "")
    [[ "$k3s_node_status" == "Ready" ]] && k3s_node_ok=1

    local traefik_disabled
    traefik_disabled=$(vm_ssh "$vm_ip" \
      "grep -q 'traefik' /etc/rancher/k3s/config.yaml 2>/dev/null && echo yes || echo no" 2>/dev/null || echo "no")
    [[ "$traefik_disabled" == "yes" ]] && k3s_traefik_ok=1
  fi

  if [[ "$kc_conn_ok" -eq 1 ]]; then
    local secret_name
    secret_name=$(kubectl get secret mgc-registry-secret --no-headers 2>/dev/null | awk '{print $1}')
    [[ "$secret_name" == "mgc-registry-secret" ]] && k3s_secret_ok=1

    local sa_pull
    sa_pull=$(kubectl get sa default -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null || echo "")
    [[ "$sa_pull" == *"mgc-registry-secret"* ]] && k3s_sa_ok=1
  fi

  local k3s_cr_ok=0
  if [[ "$k3s_secret_ok" -eq 1 && "$k3s_sa_ok" -eq 1 ]]; then k3s_cr_ok=1; fi

  local k3s_all_ok=0
  if [[ "$k3s_node_ok" -eq 1 && "$k3s_traefik_ok" -eq 1 && "$k3s_cr_ok" -eq 1 ]]; then k3s_all_ok=1; fi
  if [[ "$k3s_all_ok" -eq 1 ]]; then diag_parent_ok "Cluster K3s"
  else diag_parent_fail "Cluster K3s"; fi

  if [[ "$ssh_conn_ok" -eq 1 ]]; then
    if [[ "$k3s_node_ok" -eq 1 ]]; then diag_sub_ok "Node" "Ready"
    else diag_sub_fail "Node" "${k3s_node_status:-sem resposta} — rode: start --cluster-id ${vm_id}"; fi

    if [[ "$k3s_traefik_ok" -eq 1 ]]; then diag_sub_ok "Traefik" "desabilitado"
    else diag_sub_fail "Traefik" "não desabilitado — rode: fix --cluster-id ${vm_id}"; fi
  else
    diag_sub_skip "Node"
    diag_sub_skip "Traefik"
  fi

  if [[ "$kc_conn_ok" -eq 1 ]]; then
    if [[ "$k3s_cr_ok" -eq 1 ]]; then diag_sub_parent_ok "Container Registry"
    else diag_sub_parent_fail "Container Registry"; fi

    if [[ "$k3s_secret_ok" -eq 1 ]]; then diag_subsub_ok "Secret" "mgc-registry-secret presente"
    else diag_subsub_fail "Secret" "não encontrado — rode: fix --cluster-id ${vm_id}"; fi

    if [[ "$k3s_sa_ok" -eq 1 ]]; then diag_subsub_ok "Service Account" "imagePullSecrets configurado"
    else diag_subsub_fail "Service Account" "não configurado — rode: fix --cluster-id ${vm_id}"; fi
  else
    diag_sub_skip "Container Registry"
  fi

  echo ""
}

# ─── COMANDO: diagnose ────────────────────────────────────────────────────────
cmd_diagnose() {
  local cluster_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster-id)   cluster_id="$2"; shift 2 ;;
      --cluster-id=*) cluster_id="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done

  if [[ -n "$cluster_id" ]]; then
    cluster_by_id "$cluster_id" >/dev/null || die "Cluster '${cluster_id}' não encontrado. Liste com: ./k3s.sh kubernetes cluster list"
    _diagnose_cluster "$cluster_id"
  else
    local clusters
    clusters=$(list_clusters)
    if [[ -z "$clusters" ]]; then
      echo "Nenhum cluster encontrado."
      return
    fi
    while IFS='|' read -r vm_id name ip; do
      [[ -z "$vm_id" ]] && continue
      _diagnose_cluster "$vm_id"
    done <<< "$clusters"
  fi
}

# ─── FIX helpers ─────────────────────────────────────────────────────────────

# Garante regra de ingresso aberta (IPv4 + IPv6) para um port no Security Group
_fix_sg_port() {
  local sg_id="$1" port="$2"
  local rules_json
  rules_json=$(mgcj mgc network security-groups rules list --security-group-id="$sg_id" 2>/dev/null) || rules_json=""

  local has_ipv4 has_ipv6
  has_ipv4=$(printf '%s\n' "$rules_json" | python3 -c "
import json, sys
port = $port
data = json.load(sys.stdin)
rules = data.get('security_group_rules', data.get('rules', []))
found = any(
    r.get('direction') == 'ingress' and str(r.get('protocol','')) == 'tcp'
    and int(r.get('port_range_min',-1)) <= port <= int(r.get('port_range_max', port))
    and r.get('ethertype','') == 'IPv4'
    and r.get('remote_ip_prefix','') in ('0.0.0.0/0','')
    for r in rules)
print('yes' if found else 'no')
" 2>/dev/null || echo "no")

  has_ipv6=$(printf '%s\n' "$rules_json" | python3 -c "
import json, sys
port = $port
data = json.load(sys.stdin)
rules = data.get('security_group_rules', data.get('rules', []))
found = any(
    r.get('direction') == 'ingress' and str(r.get('protocol','')) == 'tcp'
    and int(r.get('port_range_min',-1)) <= port <= int(r.get('port_range_max', port))
    and r.get('ethertype','') == 'IPv6'
    and r.get('remote_ip_prefix','') in ('::/0','')
    for r in rules)
print('yes' if found else 'no')
" 2>/dev/null || echo "no")

  if [[ "$has_ipv4" == "yes" && "$has_ipv6" == "yes" ]]; then return 0; fi

  step "Security Group" "Liberando porta ${port}"
  if [[ "$has_ipv4" != "yes" ]]; then
    mgcj mgc network security-groups rules create \
      --security-group-id="$sg_id" --direction="ingress" --ethertype="IPv4" \
      --protocol="tcp" --port-range-min="$port" --port-range-max="$port" \
      --remote-ip-prefix="0.0.0.0/0" --wait >/dev/null
  fi
  if [[ "$has_ipv6" != "yes" ]]; then
    mgcj mgc network security-groups rules create \
      --security-group-id="$sg_id" --direction="ingress" --ethertype="IPv6" \
      --protocol="tcp" --port-range-min="$port" --port-range-max="$port" \
      --remote-ip-prefix="::/0" --wait >/dev/null
  fi
  step_ok "Security Group" "Porta ${port} liberada"
}

# Resolve par de chaves SSH sem sobrescrever chave local existente
_fix_ssh_key() {
  local ssh_key_status
  ssh_key_status=$(_check_ssh_key_status)

  case "$ssh_key_status" in
    ok) return 0 ;;
    diverge)
      step "Chave SSH" "Atualizando registro no MGC"
      local mgc_raw mgc_id
      mgc_raw=$(mgcj mgc profile ssh-keys list | python3 -c "
import json, sys
keys = json.load(sys.stdin).get('results', [])
match = [k for k in keys if k.get('name') == '${SSH_KEY_NAME}']
print(json.dumps(match[0]) if match else '')
" 2>/dev/null || echo "")
      mgc_id=$(echo "$mgc_raw" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
      [[ -n "$mgc_id" ]] && mgcj mgc profile ssh-keys delete --key-id="$mgc_id" --no-confirm >/dev/null 2>&1 || true
      mgcj mgc profile ssh-keys create \
        --name="${SSH_KEY_NAME}" \
        --key="$(cat "${SSH_KEY_PATH}.pub")" >/dev/null \
        || die "Falha ao recadastrar chave SSH na Magalu Cloud"
      step_ok "Chave SSH" "Sincronizada com MGC"
      ;;
    local-missing|both-missing)
      step "Chave SSH" "Gerando novo par SSH"
      local mgc_raw mgc_id
      mgc_raw=$(mgcj mgc profile ssh-keys list | python3 -c "
import json, sys
keys = json.load(sys.stdin).get('results', [])
match = [k for k in keys if k.get('name') == '${SSH_KEY_NAME}']
print(json.dumps(match[0]) if match else '')
" 2>/dev/null || echo "")
      mgc_id=$(echo "$mgc_raw" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
      [[ -n "$mgc_id" ]] && mgcj mgc profile ssh-keys delete --key-id="$mgc_id" --no-confirm >/dev/null 2>&1 || true
      _gen_ssh_key
      mgcj mgc profile ssh-keys create \
        --name="${SSH_KEY_NAME}" \
        --key="$(cat "${SSH_KEY_PATH}.pub")" >/dev/null \
        || die "Falha ao cadastrar nova chave SSH na Magalu Cloud"
      step_ok "Chave SSH" "Novo par gerado e registrado"
      ;;
    mgc-missing)
      step "Chave SSH" "Cadastrando chave local no MGC"
      mgcj mgc profile ssh-keys create \
        --name="${SSH_KEY_NAME}" \
        --key="$(cat "${SSH_KEY_PATH}.pub")" >/dev/null \
        || die "Falha ao cadastrar chave SSH na Magalu Cloud"
      step_ok "Chave SSH" "Cadastrada no MGC"
      ;;
  esac
}

# Recupera acesso SSH a um cluster preservando o IP público
_fix_cluster() {
  local vm_id="$1"

  local cluster
  cluster=$(cluster_by_id "$vm_id") || die "Cluster '${vm_id}' não encontrado."
  local name vm_ip
  name=$(echo "$cluster"  | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
  vm_ip=$(echo "$cluster" | python3 -c "import json,sys; print(json.load(sys.stdin)['ip'])")

  hdr "Corrigindo cluster '${name}'"

  local active_ip="$vm_ip"
  local ssh_accessible=0

  # ════════════════════════════════════════════════════════════════
  # RECURSOS
  # ════════════════════════════════════════════════════════════════
  diag_section "Recursos"

  # ── Virtual Machine ───────────────────────────────────────────
  local vm_json vm_state
  vm_json=$(mgcj mgc virtual-machine instances get "$vm_id" 2>/dev/null) || die "Falha ao obter dados da VM"
  vm_state=$(echo "$vm_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('state',''))" 2>/dev/null || echo "")

  if [[ "$vm_state" == "running" ]]; then
    diag_parent_ok "Virtual Machine"
    diag_sub_ok "Estado" "ligada"
  elif [[ "$vm_state" == "stopped" ]]; then
    diag_parent_fail "Virtual Machine"
    diag_sub_fail "Estado" "desligada — ligando..."
    mgcj mgc virtual-machine instances start "$vm_id" >/dev/null || die "Falha ao ligar VM"
    for _i in $(seq 1 60); do
      vm_state=$(mgcj mgc virtual-machine instances get "$vm_id" | \
        python3 -c "import json,sys; print(json.load(sys.stdin).get('state',''))" 2>/dev/null || echo "")
      [[ "$vm_state" == "running" ]] && break
      sleep 5
    done
    [[ "$vm_state" == "running" ]] || die "VM não ficou running após 300s"
    diag_sub_ok "Estado" "ligada"
    # Aguarda IP aparecer na API após start
    for _i in $(seq 1 12); do
      vm_ip=$(mgcj mgc virtual-machine instances get "$vm_id" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ifaces=d.get('network',{}).get('interfaces',[])
print(ifaces[0].get('associated_public_ipv4','') if ifaces else '')
" 2>/dev/null || echo "")
      [[ -n "$vm_ip" && "$vm_ip" != "—" ]] && break
      sleep 5
    done
    active_ip="$vm_ip"
  else
    diag_parent_fail "Virtual Machine"
    diag_sub_fail "Estado" "${vm_state} — não foi possível recuperar automaticamente"
  fi

  # ── IP Público ────────────────────────────────────────────────
  # Leitura única se VM já estava running
  if [[ -z "$vm_ip" || "$vm_ip" == "—" ]]; then
    vm_ip=$(mgcj mgc virtual-machine instances get "$vm_id" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ifaces=d.get('network',{}).get('interfaces',[])
print(ifaces[0].get('associated_public_ipv4','') if ifaces else '')
" 2>/dev/null || echo "")
    active_ip="$vm_ip"
  fi

  if [[ -n "$vm_ip" && "$vm_ip" != "—" ]]; then
    diag_sub_ok "IP Público" "$vm_ip"
  else
    diag_sub_fail "IP Público" "ausente"
    local port_id
    port_id=$(echo "$vm_json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ifaces=d.get('network',{}).get('interfaces',[])
print(ifaces[0].get('id','') if ifaces else '')
" 2>/dev/null || echo "")
    [[ -n "$port_id" ]] || die "Port ID da VM não encontrado — não foi possível associar IP"

    echo ""
    echo "  Selecione um IP público para associar ao cluster:"
    echo ""

    local free_ips_json
    free_ips_json=$(mgcj mgc network public-ips list 2>/dev/null | python3 -c "
import json,sys
ips=json.load(sys.stdin).get('public_ips',[])
free=[ip for ip in ips if not ip.get('port_id')]
print(json.dumps(free))
" 2>/dev/null || echo "[]")

    local free_count
    free_count=$(echo "$free_ips_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

    local _idx=1
    while IFS= read -r _addr; do
      printf "    [%s] %s\n" "$_idx" "$_addr"
      _idx=$((_idx+1))
    done < <(echo "$free_ips_json" | python3 -c "
import json,sys
for ip in json.load(sys.stdin):
    print(ip.get('public_ip', ip.get('id','?')))")

    local next_opt=$((free_count+1))
    printf "    [%s] Criar novo IP público\n" "$next_opt"
    printf "    [0] Pular (cluster ficará sem IP)\n"
    echo ""

    local chosen_ip_id=""
    while [[ -z "$chosen_ip_id" ]]; do
      read -rp "  Escolha: " _ip_opt
      if [[ "$_ip_opt" == "0" ]]; then
        warn "IP público não configurado — o cluster ficará inacessível"
        break
      elif [[ "$_ip_opt" == "$next_opt" ]]; then
        local new_ip_json
        new_ip_json=$(mgcj mgc network public-ips create 2>/dev/null) \
          || die "Falha ao criar IP público — cota atingida? Rode: ./k3s.sh network ip-cleanup"
        chosen_ip_id=$(echo "$new_ip_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
        [[ -n "$chosen_ip_id" ]] || die "Não foi possível obter o ID do novo IP público"
      elif [[ "$_ip_opt" =~ ^[0-9]+$ ]] && [[ "$_ip_opt" -ge 1 ]] && [[ "$_ip_opt" -le "$free_count" ]]; then
        chosen_ip_id=$(echo "$free_ips_json" | python3 -c "
import json,sys
ips=json.load(sys.stdin)
print(ips[$((${_ip_opt}-1))].get('id',''))
" 2>/dev/null || echo "")
        [[ -n "$chosen_ip_id" ]] || { echo "  Opção inválida."; chosen_ip_id=""; continue; }
      else
        echo "  Opção inválida."
      fi
    done

    if [[ -n "$chosen_ip_id" ]]; then
      mgcj mgc network public-ips attach \
        --public-ip-id="$chosen_ip_id" --port-id="$port_id" >/dev/null \
        || die "Falha ao associar IP público à VM"
      for _i in $(seq 1 20); do
        vm_ip=$(mgcj mgc virtual-machine instances get "$vm_id" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ifaces=d.get('network',{}).get('interfaces',[])
print(ifaces[0].get('associated_public_ipv4','') if ifaces else '')
" 2>/dev/null || echo "")
        [[ -n "$vm_ip" ]] && break
        sleep 5
      done
      [[ -n "$vm_ip" ]] || die "IP associado mas não apareceu na VM — verifique no console da MGC"
      active_ip="$vm_ip"
      diag_sub_ok "IP Público" "$vm_ip"
    fi
  fi

  # ════════════════════════════════════════════════════════════════
  # CONECTIVIDADE
  # ════════════════════════════════════════════════════════════════
  diag_section "Conectividade"

  # ── SSH ───────────────────────────────────────────────────────
  diag_sub_parent_ok "SSH"

  # Chave SSH
  local ssh_key_status
  ssh_key_status=$(_check_ssh_key_status)
  if [[ "$ssh_key_status" == "ok" ]]; then
    diag_subsub_ok "Chave" "sincronizada"
  else
    diag_subsub_fail "Chave" "$ssh_key_status"
    _fix_ssh_key
    diag_subsub_ok "Chave" "sincronizada"
  fi

  # Security Group porta 22
  local sg_id
  sg_id=$(get_sg_id)
  if [[ -n "$sg_id" ]]; then
    local rules_json_22
    rules_json_22=$(mgcj mgc network security-groups rules list --security-group-id="$sg_id" 2>/dev/null) || rules_json_22=""
    local sg22_status
    sg22_status=$(_sg_port_status "$rules_json_22" 22)
    if [[ "$sg22_status" == "open" ]]; then
      diag_subsub_ok "Grupo de Segurança" "porta 22 aberta"
    else
      diag_subsub_fail "Grupo de Segurança" "porta 22 ${sg22_status}"
      _fix_sg_port "$sg_id" 22
      diag_subsub_ok "Grupo de Segurança" "porta 22 aberta"
    fi
  else
    diag_subsub_fail "Grupo de Segurança" "SG '${SG_NAME}' não encontrado"
  fi

  # Conexão SSH (porta TCP + autenticação)
  if [[ -f "${SSH_KEY_PATH}" ]] && [[ -n "$active_ip" ]] && [[ "$active_ip" != "—" ]]; then
    local port_open=0
    for _i in $(seq 1 18); do
      if nc -z -w 3 "$active_ip" 22 2>/dev/null; then
        port_open=1; break
      fi
      sleep 5
    done
    if [[ "$port_open" -eq 1 ]]; then
      for _i in $(seq 1 6); do
        if ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
             -o BatchMode=yes "${VM_USER}@${active_ip}" "exit 0" 2>/dev/null; then
          ssh_accessible=1; break
        fi
        [[ "$_i" -lt 6 ]] && sleep 5
      done
    fi
    if [[ "$ssh_accessible" -eq 1 ]]; then
      diag_subsub_ok "Conexão" "autenticada"
    else
      diag_subsub_fail "Conexão" "inacessível — iniciando recuperação via snapshot"
    fi
  else
    diag_subsub_skip "Conexão"
  fi

  # ── Recuperação via snapshot (se SSH inacessível) ─────────────
  if [[ "$ssh_accessible" -eq 0 ]] && [[ -n "$active_ip" && "$active_ip" != "—" ]]; then
    local vm_name old_port_id old_public_ip_id
    vm_name=$(echo "$vm_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))" 2>/dev/null)
    old_port_id=$(echo "$vm_json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ifaces=d.get('network',{}).get('interfaces',[])
print(ifaces[0].get('id','') if ifaces else '')
" 2>/dev/null || echo "")
    old_public_ip_id=$(mgcj mgc network public-ips list | python3 -c "
import json,sys
ips=json.load(sys.stdin).get('public_ips',[])
match=[ip for ip in ips if ip.get('port_id')=='${old_port_id}']
print(match[0]['id'] if match else '')
" 2>/dev/null || echo "")

    [[ -n "$old_port_id" ]]      || die "Não foi possível obter o port ID da VM"
    [[ -n "$old_public_ip_id" ]] || die "Não foi possível encontrar o IP público associado à VM"

    local snap_name="fix-${name}"
    step "Snapshot" "Criando snapshot da VM atual"
    local snap_json snap_id
    snap_json=$(mgcj mgc virtual-machine snapshots create \
      --instance.id="$vm_id" \
      --name="$snap_name") || die "Falha ao criar snapshot"
    snap_id=$(echo "$snap_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
    [[ -n "$snap_id" ]] || die "Não foi possível obter o ID do snapshot"

    step "Snapshot" "Aguardando snapshot ficar disponível"
    local snap_state=""
    for _i in $(seq 1 60); do
      snap_state=$(mgcj mgc virtual-machine snapshots get --id="$snap_id" | \
        python3 -c "import json,sys; print(json.load(sys.stdin).get('state',''))" 2>/dev/null || echo "")
      [[ "$snap_state" == "available" ]] && break
      [[ "$snap_state" == "error" ]]     && die "Snapshot entrou em estado de erro"
      sleep 10
    done
    [[ "$snap_state" == "available" ]] || die "Timeout aguardando snapshot (600s)"
    step_ok "Snapshot" "Disponível (${snap_id})"

    step "VM atual" "Parando"
    mgcj mgc virtual-machine instances stop "$vm_id" >/dev/null || warn "Falha ao parar VM"
    sleep 5
    step_ok "VM atual" "Parada"

    step "IP público" "Desacoplando"
    mgcj mgc network public-ips detach \
      --public-ip-id="$old_public_ip_id" --port-id="$old_port_id" >/dev/null \
      || die "Falha ao desacoplar IP público"
    step_ok "IP público" "Desacoplado"

    local vpc_id
    vpc_id=$(mgcj mgc network vpcs list | python3 -c "
import json,sys
vpcs=[v for v in json.load(sys.stdin).get('vpcs',[]) if v.get('name')=='vpc_default']
print(vpcs[0]['id'] if vpcs else '')
" 2>/dev/null || echo "")
    [[ -n "$vpc_id" ]] || die "vpc_default não encontrada"
    [[ -n "$sg_id"  ]] || sg_id=$(get_sg_id)
    [[ -n "$sg_id"  ]] || die "Security Group '${SG_NAME}' não encontrado"

    step "Nova VM" "Restaurando com nova chave SSH"
    local new_vm_json new_vm_id
    new_vm_json=$(mgcj mgc virtual-machine snapshots restore \
      --id="$snap_id" \
      --name="$vm_name" \
      --machine-type.name="${MACHINE_TYPE}" \
      --ssh-key-name="${SSH_KEY_NAME}" \
      --network.vpc.id="$vpc_id" \
      --network.interface.security-groups="[{\"id\":\"${sg_id}\"}]") \
      || die "Falha ao restaurar snapshot"
    new_vm_id=$(echo "$new_vm_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
    [[ -n "$new_vm_id" ]] || die "Não foi possível obter o ID da nova VM"

    step "Nova VM" "Aguardando inicializar"
    local new_vm_state=""
    for _i in $(seq 1 60); do
      new_vm_state=$(mgcj mgc virtual-machine instances get "$new_vm_id" | \
        python3 -c "import json,sys; print(json.load(sys.stdin).get('state',''))" 2>/dev/null || echo "")
      [[ "$new_vm_state" == "running" ]] && break
      sleep 10
    done
    [[ "$new_vm_state" == "running" ]] || die "Timeout aguardando nova VM (600s)"
    step_ok "Nova VM" "Rodando (${new_vm_id})"

    local new_port_id
    new_port_id=$(mgcj mgc virtual-machine instances get "$new_vm_id" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ifaces=d.get('network',{}).get('interfaces',[])
print(ifaces[0].get('id','') if ifaces else '')
" 2>/dev/null || echo "")
    [[ -n "$new_port_id" ]] || die "Não foi possível obter o port ID da nova VM"

    step "IP público" "Acoplando na nova VM"
    mgcj mgc network public-ips attach \
      --public-ip-id="$old_public_ip_id" --port-id="$new_port_id" >/dev/null \
      || die "Falha ao acoplar IP público"

    for _i in $(seq 1 30); do
      active_ip=$(mgcj mgc virtual-machine instances get "$new_vm_id" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ifaces=d.get('network',{}).get('interfaces',[])
print(ifaces[0].get('associated_public_ipv4','') if ifaces else '')
" 2>/dev/null || echo "")
      [[ -n "$active_ip" ]] && break
      sleep 5
    done
    step_ok "IP público" "${active_ip:-associando...}"

    step "SSH" "Validando acesso na nova VM"
    if [[ -n "$active_ip" ]] && \
       ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
           -o BatchMode=yes "${VM_USER}@${active_ip}" "exit 0" 2>/dev/null; then
      step_ok "SSH" "Acesso confirmado"
      ssh_accessible=1
      vm_id="$new_vm_id"
    else
      warn "SSH ainda não responde — o cluster pode precisar de alguns instantes"
    fi

    step "Snapshot" "Removendo snapshot temporário"
    mgcj mgc virtual-machine snapshots delete --id="$snap_id" --no-confirm >/dev/null 2>&1 \
      && step_ok "Snapshot" "Removido" \
      || warn "Não foi possível remover snapshot '${snap_id}' — remova manualmente"

    step "VM antiga" "Removendo"
    mgcj mgc virtual-machine instances delete "$vm_id" --no-confirm >/dev/null 2>&1 \
      && step_ok "VM antiga" "Removida" \
      || warn "Não foi possível remover VM antiga '${vm_id}' — remova manualmente"
  fi

  # ── kubectl ───────────────────────────────────────────────────
  diag_sub_parent_ok "kubectl"

  # Kubeconfig: verifica antes de reescrever
  local kubeconfig_ok=0
  if kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
    kubeconfig_ok=1
    diag_subsub_ok "Kubeconfig" "configurado"
  else
    diag_subsub_fail "Kubeconfig" "não conecta"
    if [[ "$ssh_accessible" -eq 1 ]]; then
      mkdir -p "${HOME}/.kube"
      vm_ssh "$active_ip" "sudo cat /etc/rancher/k3s/k3s.yaml" \
        | sed "s/127.0.0.1/${active_ip}/g" \
        > "${HOME}/.kube/config"
      chmod 600 "${HOME}/.kube/config"
      diag_subsub_ok "Kubeconfig" "reconfigurado"
      kubeconfig_ok=1
    else
      diag_subsub_skip "Kubeconfig"
    fi
  fi

  # Security Group porta 6443
  if [[ -n "$sg_id" ]]; then
    local rules_json_6443
    rules_json_6443=$(mgcj mgc network security-groups rules list --security-group-id="$sg_id" 2>/dev/null) || rules_json_6443=""
    local sg6443_status
    sg6443_status=$(_sg_port_status "$rules_json_6443" 6443)
    if [[ "$sg6443_status" == "open" ]]; then
      diag_subsub_ok "Grupo de Segurança" "porta 6443 aberta"
    else
      diag_subsub_fail "Grupo de Segurança" "porta 6443 ${sg6443_status}"
      _fix_sg_port "$sg_id" 6443
      diag_subsub_ok "Grupo de Segurança" "porta 6443 aberta"
    fi
  else
    diag_subsub_fail "Grupo de Segurança" "SG '${SG_NAME}' não encontrado"
  fi

  # ════════════════════════════════════════════════════════════════
  # KUBERNETES
  # ════════════════════════════════════════════════════════════════
  if [[ "$ssh_accessible" -eq 1 ]]; then
    diag_section "Kubernetes"
    diag_parent_ok "Cluster K3s"

    # Node
    local k3s_node
    k3s_node=$(vm_ssh "$active_ip" \
      "sudo k3s kubectl get nodes --no-headers 2>/dev/null | awk '{print \$2}'" 2>/dev/null || echo "")
    if [[ "$k3s_node" == "Ready" ]]; then
      diag_sub_ok "Node" "Ready"
    else
      diag_sub_fail "Node" "${k3s_node:-não responde} — reiniciando K3s"
      vm_ssh "$active_ip" "sudo systemctl restart k3s" 2>/dev/null || true
      sleep 5
      for _i in $(seq 1 24); do
        k3s_node=$(vm_ssh "$active_ip" \
          "sudo k3s kubectl get nodes --no-headers 2>/dev/null | awk '{print \$2}'" 2>/dev/null || echo "")
        [[ "$k3s_node" == "Ready" ]] && break
        sleep 5
      done
      [[ "$k3s_node" == "Ready" ]] \
        && diag_sub_ok "Node" "Ready" \
        || diag_sub_fail "Node" "ainda não Ready — verifique com: diagnose --cluster-id ${vm_id}"
    fi

    # Traefik
    local traefik_disabled
    traefik_disabled=$(vm_ssh "$active_ip" \
      "grep -q 'traefik' /etc/rancher/k3s/config.yaml 2>/dev/null && echo yes || echo no" 2>/dev/null || echo "no")
    if [[ "$traefik_disabled" == "yes" ]]; then
      diag_sub_ok "Traefik" "desabilitado"
    else
      diag_sub_fail "Traefik" "ativo — desabilitando"
      _apply_traefik_fix "$active_ip"
      diag_sub_ok "Traefik" "desabilitado"
    fi

    # Container Registry
    diag_sub_parent_ok "Container Registry"
    local secret_ok=0 sa_ok=0
    kubectl get secret mgc-registry-secret >/dev/null 2>&1 && secret_ok=1
    local sa_pull
    sa_pull=$(kubectl get sa default -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null || echo "")
    [[ "$sa_pull" == *"mgc-registry-secret"* ]] && sa_ok=1

    if [[ "$secret_ok" -eq 1 && "$sa_ok" -eq 1 ]]; then
      diag_subsub_ok "Secret" "mgc-registry-secret presente"
      diag_subsub_ok "Service Account" "imagePullSecrets configurado"
    else
      [[ "$secret_ok" -eq 1 ]] \
        && diag_subsub_ok "Secret" "mgc-registry-secret presente" \
        || diag_subsub_fail "Secret" "ausente"
      [[ "$sa_ok" -eq 1 ]] \
        && diag_subsub_ok "Service Account" "imagePullSecrets configurado" \
        || diag_subsub_fail "Service Account" "não configurado"
      _ensure_registry
      diag_subsub_ok "Secret" "mgc-registry-secret presente"
      diag_subsub_ok "Service Account" "imagePullSecrets configurado"
    fi
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${G}${B}✓ Cluster '${name}' corrigido!${N}"
  echo ""
  echo -e "  IP:        ${C}${active_ip:-${vm_ip}}${N}"
  echo -e "  Verificar: ${C}kubectl get nodes${N}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ─── COMANDO: fix ─────────────────────────────────────────────────────────────
cmd_fix() {
  local cluster_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster-id)   cluster_id="$2"; shift 2 ;;
      --cluster-id=*) cluster_id="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done

  if [[ -n "$cluster_id" ]]; then
    cluster_by_id "$cluster_id" >/dev/null \
      || die "Cluster '${cluster_id}' não encontrado. Liste com: ./k3s.sh kubernetes cluster list"
    _fix_cluster "$cluster_id"
  else
    local clusters
    clusters=$(list_clusters)
    if [[ -z "$clusters" ]]; then
      echo "Nenhum cluster encontrado."
      return
    fi
    while IFS='|' read -r vm_id name ip; do
      [[ -z "$vm_id" ]] && continue
      _fix_cluster "$vm_id"
    done <<< "$clusters"
  fi
}

# ─── Help ─────────────────────────────────────────────────────────────────────
cmd_help() {
  echo ""
  echo -e "${B}k3s.sh${N} — Kubernetes local via K3s na Magalu Cloud"
  echo ""
  echo "Uso:"
  echo -e "  ${C}./k3s.sh kubernetes cluster list${N}"
  echo -e "  ${C}./k3s.sh kubernetes cluster create${N}"
  echo -e "  ${C}./k3s.sh kubernetes cluster start               --cluster-id ID${N}"
  echo -e "  ${C}./k3s.sh kubernetes cluster stop                --cluster-id ID${N}"
  echo -e "  ${C}./k3s.sh kubernetes cluster kubeconfig          --cluster-id ID > kubeconfig.yaml${N}"
  echo -e "  ${C}./k3s.sh kubernetes cluster get                 --cluster-id ID${N}"
  echo -e "  ${C}./k3s.sh kubernetes cluster delete              --cluster-id ID${N}"
  echo -e "  ${C}./k3s.sh kubernetes cluster configure-registry  --cluster-id ID${N}"
echo -e "  ${C}./k3s.sh kubernetes cluster diagnose${N}                                        # diagnóstico de todos os clusters"
  echo -e "  ${C}./k3s.sh kubernetes cluster diagnose           --cluster-id ID${N}              # diagnóstico de um cluster específico"
  echo -e "  ${C}./k3s.sh kubernetes cluster fix${N}                                              # recupera acesso em todos os clusters com problema"
  echo -e "  ${C}./k3s.sh kubernetes cluster fix              --cluster-id ID${N}              # recupera acesso em um cluster específico"
  echo ""
  echo -e "  ${C}./k3s.sh network ip-cleanup${N}   — lista e remove IPs públicos órfãos"
  echo ""
  echo "Equivalente aos comandos 'mgc kubernetes cluster ...' do MKS."
  echo "A região utilizada é a configurada no mgc CLI: mgc profile region set"
  echo ""
}

# ─── Router ───────────────────────────────────────────────────────────────────
[[ $# -lt 1 ]] && { cmd_help; exit 0; }
check_update
check_prereqs

case "${1:-} ${2:-} ${3:-}" in
  "kubernetes cluster create"*)              shift 3; cmd_create              "$@" ;;
  "kubernetes cluster start"*)               shift 3; cmd_start               "$@" ;;
  "kubernetes cluster stop"*)                shift 3; cmd_stop                "$@" ;;
  "kubernetes cluster kubeconfig"*)          shift 3; cmd_kubeconfig          "$@" ;;
  "kubernetes cluster list"*)                shift 3; cmd_list                     ;;
  "kubernetes cluster get"*)                 shift 3; cmd_get                 "$@" ;;
  "kubernetes cluster delete"*)              shift 3; cmd_delete              "$@" ;;
  "kubernetes cluster configure-registry"*)  shift 3; cmd_configure_registry  "$@" ;;
"kubernetes cluster diagnose"*)            shift 3; cmd_diagnose             "$@" ;;
  "kubernetes cluster fix"*)                 shift 3; cmd_fix                  "$@" ;;
  "network ip-cleanup"*)                     shift 2; cmd_ip_cleanup               ;;
  *) cmd_help ;;
esac
