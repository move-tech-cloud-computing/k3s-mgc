# k3s — Kubernetes local na Magalu Cloud

Componente Kubernetes simplificado utilizado durante o curso **Move Tech 2026 (Magalu × Prósper Digital Skills)**. Provisiona um cluster **K3s single-node** em uma VM da Magalu Cloud com a mesma interface de linha de comando do MKS (`mgc kubernetes clusters`).

---

## Pré-requisitos

| Ferramenta | Instalação |
|------------|-----------|
| `mgc cli` | [Veja a documentação oficial](https://docs.magalu.cloud/docs/devops-tools/cli-mgc/how-to/download-and-install) |
| `ssh` | Já incluso no macOS e Linux |
| `python3` | Já incluso no macOS e Linux |
| `kubectl` | [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools/) |

Você também precisa:
- Estar autenticado no `mgc`: `mgc auth login`

> A chave SSH é gerada e cadastrada automaticamente pelo script no primeiro `create`.

---

## Instalação

```bash
curl -fsSL https://raw.githubusercontent.com/move-tech-cloud-computing/k3s-mgc/main/k3s.sh -o ~/k3s.sh
chmod +x ~/k3s.sh
```

> **Usuários Windows:** o script requer um ambiente Linux. Veja as [alternativas para Windows](#windows) abaixo.

---

## Uso

Os comandos seguem o mesmo padrão do `mgc kubernetes cluster`:

### Criar o cluster

```bash
~/k3s.sh kubernetes cluster create
```

O script coleta três informações antes de provisionar:

**1. Nome do cluster**
```
  Nome do cluster: meu-cluster
```

**2. Tipo de VM**
```
  → Selecione o tipo de VM:

    [1] BV1-1-10   —  1 vCPU    1 GB RAM   10 GB
    [2] BV1-2-10   —  1 vCPU    2 GB RAM   10 GB
    [3] BV2-2-10   —  2 vCPUs   2 GB RAM   10 GB
    [4] BV1-4-10   —  1 vCPU    4 GB RAM   10 GB   (recomendado)
    [5] BV2-4-10   —  2 vCPUs   4 GB RAM   10 GB

  Escolha [padrão 4]:
```

A partir daí o script provisiona a VM, instala o K3s e configura o kubectl automaticamente (≈5 minutos).

**3. Container Registry (opcional)**

Ao final, o script pergunta se você deseja vincular um registry. Se responder `s`, pode selecionar um existente ou criar um novo — o secret de acesso é criado automaticamente no cluster.

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
```

### Parar e iniciar o cluster

Use `stop` para desligar a VM sem destruir o cluster, e `start` para religar:

```bash
~/k3s.sh kubernetes cluster stop  --cluster-id <ID>
~/k3s.sh kubernetes cluster start --cluster-id <ID>
```

O `start` aguarda a VM inicializar e atualiza o `~/.kube/config` automaticamente — inclusive se o IP público mudar.

### Diagnosticar o cluster

Exibe o estado detalhado do cluster em três seções: **Recursos**, **Conectividade** e **Kubernetes**.

```bash
# Todos os clusters
~/k3s.sh kubernetes cluster diagnose

# Cluster específico
~/k3s.sh kubernetes cluster diagnose --cluster-id <ID>
```

```
┌ Diagnóstico do cluster 'meu-cluster'

  Recursos
  ✓ Virtual Machine
    ✓ Estado                 ligada
    ✓ IP Público             201.23.85.63

  Conectividade
  ✓ SSH
    ✓ Chave                  sincronizada
    ✓ Grupo de Segurança     porta 22 aberta
    ✓ Conexão                autenticada
  ✓ kubectl
    ✓ Kubeconfig             configurado
    ✓ Grupo de Segurança     porta 6443 aberta
    ✓ Conexão                API Server respondendo

  Kubernetes
  ✓ Cluster K3s
    ✓ Node                   Ready
    ✓ Traefik                desabilitado
    ✓ Container Registry
      ✓ Secret               mgc-registry-secret presente
      ✓ Service Account      imagePullSecrets configurado
```

### Corrigir o cluster

Verifica cada ponto do diagnóstico e corrige automaticamente o que estiver com problema — sem tocar no que já está funcionando.

```bash
# Todos os clusters
~/k3s.sh kubernetes cluster fix

# Cluster específico
~/k3s.sh kubernetes cluster fix --cluster-id <ID>
```

Correções cobertas automaticamente:

| Problema | Ação |
|----------|------|
| VM desligada | Liga e aguarda estado running |
| IP público ausente | Menu interativo para vincular IP livre ou criar novo |
| Security Group bloqueado | Adiciona regras de acesso para as portas 22 e 6443 |
| Chave SSH fora de sincronia | Recadastra no MGC |
| SSH inacessível | Recovery via snapshot, preservando o IP público |
| Traefik ativo | Desabilita e reinicia K3s |
| Kubeconfig inválido | Reconfigura `~/.kube/config` |
| K3s node não Ready | Reinicia o serviço e aguarda Ready |
| Registry/Secret/SA ausentes | Reconfigura somente o que está faltando |

### Configurar acesso ao Container Registry

O acesso ao registry é configurado automaticamente durante o `create`. Caso queira configurar depois ou em um cluster já existente:

```bash
~/k3s.sh kubernetes cluster configure-registry --cluster-id <ID>
```

### Outros comandos

```bash
~/k3s.sh kubernetes cluster list
~/k3s.sh kubernetes cluster get    --cluster-id <ID>
~/k3s.sh kubernetes cluster delete --cluster-id <ID>
~/k3s.sh network ip-cleanup
```

### Região

O script usa a região configurada no `mgc` CLI. Para alterá-la:

```bash
mgc profile region set
```

---

## Windows

O script requer bash e ferramentas Linux (`ssh`, `python3`, `nc`). No Windows, há duas formas de rodar:

### Opção 1 — VM Linux na Magalu Cloud (recomendado)

Crie uma VM Ubuntu na Magalu Cloud e execute o script a partir dela. Todos os pré-requisitos já estão disponíveis por padrão.

### Opção 2 — WSL2

Com o WSL2 instalado, abra um terminal Ubuntu e siga as instruções de instalação normalmente:

```bash
# Dentro do terminal WSL2
curl -fsSL https://raw.githubusercontent.com/move-tech-cloud-computing/k3s-mgc/main/k3s.sh -o ~/k3s.sh
chmod +x ~/k3s.sh
```

Para instalar o WSL2: [learn.microsoft.com/windows/wsl/install](https://learn.microsoft.com/pt-br/windows/wsl/install)

---

## O que acontece por baixo

Quando você roda `create`, o script:

1. Verifica pré-requisitos e autenticação no `mgc`
2. Gera a chave SSH `~/.ssh/ssh-k3s-cluster` e cadastra na Magalu Cloud (apenas uma vez)
3. Cria (ou reutiliza) um **Security Group** `sg-k3s-cluster` com as portas 22 e 6443
4. Cria uma **VM** na `vpc_default` com o tipo escolhido interativamente
5. Aguarda SSH ficar disponível
6. Instala o **K3s** via script oficial (`get.k3s.io`) com Traefik desabilitado
7. Aguarda o nó ficar `Ready`
8. Salva o kubeconfig em `~/.kube/config` e configura o kubectl automaticamente
9. (Opcional) Pergunta se deseja vincular um Container Registry — se sim, cria o secret `mgc-registry-secret` e atualiza o service account `default`

---

## Comparação com o MKS

| | K3s (este script) | MKS |
|---|---|---|
| `create` | `~/k3s.sh kubernetes cluster create` | `mgc kubernetes cluster create` |
| `start` | `~/k3s.sh kubernetes cluster start --cluster-id <ID>` | `mgc kubernetes cluster start` |
| `stop` | `~/k3s.sh kubernetes cluster stop --cluster-id <ID>` | `mgc kubernetes cluster stop` |
| `delete` | `~/k3s.sh kubernetes cluster delete --cluster-id <ID>` | `mgc kubernetes cluster delete` |
| `diagnose` | `~/k3s.sh kubernetes cluster diagnose --cluster-id <ID>` | — |
| `fix` | `~/k3s.sh kubernetes cluster fix --cluster-id <ID>` | — |
| kubeconfig | Configurado automaticamente em `~/.kube/config` | `mgc kubernetes cluster kubeconfig` |
| Nós | 1 (single-node) | Multi-node gerenciado |
| Custo | Apenas a VM | Serviço gerenciado |
| Alta disponibilidade | Não | Sim |

---

*Parte do curso [Move Tech 2026](https://github.com/move-tech-cloud-computing) — Magalu × Prósper Digital Skills*
