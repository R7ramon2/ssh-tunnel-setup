#!/usr/bin/env bash
# =============================================================================
#  tunnel-setup.sh — SSH Reverse Tunnel Configurator
#  Compatível com: Linux (Debian/Ubuntu/Arch/Alpine), macOS, Raspberry Pi OS
#  Autor: Ramon Alcântara
#  Linkedin: https://www.linkedin.com/in/ramon-ranieri-276566150/
# =============================================================================

set -euo pipefail

# ─── Cores e estilos ──────────────────────────────────────────────────────────
if [ -t 1 ] && command -v tput &>/dev/null && tput colors &>/dev/null 2>&1 && [ "$(tput colors)" -ge 8 ]; then
  BOLD=$(tput bold); RESET=$(tput sgr0)
  RED=$(tput setaf 1);   GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
  BLUE=$(tput setaf 4);  CYAN=$(tput setaf 6);  WHITE=$(tput setaf 7)
  MAGENTA=$(tput setaf 5)
else
  BOLD=''; RESET=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; WHITE=''; MAGENTA=''
fi

# ─── Variáveis padrão ─────────────────────────────────────────────────────────
VPS_HOST=""
VPS_USER="ubuntu"
VPS_PORT=22
REMOTE_PORT=2222
LOCAL_PORT=22
BIND_IFACE=""
LOCAL_IP=""
USE_KEY=true
KEY_PATH=""
KEY_GEN=false
KEY_HAS_PASSPHRASE=false
AGENT_SOCK=""
AGENT_PID=""
PERSISTENT=false
CREATE_SERVICE=false
DRY_RUN=false
UNINSTALL=false
STATUS=false
ACTION=""
SERVICE_NAME="ssh-tunnel"

# ─── Helpers ──────────────────────────────────────────────────────────────────
banner() {
  clear
  echo "${BOLD}${CYAN}"
  echo "  ╔══════════════════════════════════════════════════════════╗"
  echo "  ║          SSH REVERSE TUNNEL — SETUP INTERATIVO           ║"
  echo "  ║      Rasp / Linux / macOS  →  VPS AWS / DigitalOcean     ║"
  echo "  ╚══════════════════════════════════════════════════════════╝${RESET}"
  echo ""
}

info()    { echo "  ${CYAN}→${RESET} $*"; }
ok()      { echo "  ${GREEN}✔${RESET} $*"; }
warn()    { echo "  ${YELLOW}⚠${RESET}  $*"; }
error()   { echo "  ${RED}✘${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }
section() { echo ""; echo "  ${BOLD}${BLUE}▸ $*${RESET}"; echo "  ${BLUE}$(printf '─%.0s' {1..54})${RESET}"; }

ask() {
  local prompt="$1" default="${2:-}" var_name="$3"
  local display_default=""
  [ -n "$default" ] && display_default=" ${CYAN}[${default}]${RESET}"
  printf "  ${WHITE}%s%s:${RESET} " "$prompt" "$display_default"
  read -r input
  [ -z "$input" ] && input="$default"
  eval "$var_name=\"\$input\""
}

ask_yn() {
  local prompt="$1" default="${2:-n}" var_name="$3"
  local hint; [ "$default" = "y" ] && hint="S/n" || hint="s/N"
  local input
  while true; do
    printf "  ${WHITE}%s ${CYAN}[%s]${RESET}: " "$prompt" "$hint"
    read -r input || input=""
    input=$(echo "${input:-$default}" | tr '[:upper:]' '[:lower:]')
    case "$input" in
      s|y|sim|yes) eval "$var_name=true";  return ;;
      n|no|nao|não) eval "$var_name=false"; return ;;
      *) warn "Resposta inválida: '${input}'. Digite ${BOLD}s${RESET} para sim ou ${BOLD}n${RESET} para não." ;;
    esac
  done
}

# ─── Detectar sistema operacional ─────────────────────────────────────────────
detect_os() {
  OS="unknown"
  INIT="unknown"

  if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
      ubuntu|debian|raspbian) OS="debian" ;;
      arch|manjaro)            OS="arch"   ;;
      alpine)                  OS="alpine" ;;
      fedora|rhel|centos)      OS="fedora" ;;
      *)                       OS="linux"  ;;
    esac
  elif [[ "$(uname)" == "Darwin" ]]; then
    OS="macos"
  fi

  # Detectar init system
  if command -v systemctl &>/dev/null && systemctl status &>/dev/null 2>&1; then
    INIT="systemd"
  elif [ -d /etc/init.d ] && command -v update-rc.d &>/dev/null; then
    INIT="sysvinit"
  elif [ -f /sbin/openrc-run ] || command -v rc-service &>/dev/null; then
    INIT="openrc"
  elif [[ "$OS" == "macos" ]]; then
    INIT="launchd"
  fi
}

# ─── Instalar dependências ─────────────────────────────────────────────────────
install_deps() {
  section "Verificando dependências"

  local missing=()
  command -v ssh      &>/dev/null || missing+=("openssh-client")
  command -v autossh  &>/dev/null || missing+=("autossh")

  if [ ${#missing[@]} -eq 0 ]; then
    ok "Todas as dependências já estão instaladas."
    return
  fi

  warn "Pacotes necessários: ${missing[*]}"
  ask_yn "Instalar automaticamente?" "y" do_install

  if $do_install; then
    case "$OS" in
      debian)
        sudo apt-get update -qq
        sudo apt-get install -y "${missing[@]}"
        ;;
      arch)
        sudo pacman -Sy --noconfirm "${missing[@]}"
        ;;
      alpine)
        sudo apk add --no-cache "${missing[@]}"
        ;;
      fedora)
        sudo dnf install -y "${missing[@]}" 2>/dev/null || sudo yum install -y "${missing[@]}"
        ;;
      macos)
        if ! command -v brew &>/dev/null; then
          die "Homebrew não encontrado. Instale em: https://brew.sh"
        fi
        brew install autossh
        ;;
      *)
        die "Sistema não reconhecido. Instale manualmente: ${missing[*]}"
        ;;
    esac
    ok "Dependências instaladas."
  else
    die "Dependências ausentes. Abortando."
  fi
}

