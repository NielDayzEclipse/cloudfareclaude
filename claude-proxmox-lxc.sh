#!/usr/bin/env bash
# =============================================================================
#  Claude + Proxmox MCP  -  instalador de LXC (estilo community-scripts)
#
#  Rode no SHELL DO NÓ PROXMOX (Datacenter > seu nó > Shell), como root:
#     bash claude-proxmox-lxc.sh
#
#  O que ele faz:
#    1. Cria um usuário dedicado (claude-mcp@pve) e um token de API com
#       Privilege Separation e permissões limitadas (leitura OU controle de VMs)
#    2. Cria um container LXC Debian 13 sem privilégios
#    3. Instala dentro dele: Node.js, o servidor MCP "mcp-proxmox" e o Claude Code
#    4. Registra o MCP no Claude Code, já com o token
#
#  Nada fica exposto na internet: o Claude Code roda dentro da sua rede.
# =============================================================================
set -euo pipefail

# ------------------------- Configurações (ajuste se quiser) ------------------
CT_HOSTNAME="claude"
CT_CORES=2
CT_RAM=2048          # MB
CT_SWAP=512          # MB
CT_DISK=8            # GB
CT_BRIDGE="vmbr0"
CT_STORAGE="${CT_STORAGE:-local-lvm}"   # onde fica o disco do container
TMPL_STORAGE="${TMPL_STORAGE:-local}"   # onde ficam os templates
PVE_USER="claude-mcp@pve"
PVE_TOKEN="mcp"
MCP_REPO="https://github.com/gilby125/mcp-proxmox.git"
# -----------------------------------------------------------------------------

VERDE='\e[32m'; AMARELO='\e[33m'; VERMELHO='\e[31m'; NC='\e[0m'
msg()  { echo -e "${VERDE}[✓]${NC} $*"; }
info() { echo -e "${AMARELO}[i]${NC} $*"; }
erro() { echo -e "${VERMELHO}[x]${NC} $*" >&2; exit 1; }

# ---------- Checagens ----------
[[ $EUID -eq 0 ]] || erro "Rode como root no shell do Proxmox."
command -v pct >/dev/null && command -v pveum >/dev/null \
  || erro "Este script precisa rodar no host Proxmox VE (pct/pveum não encontrados)."

echo
echo "=========================================="
echo "   Claude Code + Proxmox MCP  (LXC)"
echo "=========================================="
echo
echo "Que nível de acesso o Claude deve ter?"
echo "  1) Somente leitura  (ver nós, VMs, containers, uso de recursos)  [recomendado]"
echo "  2) Controle de VMs  (também ligar/desligar/reiniciar/snapshots)"
read -rp "Escolha [1/2]: " MODO
case "${MODO:-1}" in
  2) ROLES="PVEAuditor,PVEVMUser"; ELEVATED="true";  info "Modo: controle de VMs" ;;
  *) ROLES="PVEAuditor";           ELEVATED="false"; info "Modo: somente leitura" ;;
esac

