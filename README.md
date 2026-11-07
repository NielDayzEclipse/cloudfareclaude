# Claude Code + Proxmox MCP (LXC)

Cria um container LXC no Proxmox com o **Claude Code** já conectado à API do Proxmox
pelo servidor MCP [mcp-proxmox](https://github.com/gilby125/mcp-proxmox).
Nada fica exposto na internet: tudo roda dentro da sua rede.

## Instalação

No **Shell do nó Proxmox** (como root):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/NielDayzEclipse/cloudfareclaude/main/claude-proxmox-lxc.sh)"
```

> O comando acima só funciona com o repositório **público**. Se ele for privado, copie o
> `claude-proxmox-lxc.sh` para o Proxmox e rode `bash claude-proxmox-lxc.sh`.

O script pergunta:
- **Nível de acesso:** somente leitura (recomendado) ou controle de VMs (ligar/desligar/reiniciar/snapshots)
- **Senha de root** do novo container

## O que ele faz

1. Cria o usuário `claude-mcp@pve` e um token de API com *Privilege Separation* e papel limitado
   (`PVEAuditor`, ou `PVEAuditor,PVEVMUser` no modo controle)
2. Cria um LXC Debian 13 sem privilégios (2 CPU, 2 GB RAM, 8 GB disco, liga com o servidor)
3. Instala Node.js, o `mcp-proxmox` e o Claude Code
4. Registra o MCP no Claude Code com o token (o segredo não precisa ser copiado à mão)
5. Cria um `/root/CLAUDE.md` pedindo respostas em português e confirmação antes de ações que alterem algo

## Uso

```bash
pct enter <ID>          # ou: ssh root@<IP-do-container>
cd /root && claude
```

No primeiro uso, faça login com sua conta Claude. Depois digite `/mcp` para confirmar que o `proxmox` está conectado.

## Opções

| Variável | Padrão | Descrição |
|---|---|---|
| `CT_STORAGE` | `local-lvm` | Storage do disco do container |
| `TMPL_STORAGE` | `local` | Storage dos templates |

Exemplo: `CT_STORAGE=local-zfs bash claude-proxmox-lxc.sh`

Para trocar a bridge (padrão `vmbr0`) ou os recursos, edite as variáveis no topo do script.

## Rodar de novo

Rodar o script outra vez cria um **novo** container e **recria** o token (o antigo deixa de funcionar).