# ─── Verificar requisitos e mostrar checklist ──────────────────────────────────
show_checklist() {
  section "Checklist de pré-requisitos"

  local checks=(
    "ssh:Cliente SSH instalado"
    "autossh:autossh instalado (reconexão automática)"
  )

  for item in "${checks[@]}"; do
    local cmd="${item%%:*}" label="${item##*:}"
    if command -v "$cmd" &>/dev/null; then
      ok "$label  $(command -v "$cmd")"
    else
      warn "$label  — ${YELLOW}NÃO ENCONTRADO${RESET}"
    fi
  done

  echo ""
  info "Sistema operacional : ${BOLD}${OS}${RESET}"
  info "Init system         : ${BOLD}${INIT}${RESET}"
  echo ""
}

# ─── Detectar se chave tem passphrase ────────────────────────────────────────
KEY_HAS_PASSPHRASE=false

key_has_passphrase() {
  local key="$1"
  # ssh-keygen -y tenta ler a chave; com -P "" funciona só se não tiver passphrase
  if ssh-keygen -y -P "" -f "$key" &>/dev/null; then
    return 1  # sem passphrase
  else
    return 0  # tem passphrase
  fi
}

# ─── Garantir que ssh-agent está rodando e tem a chave ───────────────────────
ensure_agent_has_key() {
  local key="$1"

  # Iniciar agent se não estiver ativo
  if [ -z "${SSH_AUTH_SOCK:-}" ] || ! ssh-add -l &>/dev/null; then
    info "Iniciando ssh-agent..."
    eval "$(ssh-agent -s)" > /dev/null
    export SSH_AUTH_SOCK SSH_AGENT_PID
  fi

  # Verificar se a chave já está carregada no agent
  local key_fp
  key_fp=$(ssh-keygen -lf "$key" 2>/dev/null | awk '{print $2}')
  if ssh-add -l 2>/dev/null | grep -qF "$key_fp"; then
    ok "Chave já carregada no ssh-agent."
    return 0
  fi

  # Carregar a chave (vai pedir passphrase se tiver)
  echo ""
  warn "A chave ${BOLD}${key}${RESET} tem passphrase."
  info "Digite a passphrase para carregá-la no ssh-agent agora."
  info "O agent manterá a chave em memória durante a sessão."
  echo ""
  if ssh-add "$key"; then
    ok "Chave carregada no ssh-agent com sucesso."
  else
    die "Falha ao carregar a chave no ssh-agent. Verifique a passphrase."
  fi

  # Persistir SSH_AUTH_SOCK no script do túnel para que o serviço encontre o agent
  AGENT_SOCK="$SSH_AUTH_SOCK"
  AGENT_PID="${SSH_AGENT_PID:-}"
}

# ─── Configurar chave SSH ──────────────────────────────────────────────────────
configure_key() {
  section "Autenticação SSH"

  ask_yn "Usar autenticação por chave SSH? (recomendado)" "y" USE_KEY

  if $USE_KEY; then
    local default_key="$HOME/.ssh/tunnel_key"
    ask "Caminho da chave privada" "$default_key" KEY_PATH

    if [ ! -f "$KEY_PATH" ]; then
      warn "Chave não encontrada em: $KEY_PATH"
      ask_yn "Gerar nova chave SSH agora?" "y" KEY_GEN

      if $KEY_GEN; then
        local use_passphrase_on_new
        ask_yn "Proteger a nova chave com passphrase?" "n" use_passphrase_on_new
        if $use_passphrase_on_new; then
          ssh-keygen -t ed25519 -f "$KEY_PATH" -C "tunnel@$(hostname)"
          warn "Chave gerada COM passphrase. O setup irá carregá-la no ssh-agent."
        else
          ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "tunnel@$(hostname)"
          ok "Chave gerada SEM passphrase (ideal para serviços automáticos)."
        fi
        echo ""
        warn "Copie a chave pública para a VPS antes de continuar:"
        echo ""
        echo "  ${CYAN}ssh-copy-id -i ${KEY_PATH}.pub ${VPS_USER}@${VPS_HOST}${RESET}"
        echo ""
        printf "  Pressione ${BOLD}ENTER${RESET} após ter copiado a chave..."
        read -r
      else
        die "Chave não encontrada. Forneça uma chave válida ou gere uma nova."
      fi
    else
      ok "Chave encontrada: $KEY_PATH"
    fi

    # Detectar passphrase
    if key_has_passphrase "$KEY_PATH"; then
      KEY_HAS_PASSPHRASE=true
      warn "Chave com passphrase detectada."
      info "O script irá usar o ssh-agent para autenticação automática."
      ensure_agent_has_key "$KEY_PATH"
    else
      KEY_HAS_PASSPHRASE=false
      ok "Chave sem passphrase — compatível com serviços automáticos."
    fi

    # Testar conexão
    info "Testando conexão com a VPS..."
    local ssh_test_opts=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -p "$VPS_PORT")
    # Com passphrase: não passa -i, usa o agent; sem passphrase: passa -i diretamente
    if $KEY_HAS_PASSPHRASE; then
      ssh "${ssh_test_opts[@]}" "${VPS_USER}@${VPS_HOST}" "echo OK" &>/dev/null && \
        ok "Conexão via ssh-agent estabelecida com sucesso!" || \
        { warn "Não foi possível conectar via agent. Verifique se a chave foi carregada."; }
    else
      ssh "${ssh_test_opts[@]}" -i "$KEY_PATH" "${VPS_USER}@${VPS_HOST}" "echo OK" &>/dev/null && \
        ok "Conexão estabelecida com sucesso!" || \
        { warn "Não foi possível conectar. Verifique o IP e se a chave pública está na VPS."; }
    fi

  else
    KEY_PATH=""
    KEY_HAS_PASSPHRASE=false
    warn "Autenticação por senha: o túnel pode pedir senha ao reconectar."
    warn "Isso impede serviços automáticos — use chave para persistência."
  fi
}