read -rsp "Senha de root para o novo container: " CT_PASS; echo
[[ ${#CT_PASS} -ge 5 ]] || erro "Use uma senha com pelo menos 5 caracteres."

CTID=$(pvesh get /cluster/nextid)
PVE_HOST_IP=$(hostname -I | awk '{print $1}')
info "ID do container: ${CTID}   |   IP do Proxmox: ${PVE_HOST_IP}"

# ---------- 1. Usuário + token de API ----------
info "Criando usuário ${PVE_USER} e token de API..."
pveum user list --output-format json | grep -q "\"${PVE_USER}\"" \
  || pveum user add "${PVE_USER}" --comment "Usado pelo Claude (MCP)"

# recria o token caso já exista (o segredo só é mostrado na criação)
if pveum user token list "${PVE_USER}" --output-format json 2>/dev/null | grep -q "\"${PVE_TOKEN}\""; then
  pveum user token remove "${PVE_USER}" "${PVE_TOKEN}"
fi
TOKEN_JSON=$(pveum user token add "${PVE_USER}" "${PVE_TOKEN}" --privsep 1 \
  --comment "Claude MCP" --output-format json)
TOKEN_VALUE=$(echo "${TOKEN_JSON}" | grep -oP '"value"\s*:\s*"\K[^"]+')
[[ -n "${TOKEN_VALUE}" ]] || erro "Não consegui ler o segredo do token."

# com privsep, a permissão efetiva = interseção usuário ∩ token -> dar aos dois
pveum acl modify / --users  "${PVE_USER}"              --roles "${ROLES}"
pveum acl modify / --tokens "${PVE_USER}!${PVE_TOKEN}" --roles "${ROLES}"
msg "Token ${PVE_USER}!${PVE_TOKEN} criado com papel(is): ${ROLES}"

# ---------- 2. Template Debian 13 ----------
info "Procurando template Debian 13..."
pveam update >/dev/null
TMPL=$(pveam available --section system | awk '/debian-13-standard/ {print $2}' | sort -V | tail -1)
[[ -n "${TMPL}" ]] || erro "Template Debian 13 não encontrado."
if ! pveam list "${TMPL_STORAGE}" | grep -q "${TMPL}"; then
  pveam download "${TMPL_STORAGE}" "${TMPL}"
fi
msg "Template: ${TMPL}"

# ---------- 3. Container ----------
info "Criando container ${CTID}..."
pct create "${CTID}" "${TMPL_STORAGE}:vztmpl/${TMPL}" \
  --hostname "${CT_HOSTNAME}" \
  --cores "${CT_CORES}" --memory "${CT_RAM}" --swap "${CT_SWAP}" \
  --rootfs "${CT_STORAGE}:${CT_DISK}" \
  --net0 "name=eth0,bridge=${CT_BRIDGE},ip=dhcp" \
  --unprivileged 1 --features nesting=1 --onboot 1 \
  --password "${CT_PASS}" \
  --tags "claude;mcp" \
  --description "Claude Code + Proxmox MCP (${ROLES})"
pct start "${CTID}"

info "Aguardando rede do container..."
for i in {1..30}; do
  pct exec "${CTID}" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
  sleep 2
  [[ $i -eq 30 ]] && erro "Container sem acesso à internet."
done
msg "Container no ar."

# ---------- 4. Pacotes, MCP e Claude Code ----------
info "Instalando Node.js, git e dependências..."
pct exec "${CTID}" -- bash -c "export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq curl git ca-certificates nodejs npm >/dev/null"

info "Instalando servidor MCP do Proxmox..."
pct exec "${CTID}" -- bash -c "git clone -q ${MCP_REPO} /opt/mcp-proxmox \
  && cd /opt/mcp-proxmox && npm install --omit=dev --silent"

info "Instalando Claude Code..."
pct exec "${CTID}" -- bash -c "curl -fsSL https://claude.ai/install.sh | bash" \
  || erro "Falha ao instalar o Claude Code."
pct exec "${CTID}" -- bash -c 'grep -q ".local/bin" ~/.bashrc || echo "export PATH=\$HOME/.local/bin:\$PATH" >> ~/.bashrc'

info "Registrando o MCP no Claude Code..."
# NODE_TLS_REJECT_UNAUTHORIZED=0: o Proxmox usa certificado autoassinado.
# Vale só para este processo MCP, que fala apenas com o Proxmox na sua rede local.
pct exec "${CTID}" -- /root/.local/bin/claude mcp add proxmox --scope user \
  -e PROXMOX_HOST="${PVE_HOST_IP}" \
  -e PROXMOX_PORT=8006 \
  -e PROXMOX_USER="${PVE_USER}" \
  -e PROXMOX_TOKEN_NAME="${PVE_TOKEN}" \
  -e PROXMOX_TOKEN_VALUE="${TOKEN_VALUE}" \
  -e PROXMOX_ALLOW_ELEVATED="${ELEVATED}" \
  -e NODE_TLS_REJECT_UNAUTHORIZED=0 \
  -- node /opt/mcp-proxmox/index.js
pct exec "${CTID}" -- bash -c 'chmod 600 /root/.claude.json 2>/dev/null || true'

# instruções para o Claude dentro do container
pct exec "${CTID}" -- bash -c "cat > /root/CLAUDE.md <<'EOF'
# Contexto
Você administra o servidor Proxmox VE do usuário pelo MCP \"proxmox\".
- Responda em português.
- Antes de qualquer ação que altere algo (desligar, reiniciar, snapshot, apagar),
  explique o que vai fazer e peça confirmação.
- Para diagnósticos, comece listando nós, VMs/containers e uso de CPU/RAM/disco.
EOF"

CT_IP=$(pct exec "${CTID}" -- hostname -I | awk '{print $1}')
unset TOKEN_VALUE TOKEN_JSON CT_PASS

echo
msg "Pronto!"
echo "------------------------------------------------------------"
echo " Container: ${CTID} (${CT_HOSTNAME})  IP: ${CT_IP}"
echo " Acesso:    ${ROLES}"
echo
echo " Para usar:"
echo "   pct enter ${CTID}        (ou: ssh root@${CT_IP})"
echo "   cd /root && claude"
echo
echo " No primeiro uso, faça login com sua conta Claude (ele mostra um link)."
echo " Depois digite /mcp para conferir se o 'proxmox' está conectado."
echo "------------------------------------------------------------"
