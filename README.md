# 🔒 SSH Reverse Tunnel Setup

Script interativo para criar e gerenciar **túneis SSH reversos** — acesse sua rede local de qualquer lugar do mundo através de uma VPS.

```
Raspberry Pi / Linux / macOS  ──→  VPS (AWS / DigitalOcean)  ←──  Você (remoto)
       túnel reverso saindo                                       ssh na porta 2222
```

---

## Como funciona

O dispositivo local (Rasp, servidor, notebook) abre uma conexão persistente com a sua VPS. Essa conexão cria uma porta na VPS que redireciona o tráfego de volta para o seu dispositivo. Você acessa a VPS de qualquer lugar e, de lá, entra no seu dispositivo como se estivesse na mesma rede.

Não é necessário IP fixo nem abrir portas no roteador — o dispositivo é quem inicia a conexão.

---

## Requisitos

| Dependência | Descrição |
|---|---|
| `bash` ≥ 4.0 | Já presente na maioria dos sistemas |
| `openssh-client` | Cliente SSH |
| `autossh` | Mantém o túnel vivo após quedas |

> O script instala as dependências ausentes automaticamente via `apt`, `pacman`, `apk`, `dnf` ou `brew`.

---

## Sistemas suportados

| Sistema | Distros | Init detectado |
|---|---|---|
| **Debian/Ubuntu** | Ubuntu, Debian, Raspberry Pi OS | systemd |
| **Arch Linux** | Arch, Manjaro | systemd |
| **Alpine Linux** | Alpine | OpenRC |
| **Fedora/RHEL** | Fedora, CentOS, RHEL | systemd |
| **macOS** | macOS 11+ | launchd |

---

## Instalação

```bash
# Clonar o repositório
git clone https://github.com/seu-usuario/ssh-tunnel-setup.git
cd ssh-tunnel-setup

# Dar permissão de execução
chmod +x tunnel-setup.sh

# Rodar
./tunnel-setup.sh
```

---

## Uso

### Modo interativo (recomendado)

Simplesmente rode o script sem argumentos. Ele guia você por cada etapa:

```bash
./tunnel-setup.sh
```

O fluxo cobre:
1. Checklist de dependências (instala o que faltar)
2. IP/usuário/portas da VPS
3. Seleção da interface de rede de saída
4. Configuração da chave SSH (detecta passphrase automaticamente)
5. Escolha de persistência e criação de serviço no boot

---

### Flags disponíveis

| Flag | Descrição |
|---|---|
| `--host <IP>` | IP ou hostname da VPS |
| `--user <user>` | Usuário da VPS (padrão: `ubuntu`) |
| `--vps-port <N>` | Porta SSH da VPS (padrão: `22`) |
| `--remote-port <N>` | Porta do túnel na VPS (padrão: `2222`) |
| `--local-port <N>` | Porta local a encaminhar (padrão: `22`) |
| `--iface <nome>` | Interface de saída (ex: `eth0`, `wlan0`) |
| `--key <caminho>` | Caminho da chave SSH privada |
| `--no-key` | Usar autenticação por senha |
| `--persistent` | Reconectar automaticamente se cair |
| `--service` | Criar serviço do sistema (inicia no boot) |
| `--dry-run` | Mostrar configuração sem aplicar nada |
| `--manage` | Abrir menu interativo de gerenciamento |
| `--status` | Ver status do túnel e serviço |
| `--start` | Iniciar o túnel/serviço |
| `--stop` | Parar o túnel (mantém serviço instalado) |
| `--restart` | Reiniciar o túnel/serviço |
| `--logs` | Ver logs do túnel |
| `--uninstall` | Remover serviço e scripts (pede confirmação) |
| `--help` | Exibir ajuda |

---

### Exemplos

```bash
# Setup completo com serviço no boot
./tunnel-setup.sh --host 56.125.45.48 --persistent --service

# Interface específica + porta remota customizada
./tunnel-setup.sh --host 1.2.3.4 --iface eth0 --remote-port 3333 --service

# Chave SSH específica
./tunnel-setup.sh --host 1.2.3.4 --key ~/.ssh/minha_chave --service

# Testar configuração sem aplicar nada
./tunnel-setup.sh --host 1.2.3.4 --service --dry-run

# Abrir menu de gerenciamento
./tunnel-setup.sh --manage
```