# ─── Configurar parâmetros do túnel ───────────────────────────────────────────
# ─── Listar e selecionar interface de rede ────────────────────────────────────
select_interface() {
  section "Interface de saída da conexão"
  info "Interfaces de rede disponíveis neste host:"
  echo ""

  local ifaces=()
  local ips=()
  local states=()

  # ── Coleta de interfaces — desativa set -e localmente para evitar abort ──
  local raw_output=""

  if command -v ip &>/dev/null; then
    raw_output=$(ip addr 2>/dev/null) || raw_output=""
    local cur_iface="" cur_ip="" cur_state=""
    while IFS= read -r line; do
      if [[ "$line" =~ ^[0-9]+:[[:space:]]([^:@[:space:]]+) ]]; then
        # Salvar interface anterior se não for lo
        if [[ -n "$cur_iface" && "$cur_iface" != "lo" ]]; then
          ifaces+=("$cur_iface")
          ips+=("${cur_ip:-}")
          states+=("${cur_state:-?}")
        fi
        cur_iface="${BASH_REMATCH[1]}"
        cur_ip=""
        cur_state="?"
        # Detectar estado UP/DOWN na mesma linha
        if [[ "$line" =~ [[:space:]]state[[:space:]]UP ]]; then
          cur_state="UP"
        elif [[ "$line" =~ [[:space:]]state[[:space:]]DOWN ]]; then
          cur_state="DOWN"
        fi
      elif [[ "$line" =~ ^[[:space:]]+inet[[:space:]]([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
        [[ -z "$cur_ip" ]] && cur_ip="${BASH_REMATCH[1]}"
      fi
    done <<< "$raw_output"
    # Não esquecer a última interface
    if [[ -n "$cur_iface" && "$cur_iface" != "lo" ]]; then
      ifaces+=("$cur_iface")
      ips+=("${cur_ip:-}")
      states+=("${cur_state:-?}")
    fi

  elif command -v ifconfig &>/dev/null; then
    raw_output=$(ifconfig 2>/dev/null) || raw_output=""
    local cur_iface="" cur_ip=""
    while IFS= read -r line; do
      if [[ "$line" =~ ^([a-zA-Z0-9]+[a-zA-Z0-9._-]*): ]]; then
        if [[ -n "$cur_iface" && "$cur_iface" != lo* ]]; then
          ifaces+=("$cur_iface")
          ips+=("${cur_ip:-}")
          states+=("?")
        fi
        cur_iface="${BASH_REMATCH[1]}"
        cur_ip=""
      elif [[ "$line" =~ inet[[:space:]]([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
        [[ -z "$cur_ip" ]] && cur_ip="${BASH_REMATCH[1]}"
      fi
    done <<< "$raw_output"
    if [[ -n "$cur_iface" && "$cur_iface" != lo* ]]; then
      ifaces+=("$cur_iface")
      ips+=("${cur_ip:-}")
      states+=("?")
    fi

  else
    warn "ip/ifconfig não encontrado — usando todas as interfaces por padrão."
    BIND_IFACE=""; LOCAL_IP=""
    return 0
  fi

  if [[ ${#ifaces[@]} -eq 0 ]]; then
    warn "Nenhuma interface encontrada — usando todas as interfaces por padrão."
    BIND_IFACE=""; LOCAL_IP=""
    return 0
  fi

  # ── Exibir tabela ──────────────────────────────────────────────────────────
  printf "  ${BOLD}%-5s %-16s %-18s %-8s %s${RESET}
" "Nº" "Interface" "IP" "Estado" "Tipo"
  printf "  ${BLUE}%-5s %-16s %-18s %-8s %s${RESET}
" "───" "─────────────" "───────────────" "──────" "────"

  local i
  for i in "${!ifaces[@]}"; do
    local iface="${ifaces[$i]}"
    local ip="${ips[$i]:-sem IP}"
    local state="${states[$i]:-?}"
    local num=$((i + 1))

    local estado_fmt
    case "$state" in
      UP)   estado_fmt="${GREEN}UP${RESET}" ;;
      DOWN) estado_fmt="${RED}DOWN${RESET}" ;;
      *)    estado_fmt="${YELLOW}?${RESET}" ;;
    esac

    local label=""
    case "$iface" in
      eth*|en[0-9]*|eno*|enp*|ens*) label="${CYAN}cabeada${RESET}" ;;
      wlan*|wl*)                     label="${CYAN}Wi-Fi${RESET}" ;;
      tun*|tap*|wg*)                 label="${YELLOW}VPN/túnel${RESET}" ;;
      docker*|br-*|veth*|virbr*)    label="${YELLOW}container${RESET}" ;;
      *)                             label="outra" ;;
    esac

    printf "  ${BOLD}[%-2s]${RESET} %-16s %-18s %-18b %b
"       "$num" "$iface" "$ip" "$estado_fmt" "$label"
  done

  echo ""
  printf "  ${BOLD}[0]${RESET}  Todas as interfaces ${CYAN}(padrão — recomendado)${RESET}
"
  echo ""
  printf "  ${WHITE}Escolha a interface de saída [0]:${RESET} "
  read -r escolha || escolha=""

  # ── Processar escolha ──────────────────────────────────────────────────────
  if [[ -z "$escolha" || "$escolha" == "0" ]]; then
    BIND_IFACE=""
    LOCAL_IP="localhost"
    info "Usando todas as interfaces (0.0.0.0)."
  elif [[ "$escolha" =~ ^[0-9]+$ ]]     && [[ "$escolha" -ge 1 ]]     && [[ "$escolha" -le "${#ifaces[@]}" ]]; then
    local sel=$(( escolha - 1 ))
    BIND_IFACE="${ifaces[$sel]}"
    LOCAL_IP="${ips[$sel]:-}"
    if [[ -z "$LOCAL_IP" ]]; then
      warn "Interface ${BOLD}${BIND_IFACE}${RESET} sem IP — verifique se está ativa."
      LOCAL_IP="localhost"
    else
      ok "Interface: ${BOLD}${BIND_IFACE}${RESET}  IP: ${BOLD}${LOCAL_IP}${RESET}"
    fi
  else
    warn "Opção inválida — usando todas as interfaces."
    BIND_IFACE=""; LOCAL_IP="localhost"
  fi
}

configure_tunnel() {
  section "Parâmetros do túnel"

  ask "IP ou hostname da VPS" "${VPS_HOST:-}" VPS_HOST
  [ -z "$VPS_HOST" ] && die "IP da VPS é obrigatório."

  ask "Usuário na VPS" "$VPS_USER" VPS_USER
  ask "Porta SSH da VPS" "$VPS_PORT" VPS_PORT
  ask "Porta remota na VPS (acesso externo)" "$REMOTE_PORT" REMOTE_PORT
  ask "Porta local a ser encaminhada" "$LOCAL_PORT" LOCAL_PORT

  select_interface

  echo ""
  info "Resumo da conexão:"
  local bind_display="${LOCAL_IP:-0.0.0.0}${BIND_IFACE:+ (${BIND_IFACE})}"
  echo "  ${BOLD}${VPS_USER}@${VPS_HOST}:${VPS_PORT}${RESET}  →  porta ${BOLD}${REMOTE_PORT}${RESET} → ${bind_display}:${LOCAL_PORT}"
}

# ─── Configurar persistência ───────────────────────────────────────────────────
configure_persistence() {
  section "Persistência e resiliência"

  ask_yn "Manter túnel persistente (reconectar se cair ou reiniciar)?" "y" PERSISTENT

  if $PERSISTENT; then
    ask_yn "Criar serviço do sistema (inicia no boot automaticamente)?" "y" CREATE_SERVICE
    ok "O túnel será reiniciado automaticamente em caso de falha."
  else
    info "Modo temporário: o túnel vai rodar apenas enquanto o script estiver ativo."
  fi
}

# ─── Gerar script do túnel ────────────────────────────────────────────────────
generate_tunnel_script() {
  local script_path="$HOME/.local/bin/run-tunnel.sh"
  mkdir -p "$(dirname "$script_path")"

  # Montar bloco de autenticação conforme o caso
  local auth_block=""
  if $USE_KEY && [ -n "$KEY_PATH" ]; then
    if $KEY_HAS_PASSPHRASE; then
      # Chave com passphrase: precisa do ssh-agent em execução
      auth_block='
# Chave com passphrase: usar ssh-agent
# O agent deve estar ativo e com a chave carregada (ssh-add KEY_PATH)
if [ -z "${SSH_AUTH_SOCK:-}" ]; then
  echo "[ERRO] ssh-agent não encontrado. Inicie com:"
  echo "  eval \$(ssh-agent -s) && ssh-add '"$KEY_PATH"'"
  exit 1
fi
if ! ssh-add -l 2>/dev/null | grep -qF "'"$KEY_PATH"'"; then
  echo "[AVISO] Chave não encontrada no agent. Tentando adicionar..."
  ssh-add '"$KEY_PATH"' || { echo "[ERRO] Falha ao carregar chave. Verifique o agent."; exit 1; }
fi
SSH_KEY_FLAG=""  # agent cuida da autenticação'
    else
      auth_block='SSH_KEY_FLAG="-i '"$KEY_PATH"'"'
    fi
  else
    auth_block='SSH_KEY_FLAG=""'
  fi

  cat > "$script_path" <<TUNNEL_SCRIPT
#!/usr/bin/env bash
# Auto-gerado por tunnel-setup.sh
# VPS : ${VPS_USER}@${VPS_HOST}:${VPS_PORT}
# Túnel: porta ${REMOTE_PORT} (VPS) → localhost:${LOCAL_PORT}
# Chave com passphrase: ${KEY_HAS_PASSPHRASE}

set -euo pipefail

VPS_HOST="${VPS_HOST}"
VPS_USER="${VPS_USER}"
VPS_PORT="${VPS_PORT}"
REMOTE_PORT="${REMOTE_PORT}"
LOCAL_PORT="${LOCAL_PORT}"
BIND_IFACE="${BIND_IFACE}"
LOCAL_IP="${LOCAL_IP:-localhost}"

${auth_block}

echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Iniciando túnel SSH reverso..."
echo "  VPS : \${VPS_USER}@\${VPS_HOST}:\${VPS_PORT}"
echo "  Túnel: :\${REMOTE_PORT} (VPS) → \${LOCAL_IP}:\${LOCAL_PORT}${BIND_IFACE:+ via \${BIND_IFACE}}"

AUTOSSH_GATETIME=0 autossh -M 0 -N \\
  -o "ServerAliveInterval=30" \\
  -o "ServerAliveCountMax=3" \\
  -o "ExitOnForwardFailure=yes" \\
  -o "StrictHostKeyChecking=no" \\
  -o "ConnectTimeout=10" \\
  \${SSH_KEY_FLAG} \\
  -p "\${VPS_PORT}" \\
  ${BIND_IFACE:+-o "BindInterface=\${BIND_IFACE}"} \\
  -R "\${REMOTE_PORT}:\${LOCAL_IP}:\${LOCAL_PORT}" \\
  "\${VPS_USER}@\${VPS_HOST}"
TUNNEL_SCRIPT

  chmod +x "$script_path"
  echo "$script_path"
}

# ─── Criar serviço systemd ────────────────────────────────────────────────────
create_service_systemd() {
  local script_path="$1"
  local service_file="/etc/systemd/system/${SERVICE_NAME}.service"

  sudo tee "$service_file" > /dev/null <<SERVICE
[Unit]
Description=SSH Reverse Tunnel → ${VPS_USER}@${VPS_HOST}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=$(whoami)
ExecStart=${script_path}
Restart=always
RestartSec=15
Environment=AUTOSSH_GATETIME=0
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

  sudo systemctl daemon-reload
  sudo systemctl enable "$SERVICE_NAME"
  sudo systemctl restart "$SERVICE_NAME"
}

# ─── Criar serviço launchd (macOS) ───────────────────────────────────────────
create_service_launchd() {
  local script_path="$1"
  local plist_path="$HOME/Library/LaunchAgents/com.user.${SERVICE_NAME}.plist"

  cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.user.${SERVICE_NAME}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${script_path}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/${SERVICE_NAME}.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/${SERVICE_NAME}.err</string>
</dict>
</plist>
PLIST

  launchctl unload "$plist_path" 2>/dev/null || true
  launchctl load -w "$plist_path"
}

# ─── Criar serviço OpenRC ─────────────────────────────────────────────────────
create_service_openrc() {
  local script_path="$1"
  local rc_file="/etc/init.d/${SERVICE_NAME}"

  sudo tee "$rc_file" > /dev/null <<RC
#!/sbin/openrc-run
name="${SERVICE_NAME}"
description="SSH Reverse Tunnel"
command="${script_path}"
command_background=true
pidfile="/run/${SERVICE_NAME}.pid"
depend() { need net; }
RC

  sudo chmod +x "$rc_file"
  sudo rc-update add "$SERVICE_NAME" default
  sudo rc-service "$SERVICE_NAME" start
}

# ─── Instalar serviço conforme o init ─────────────────────────────────────────
install_service() {
  local script_path="$1"
  section "Instalando serviço do sistema"

  # Aviso crítico: serviço no boot não tem acesso ao ssh-agent nem ao terminal
  if $KEY_HAS_PASSPHRASE; then
    echo ""
    warn "${BOLD}Atenção: chave com passphrase + serviço no boot${RESET}"
    warn "Serviços de sistema (systemd/launchd) iniciam sem sessão do usuário."
    warn "Sem um ssh-agent ativo com a chave já carregada, o túnel não consegue"
    warn "autenticar e ficará em loop de falha."
    echo ""
    info "Opções recomendadas:"
    echo "  ${CYAN}1)${RESET} Remover a passphrase da chave (mais simples para serviços):"
    echo "     ${MAGENTA}ssh-keygen -p -f ${KEY_PATH} -N \"\"${RESET}"
    echo "  ${CYAN}2)${RESET} Usar uma chave separada SEM passphrase só para o túnel."
    echo "  ${CYAN}3)${RESET} Usar systemd com SSH_AUTH_SOCK apontando para um agent"
    echo "     persistente (ex: gnome-keyring, kde-wallet ou ssh-agent no .bashrc)."
    echo ""
    ask_yn "Continuar assim mesmo (serviço pode falhar no boot)?" "n" force_service
    $force_service || { warn "Serviço não instalado. Use modo --persistent sem --service."; return; }
  fi

  case "$INIT" in
    systemd)
      create_service_systemd "$script_path"
      ok "Serviço systemd criado: ${SERVICE_NAME}.service"
      info "Gerenciar com:"
      echo "    ${CYAN}sudo systemctl {start|stop|restart|status} ${SERVICE_NAME}${RESET}"
      echo "    ${CYAN}journalctl -u ${SERVICE_NAME} -f${RESET}"
      ;;
    launchd)
      create_service_launchd "$script_path"
      ok "LaunchAgent criado (macOS)."
      info "Logs em: /tmp/${SERVICE_NAME}.log"
      ;;
    openrc)
      create_service_openrc "$script_path"
      ok "Serviço OpenRC criado."
      info "Gerenciar com: ${CYAN}sudo rc-service ${SERVICE_NAME} {start|stop|status}${RESET}"
      ;;
    *)
      warn "Init system '${INIT}' não suportado para criação automática de serviço."
      warn "Execute manualmente: ${CYAN}${script_path}${RESET}"
      ;;
  esac
}

