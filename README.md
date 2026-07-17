# k3s — Kubernetes local na Magalu Cloud

Componente Kubernetes simplificado utilizado durante o curso **Move Tech 2026 (Magalu × Prósper Digital Skills)**. Provisiona um cluster **K3s single-node** em uma VM da Magalu Cloud com a mesma interface de linha de comando do MKS (`mgc kubernetes clusters`).

---

## Pré-requisitos

| Ferramenta | macOS / Linux | Windows |
|------------|--------------|---------|
| `mgc cli` | [Veja a documentação oficial](https://docs.magalu.cloud/docs/devops-tools/cli-mgc/how-to/download-and-install) | [Veja a documentação oficial](https://docs.magalu.cloud/docs/devops-tools/cli-mgc/how-to/download-and-install) |
| `ssh` | Já incluso | Já incluso (OpenSSH nativo desde Windows 10) |
| `python3` | Já incluso | Não necessário (`k3s.ps1` usa PowerShell nativo) |
| `kubectl` | [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools/) | [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools/) |

Você também precisa:
- Estar autenticado no `mgc`: `mgc auth login`

> A chave SSH é gerada e cadastrada automaticamente pelo script no primeiro `create`.

---

## Instalação

### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/move-tech-cloud-computing/k3s-mgc/main/k3s.sh -o k3s.sh
chmod +x k3s.sh
```

### Windows (PowerShell)

Abra o PowerShell como administrador e habilite a execução de scripts:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

Baixe o script:

```powershell
Invoke-WebRequest -Uri https://raw.githubusercontent.com/move-tech-cloud-computing/k3s-mgc/main/k3s.ps1 -OutFile k3s.ps1
```

---

## Uso

Os comandos seguem o mesmo padrão do `mgc kubernetes cluster`. Nos exemplos abaixo, use o script correspondente ao seu sistema operacional:

| Sistema | Comando |
|---------|---------|
| macOS / Linux | `./k3s.sh kubernetes cluster ...` |
| Windows | `.\k3s.ps1 kubernetes cluster ...` |

### Criar o cluster

**macOS / Linux**
```bash
./k3s.sh kubernetes cluster create --name meu-cluster
```

**Windows**
```powershell
.\k3s.ps1 kubernetes cluster create --name meu-cluster
```

Ao final (≈5 minutos), o kubectl já está configurado automaticamente. O script também pergunta se você deseja vincular um **Container Registry** — se responder `s`, você pode selecionar um registry existente ou criar um novo, e o secret de acesso é criado automaticamente no cluster.

```
✓ kubectl configurado (/Users/voce/.kube/config)

  Deseja configurar acesso a um Container Registry? [s/N] s

  [1] meu-registry
  [2] Criar novo registry
  [0] Pular
  Escolha: 1

✓ Registry 'meu-registry' configurado (mgc-registry-secret)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✓ Cluster 'meu-cluster' pronto!

  Verifique:
  kubectl get nodes
```

### Parar e iniciar o cluster

Use `stop` para desligar a VM sem destruir o cluster, e `start` para religar:

**macOS / Linux**
```bash
./k3s.sh kubernetes cluster stop  --cluster-id <ID>
./k3s.sh kubernetes cluster start --cluster-id <ID>
```

**Windows**
```powershell
.\k3s.ps1 kubernetes cluster stop  --cluster-id <ID>
.\k3s.ps1 kubernetes cluster start --cluster-id <ID>
```

O `start` aguarda a VM inicializar e atualiza o `~/.kube/config` automaticamente — inclusive se o IP público mudar.

### Configurar acesso ao Container Registry

O acesso ao registry é configurado automaticamente durante o `create` (o script pergunta ao final). Caso queira configurar depois ou em um cluster já existente:

**macOS / Linux**
```bash
./k3s.sh kubernetes cluster configure-registry --cluster-id <ID>
```

**Windows**
```powershell
.\k3s.ps1 kubernetes cluster configure-registry --cluster-id <ID>
```

O comando lista os registries disponíveis na sua conta, permite criar um novo, e configura o secret `mgc-registry-secret` no cluster automaticamente.

### Outros comandos

**macOS / Linux**
```bash
./k3s.sh kubernetes cluster list
./k3s.sh kubernetes cluster get    --cluster-id <ID>
./k3s.sh kubernetes cluster delete --cluster-id <ID>
```

**Windows**
```powershell
.\k3s.ps1 kubernetes cluster list
.\k3s.ps1 kubernetes cluster get    --cluster-id <ID>
.\k3s.ps1 kubernetes cluster delete --cluster-id <ID>
```

### Região

O script usa a região configurada no `mgc` CLI. Para alterá-la:

```bash
mgc profile region set
```

---

## O que acontece por baixo

Quando você roda `create`, o script:

1. Verifica pré-requisitos e autenticação no `mgc`
2. Gera a chave SSH `~/.ssh/k3s-cluster` e cadastra na Magalu Cloud (apenas uma vez)
3. Cria (ou reutiliza) um **Security Group** `sg-k3s` com as portas 22, 8000 e 6443
4. Cria uma **VM** `k3s-cluster` (Ubuntu 24.04, tipo `BV2-2-40`) na `vpc_default`
5. Aguarda SSH ficar disponível
6. Instala o **K3s** via script oficial (`get.k3s.io`)
7. Aguarda o nó ficar `Ready`
8. Salva o kubeconfig em `~/.kube/config` e configura o kubectl automaticamente
9. (Opcional) Pergunta se deseja vincular um Container Registry — se sim, cria o secret `mgc-registry-secret` e atualiza o service account `default`

O script é **idempotente**: se falhar em qualquer etapa, rode novamente — ele detecta o que já foi criado e continua de onde parou.

Quando você roda `delete`, o script remove a VM, o Security Group e a chave SSH da Magalu Cloud.

---

## Comparação com o MKS

| | K3s (este script) | MKS |
|---|---|---|
| `create` | `./k3s.sh kubernetes cluster create --name <NOME>` | `mgc kubernetes cluster create` |
| `start` | `./k3s.sh kubernetes cluster start --cluster-id <ID>` | `mgc kubernetes cluster start` |
| `stop` | `./k3s.sh kubernetes cluster stop --cluster-id <ID>` | `mgc kubernetes cluster stop` |
| `delete` | `./k3s.sh kubernetes cluster delete --cluster-id <ID>` | `mgc kubernetes cluster delete` |
| kubeconfig | Configurado automaticamente em `~/.kube/config` | `mgc kubernetes cluster kubeconfig` |
| Nós | 1 (single-node) | Multi-node gerenciado |
| Custo | Apenas a VM | Serviço gerenciado |
| Alta disponibilidade | Não | Sim |

---

## Estado local

O script mantém um arquivo de estado com os IDs dos recursos criados. Se precisar inspecionar ou limpar manualmente:

**macOS / Linux**
```bash
cat ~/.k3s-mgc/clusters.json          # ver estado atual
echo '{}' > ~/.k3s-mgc/clusters.json  # limpar
```

**Windows**
```powershell
Get-Content "$env:USERPROFILE\.k3s-mgc\clusters.json"        # ver estado atual
'{}' | Set-Content "$env:USERPROFILE\.k3s-mgc\clusters.json" # limpar
```

---

*Parte do curso [Move Tech 2026](https://github.com/move-tech-cloud-computing) — Magalu × Prósper Digital Skills*