---

## Menu de gerenciamento

Após o setup, rode `./tunnel-setup.sh --manage` a qualquer momento para ver o estado atual e gerenciar o serviço:

```
  Estado atual: ativo (systemd)

  [1] Ver status detalhado
  [2] Ver logs
  [3] Iniciar túnel
  [4] Parar túnel (mantém serviço)
  [5] Reiniciar túnel
  [6] Desinstalar tudo (serviço + script)
  [0] Sair
```

---

## Seleção de interface de rede

O script lista todas as interfaces disponíveis e deixa você escolher por qual o tráfego do túnel vai sair:

```
  Nº    Interface        IP                 Estado   Tipo
  ───   ─────────────    ───────────────    ──────   ────
  [1]   eth0             192.168.1.10       UP       cabeada
  [2]   wlan0            192.168.1.20       UP       Wi-Fi
  [3]   tun0             10.8.0.2           UP       VPN/túnel
  [4]   docker0          172.17.0.1         DOWN     container

  [0]   Todas as interfaces (padrão — recomendado)
```

A opção `[0]` usa `0.0.0.0` e é o comportamento padrão na maioria dos casos.

---

## Chaves SSH com passphrase

O script detecta automaticamente se a chave tem passphrase:

- **Sem passphrase** — ideal para serviços automáticos. O `autossh` autentica direto.
- **Com passphrase** — o script carrega a chave no `ssh-agent` uma vez (você digita a senha), e o agent cuida das reconexões automáticas durante a sessão.

> ⚠️ Chaves com passphrase **não funcionam com serviços no boot** (systemd/launchd), pois não há sessão de usuário ativa para perguntar a senha. Opções:
> ```bash
> # Remover passphrase da chave (mais simples para serviços)
> ssh-keygen -p -f ~/.ssh/tunnel_key -N ""
>
> # Ou criar uma chave separada sem passphrase só para o túnel
> ssh-keygen -t ed25519 -f ~/.ssh/tunnel_key -N ""
> ```

---

## Como acessar de qualquer lugar

Após o setup, acesse seu dispositivo de qualquer rede:

```bash
# Passo 1: conectar na VPS
ssh ubuntu@SEU_IP_DA_VPS

# Passo 2: saltar para o dispositivo via túnel
ssh pi@localhost -p 2222
```

Ou em um único comando com ProxyJump:

```bash
ssh -J ubuntu@SEU_IP_DA_VPS pi@localhost -p 2222
```

Dica: adicione ao seu `~/.ssh/config` para não precisar digitar toda vez:

```sshconfig
Host meu-rasp
  HostName localhost
  User pi
  Port 2222
  ProxyJump ubuntu@SEU_IP_DA_VPS
```

```bash
# Depois é só:
ssh meu-rasp
```

---

## Configuração da VPS

Para o túnel funcionar, a VPS precisa permitir `GatewayPorts` e o encaminhamento de portas. Edite `/etc/ssh/sshd_config` na VPS:

```
GatewayPorts yes
AllowTcpForwarding yes
```

```bash
sudo systemctl restart sshd
```

> Se estiver usando AWS, lembre também de abrir a porta `2222` (ou a que você escolheu) no **Security Group** da instância.

---

## Estrutura gerada pelo script

```
~/.local/bin/run-tunnel.sh        # script do túnel (gerado automaticamente)
/etc/systemd/system/ssh-tunnel.service   # serviço systemd (se --service)
~/Library/LaunchAgents/com.user.ssh-tunnel.plist  # launchd macOS (se --service)
/etc/init.d/ssh-tunnel            # OpenRC Alpine (se --service)
/tmp/ssh-tunnel.log               # log (modo background sem serviço)
/tmp/ssh-tunnel.pid               # PID (modo background sem serviço)
```

---

## Alternativas

Se o objetivo for expor a rede inteira (não só SSH), considere:

| Ferramenta | Vantagem |
|---|---|
| [Tailscale](https://tailscale.com) | Zero config, VPN mesh, acesso a toda a rede |
| [WireGuard](https://www.wireguard.com) | Alta performance, controle total |
| [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) | Expõe serviços web com HTTPS automático |

---

## Licença

MIT — faça o que quiser, sem garantias.