# ─── Parar túnel (sem remover serviço) ───────────────────────────────────────
do_stop() {
  section "Parando o túnel"
  local stopped=false

  case "$INIT" in
    systemd)
      if sudo systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        sudo systemctl stop "$SERVICE_NAME"
        ok "Serviço systemd parado." && stopped=true
      fi
      ;;
    launchd)
      local plist="$HOME/Library/LaunchAgents/com.user.${SERVICE_NAME}.plist"
      if [ -f "$plist" ]; then
        launchctl unload "$plist" 2>/dev/null && ok "LaunchAgent parado." && stopped=true
      fi
      ;;
    openrc)
      if sudo rc-service "$SERVICE_NAME" status &>/dev/null; then
        sudo rc-service "$SERVICE_NAME" stop && ok "Serviço OpenRC parado." && stopped=true
      fi
      ;;
  esac

  local pid_file="/tmp/${SERVICE_NAME}.pid"
  if [ -f "$pid_file" ]; then
    local pid; pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" && ok "Processo do túnel (PID $pid) encerrado." && stopped=true
    fi
    rm -f "$pid_file"
  fi

  pkill -f "autossh.*${VPS_HOST}" 2>/dev/null && ok "Processos autossh encerrados." && stopped=true || true
  pkill -f "ssh.*-R.*${REMOTE_PORT}.*${VPS_HOST}" 2>/dev/null && ok "Processos ssh encerrados." && stopped=true || true

  $stopped || warn "Nenhum túnel ativo encontrado."
}

# ─── Iniciar serviço parado ───────────────────────────────────────────────────
do_start() {
  section "Iniciando o túnel"
  local script_path="$HOME/.local/bin/run-tunnel.sh"
  [ ! -f "$script_path" ] && die "Script do túnel não encontrado. Execute o setup primeiro."

  case "$INIT" in
    systemd)
      [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ] && sudo systemctl start "$SERVICE_NAME" && ok "Serviço systemd iniciado." && return ;;
    launchd)
      local plist="$HOME/Library/LaunchAgents/com.user.${SERVICE_NAME}.plist"
      [ -f "$plist" ] && launchctl load -w "$plist" 2>/dev/null && ok "LaunchAgent iniciado." && return ;;
    openrc)
      [ -f "/etc/init.d/${SERVICE_NAME}" ] && sudo rc-service "$SERVICE_NAME" start && ok "Serviço OpenRC iniciado." && return ;;
  esac

  nohup "$script_path" > /tmp/${SERVICE_NAME}.log 2>&1 &
  echo $! > /tmp/${SERVICE_NAME}.pid
  ok "Túnel iniciado em background (PID: $(cat /tmp/${SERVICE_NAME}.pid))"
  info "Logs: ${CYAN}tail -f /tmp/${SERVICE_NAME}.log${RESET}"
}

# ─── Reiniciar túnel ──────────────────────────────────────────────────────────
do_restart() {
  section "Reiniciando o túnel"

  case "$INIT" in
    systemd)
      [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ] && sudo systemctl restart "$SERVICE_NAME" && ok "Serviço systemd reiniciado." && return ;;
    launchd)
      local plist="$HOME/Library/LaunchAgents/com.user.${SERVICE_NAME}.plist"
      if [ -f "$plist" ]; then launchctl unload "$plist" 2>/dev/null; launchctl load -w "$plist" && ok "LaunchAgent reiniciado." && return; fi ;;
    openrc)
      [ -f "/etc/init.d/${SERVICE_NAME}" ] && sudo rc-service "$SERVICE_NAME" restart && ok "Serviço OpenRC reiniciado." && return ;;
  esac

  do_stop; sleep 2; do_start
}

# ─── Desinstalar serviço ───────────────────────────────────────────────────────
do_uninstall() {
  section "Desinstalando serviço e arquivos"

  do_stop 2>/dev/null || true

  local removed_service=false
  case "$INIT" in
    systemd)
      if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
        sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
        sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        sudo systemctl daemon-reload
        ok "Serviço systemd removido." && removed_service=true
      fi
      ;;
    launchd)
      local plist="$HOME/Library/LaunchAgents/com.user.${SERVICE_NAME}.plist"
      if [ -f "$plist" ]; then
        launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist" && ok "LaunchAgent removido." && removed_service=true
      fi
      ;;
    openrc)
      if [ -f "/etc/init.d/${SERVICE_NAME}" ]; then
        sudo rc-update del "$SERVICE_NAME" default 2>/dev/null || true
        sudo rm -f "/etc/init.d/${SERVICE_NAME}" && ok "Serviço OpenRC removido." && removed_service=true
      fi
      ;;
  esac
  $removed_service || info "Nenhum serviço de sistema encontrado."

  [ -f "$HOME/.local/bin/run-tunnel.sh" ] && rm -f "$HOME/.local/bin/run-tunnel.sh" && ok "Script do túnel removido."
  rm -f "/tmp/${SERVICE_NAME}.pid" "/tmp/${SERVICE_NAME}.log" "/tmp/${SERVICE_NAME}.err"
  ok "Arquivos temporários removidos."
  echo ""
  ok "${BOLD}Desinstalação concluída.${RESET} Túnel removido completamente."
}

# ─── Ver logs do túnel ────────────────────────────────────────────────────────
do_logs() {
  section "Logs do túnel"

  case "$INIT" in
    systemd)
      if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
        info "Últimas 50 linhas (Ctrl+C para sair do follow):"
        echo ""
        sudo journalctl -u "$SERVICE_NAME" -n 50 --no-pager 2>/dev/null && return
      fi
      ;;
  esac

  local log="/tmp/${SERVICE_NAME}.log"
  if [ -f "$log" ]; then
    info "Arquivo: $log"
    echo ""
    tail -50 "$log"
  else
    warn "Nenhum log encontrado."
    info "Systemd: ${CYAN}journalctl -u ${SERVICE_NAME} -f${RESET}"
  fi
}

# ─── Status do serviço ─────────────────────────────────────────────────────────
do_status() {
  section "Status do túnel"

  case "$INIT" in
    systemd)
      sudo systemctl status "$SERVICE_NAME" 2>/dev/null || warn "Serviço não encontrado."
      ;;
    launchd)
      launchctl list | grep "$SERVICE_NAME" || warn "Serviço não encontrado."
      ;;
    openrc)
      sudo rc-service "$SERVICE_NAME" status 2>/dev/null || warn "Serviço não encontrado."
      ;;
  esac

  echo ""
  info "Verificando porta ${REMOTE_PORT} na VPS (${VPS_HOST})..."
  if ssh -o BatchMode=yes -o ConnectTimeout=5 \
      ${KEY_PATH:+-i "$KEY_PATH"} -p "${VPS_PORT}" \
      "${VPS_USER}@${VPS_HOST}" \
      "ss -tlnp | grep :${REMOTE_PORT} && echo 'PORTA ATIVA' || echo 'PORTA INATIVA'" 2>/dev/null; then
    true
  else
    warn "Não foi possível verificar a porta na VPS."
  fi
}

# ─── Menu de gerenciamento interativo ────────────────────────────────────────
show_manage_menu() {
  while true; do
    banner
    section "Gerenciar túnel SSH"
    echo ""

    # Detectar estado atual
    local estado="${RED}inativo${RESET}"
    local tem_servico=false

    case "$INIT" in
      systemd)
        if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
          tem_servico=true
          if sudo systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            estado="${GREEN}ativo (systemd)${RESET}"
          else
            estado="${YELLOW}parado (systemd)${RESET}"
          fi
        fi
        ;;
      launchd)
        if [ -f "$HOME/Library/LaunchAgents/com.user.${SERVICE_NAME}.plist" ]; then
          tem_servico=true
          estado="${YELLOW}instalado (launchd)${RESET}"
        fi
        ;;
      openrc)
        if [ -f "/etc/init.d/${SERVICE_NAME}" ]; then
          tem_servico=true
          estado="${YELLOW}instalado (openrc)${RESET}"
        fi
        ;;
    esac

    [ -f "/tmp/${SERVICE_NAME}.pid" ] && kill -0 "$(cat /tmp/${SERVICE_NAME}.pid)" 2>/dev/null &&       estado="${GREEN}ativo (background)${RESET}"

    echo "  Estado atual: ${BOLD}${estado}${RESET}"
    echo ""
    printf "  ${CYAN}[1]${RESET} %-30s
" "Ver status detalhado"
    printf "  ${CYAN}[2]${RESET} %-30s
" "Ver logs"
    printf "  ${CYAN}[3]${RESET} %-30s
" "Iniciar túnel"
    printf "  ${CYAN}[4]${RESET} %-30s
" "Parar túnel (mantém serviço)"
    printf "  ${CYAN}[5]${RESET} %-30s
" "Reiniciar túnel"
    printf "  ${RED}[6]${RESET} %-30s
" "Desinstalar tudo (serviço + script)"
    printf "  ${CYAN}[0]${RESET} %-30s
" "Sair"
    echo ""
    printf "  ${WHITE}Escolha:${RESET} "
    read -r opcao

    case "$opcao" in
      1) do_status;  echo ""; printf "  Pressione ENTER para continuar..."; read -r ;;
      2) do_logs;    echo ""; printf "  Pressione ENTER para continuar..."; read -r ;;
      3) do_start;   echo ""; printf "  Pressione ENTER para continuar..."; read -r ;;
      4) do_stop;    echo ""; printf "  Pressione ENTER para continuar..."; read -r ;;
      5) do_restart; echo ""; printf "  Pressione ENTER para continuar..."; read -r ;;
      6)
        echo ""
        warn "Isso irá ${BOLD}parar e remover${RESET} o serviço e todos os arquivos do túnel."
        ask_yn "Confirmar desinstalação completa?" "n" confirmed_uninstall
        if $confirmed_uninstall; then
          do_uninstall
          echo ""
          printf "  Pressione ENTER para continuar..."
          read -r
        else
          warn "Cancelado."
        fi
        ;;
      0|q|Q) echo ""; ok "Saindo."; break ;;
      *) warn "Opção inválida: $opcao" ;;
    esac
  done
}

# ─── Uso / ajuda ──────────────────────────────────────────────────────────────────
usage() {
  banner
  echo "  ${BOLD}Uso:${RESET} $0 [opções]"
  echo ""
  echo "  ${BOLD}Flags disponíveis:${RESET}"
  printf "  %-28s %s\n" "${CYAN}--host <IP>${RESET}"        "IP ou hostname da VPS"
  printf "  %-28s %s\n" "${CYAN}--user <user>${RESET}"      "Usuário da VPS (padrão: ubuntu)"
  printf "  %-28s %s\n" "${CYAN}--vps-port <porta>${RESET}" "Porta SSH da VPS (padrão: 22)"
  printf "  %-28s %s\n" "${CYAN}--remote-port <N>${RESET}"  "Porta remota do túnel (padrão: 2222)"
  printf "  %-28s %s\n" "${CYAN}--local-port <N>${RESET}"   "Porta local (padrão: 22)"
  printf "  %-28s %s\n" "${CYAN}--iface <nome>${RESET}"     "Interface de saída (ex: eth0, wlan0)"
  printf "  %-28s %s\n" "${CYAN}--key <caminho>${RESET}"    "Caminho da chave SSH privada"
  printf "  %-28s %s\n" "${CYAN}--no-key${RESET}"           "Usar autenticação por senha"
  printf "  %-28s %s\n" "${CYAN}--persistent${RESET}"       "Ativar persistência (reconexão auto)"
  printf "  %-28s %s\n" "${CYAN}--service${RESET}"          "Criar serviço do sistema (boot)"
  printf "  %-28s %s\n" "${CYAN}--dry-run${RESET}"          "Mostrar config sem executar"
  printf "  %-28s %s\n" "${CYAN}--manage${RESET}"           "Menu interativo de gerenciamento"
  printf "  %-28s %s\n" "${CYAN}--status${RESET}"           "Ver status do túnel/serviço"
  printf "  %-28s %s\n" "${CYAN}--start${RESET}"            "Iniciar o túnel/serviço"
  printf "  %-28s %s\n" "${CYAN}--stop${RESET}"             "Parar o túnel (mantém serviço)"
  printf "  %-28s %s\n" "${CYAN}--restart${RESET}"          "Reiniciar o túnel/serviço"
  printf "  %-28s %s\n" "${CYAN}--logs${RESET}"             "Ver logs do túnel"
  printf "  %-28s %s\n" "${CYAN}--uninstall${RESET}"        "Remover serviço e scripts"
  printf "  %-28s %s\n" "${CYAN}--help${RESET}"             "Exibir esta ajuda"
  echo ""
  echo "  ${BOLD}Exemplos:${RESET}"
  echo "  ${MAGENTA}./tunnel-setup.sh${RESET}                         # modo interativo"
  echo "  ${MAGENTA}./tunnel-setup.sh --host 56.125.45.48 --persistent --service${RESET}"
  echo "  ${MAGENTA}./tunnel-setup.sh --host 1.2.3.4 --key ~/.ssh/id_ed25519 --remote-port 3333${RESET}"
  echo "  ${MAGENTA}./tunnel-setup.sh --manage${RESET}                          # menu de gerenciamento"
  echo "  ${MAGENTA}./tunnel-setup.sh --status${RESET}"
  echo "  ${MAGENTA}./tunnel-setup.sh --stop${RESET}"
  echo "  ${MAGENTA}./tunnel-setup.sh --start${RESET}"
  echo "  ${MAGENTA}./tunnel-setup.sh --restart${RESET}"
  echo "  ${MAGENTA}./tunnel-setup.sh --logs${RESET}"
  echo "  ${MAGENTA}./tunnel-setup.sh --uninstall${RESET}"
  echo ""
  exit 0
}

# ─── Parsear argumentos ───────────────────────────────────────────────────────
INTERACTIVE=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)          VPS_HOST="$2";    shift 2; INTERACTIVE=false ;;
    --user)          VPS_USER="$2";    shift 2 ;;
    --vps-port)      VPS_PORT="$2";    shift 2 ;;
    --remote-port)   REMOTE_PORT="$2"; shift 2 ;;
    --local-port)    LOCAL_PORT="$2";  shift 2 ;;
    --iface)         BIND_IFACE="$2"; shift 2 ;;
    --key)           KEY_PATH="$2";    USE_KEY=true; shift 2; INTERACTIVE=false ;;
    --no-key)        USE_KEY=false;    shift ;;
    --persistent)    PERSISTENT=true;  shift; INTERACTIVE=false ;;
    --service)       CREATE_SERVICE=true; PERSISTENT=true; shift; INTERACTIVE=false ;;
    --dry-run)       DRY_RUN=true;     shift ;;
    --status)        STATUS=true;      INTERACTIVE=false; shift ;;
    --stop)          ACTION="stop";    INTERACTIVE=false; shift ;;
    --start)         ACTION="start";   INTERACTIVE=false; shift ;;
    --restart)       ACTION="restart"; INTERACTIVE=false; shift ;;
    --logs)          ACTION="logs";    INTERACTIVE=false; shift ;;
    --uninstall)     UNINSTALL=true;   INTERACTIVE=false; shift ;;
    --manage)        ACTION="menu";    INTERACTIVE=false; shift ;;
    --help|-h)       usage ;;
    *) error "Opção desconhecida: $1"; usage ;;
  esac
done

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  banner
  detect_os

  # Ações diretas (sem interatividade)
  # Ações diretas por flag
  case "$ACTION" in
    stop)    do_stop;    exit 0 ;;
    start)   do_start;   exit 0 ;;
    restart) do_restart; exit 0 ;;
    logs)    do_logs;    exit 0 ;;
    menu)    show_manage_menu; exit 0 ;;
  esac

  if $UNINSTALL; then
    echo ""
    warn "Isso irá ${BOLD}parar e remover${RESET} o serviço e o script do túnel."
    ask_yn "Confirmar desinstalação completa?" "n" confirmed_uninstall
    $confirmed_uninstall || { warn "Cancelado."; exit 0; }
    do_uninstall
    exit 0
  fi

  if $STATUS; then
    do_status
    exit 0
  fi

  show_checklist
  install_deps

  # Modo interativo: preencher o que estiver faltando
  if $INTERACTIVE || [ -z "$VPS_HOST" ]; then
    configure_tunnel
    configure_key
    configure_persistence
  else
    # Flags: completar valores ausentes com defaults
    [ -z "$KEY_PATH" ] && $USE_KEY && KEY_PATH="$HOME/.ssh/tunnel_key"
    $CREATE_SERVICE && PERSISTENT=true
  fi

  # Configuração final
  section "Configuração final"
  echo "  ${BOLD}VPS:${RESET}          ${VPS_USER}@${VPS_HOST}:${VPS_PORT}"
  local bind_show="${LOCAL_IP:-0.0.0.0}${BIND_IFACE:+ via ${BIND_IFACE}}"
  echo "  ${BOLD}Túnel:${RESET}        :${REMOTE_PORT} (VPS) → ${bind_show}:${LOCAL_PORT}"
  echo "  ${BOLD}Autenticação:${RESET} $(${USE_KEY} && echo "Chave SSH: ${KEY_PATH}" || echo "Senha")"
  echo "  ${BOLD}Persistente:${RESET}  $(${PERSISTENT} && echo "${GREEN}sim${RESET}" || echo "${YELLOW}não (temporário)${RESET}")"
  echo "  ${BOLD}Serviço:${RESET}      $(${CREATE_SERVICE} && echo "${GREEN}sim (${INIT})${RESET}" || echo "${YELLOW}não${RESET}")"
  echo "  ${BOLD}Sistema:${RESET}      ${OS} / ${INIT}"
  echo ""

  if $DRY_RUN; then
    warn "Modo --dry-run: nenhuma alteração foi feita."
    exit 0
  fi

  ask_yn "Confirmar e aplicar configuração?" "y" confirmed
  $confirmed || { warn "Cancelado."; exit 0; }

  section "Gerando script do túnel"
  SCRIPT_PATH=$(generate_tunnel_script)
  ok "Script gerado: ${BOLD}${SCRIPT_PATH}${RESET}"

  if $CREATE_SERVICE; then
    install_service "$SCRIPT_PATH"
  elif $PERSISTENT; then
    # Persistente mas sem serviço formal: rodar em background com nohup
    section "Iniciando túnel em background"
    nohup "$SCRIPT_PATH" > /tmp/${SERVICE_NAME}.log 2>&1 &
    echo $! > /tmp/${SERVICE_NAME}.pid
    ok "Túnel rodando em background (PID: $(cat /tmp/${SERVICE_NAME}.pid))"
    info "Logs: ${CYAN}tail -f /tmp/${SERVICE_NAME}.log${RESET}"
    info "Parar: ${CYAN}kill \$(cat /tmp/${SERVICE_NAME}.pid)${RESET}"
  else
    section "Iniciando túnel (modo temporário)"
    info "Pressione ${BOLD}Ctrl+C${RESET} para encerrar."
    echo ""
    exec "$SCRIPT_PATH"
  fi

  echo ""
  section "Como usar o túnel"
  echo "  De qualquer lugar com internet:"
  echo ""
  echo "  ${CYAN}# Passo 1: conectar na VPS${RESET}"
  echo "  ${MAGENTA}ssh ${VPS_USER}@${VPS_HOST} -p ${VPS_PORT}${RESET}"
  echo ""
  echo "  ${CYAN}# Passo 2: saltar para este host via túnel${RESET}"
  echo "  ${MAGENTA}ssh $(whoami)@localhost -p ${REMOTE_PORT}${RESET}"
  echo ""
  echo "  ${CYAN}# Ou em um único comando (ProxyJump):${RESET}"
  echo "  ${MAGENTA}ssh -J ${VPS_USER}@${VPS_HOST}:${VPS_PORT} $(whoami)@localhost -p ${REMOTE_PORT}${RESET}"
  echo ""
  ok "Configuração concluída."
  echo ""
}

main "$@"
