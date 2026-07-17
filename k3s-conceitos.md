# K3s — Conceitos, Comparação com Kubernetes e Limitações

> **Contexto:** este documento explica o papel do K3s no curso Move Tech, o que ele tem em comum com o Kubernetes gerenciado (MKS da Magalu Cloud), e onde as diferenças importam. Serve tanto para o facilitador quanto para alunos que queiram entender o "porquê" do que estão fazendo.

---

## O que é o K3s

K3s é uma distribuição leve e 100% compatível com o Kubernetes, criada pela Rancher Labs (hoje parte da SUSE). O nome é uma piada interna: se K8s tem 8 letras entre o K e o s, um Kubernetes pela metade teria 5 — mas eles foram além e chegaram em 3.

**O que o K3s empacota em um único binário de ~80 MB:**

| Componente | Papel |
|---|---|
| `k3s server` | API Server, Scheduler, Controller Manager — o cérebro do cluster |
| `containerd` | Runtime de containers (substitui o Docker) |
| `CoreDNS` | DNS interno do cluster |
| `Flannel` | Rede entre pods (CNI) |
| **Klipper ServiceLB** | Implementa `type: LoadBalancer` usando o IP do próprio nó |
| `Traefik` | Ingress Controller padrão |
| `local-path-provisioner` | Persistent Volumes usando disco local |
| `SQLite` / `etcd` | Banco de estado do cluster |

No Kubernetes "cheio" cada um desses componentes é instalado separadamente, configurado separadamente e, num cluster gerenciado (MKS), mantido pela própria cloud. No K3s, tudo vem junto, pronto para rodar com um único comando.

---

## Por que usamos K3s neste curso

O Kubernetes gerenciado da Magalu Cloud (MKS) é o produto de produção. Mas para fins de laboratório ele tem dois problemas: **custo** (um cluster MKS cobra pelo control plane + nós mesmo parado) e **tempo de provisionamento** (~5-10 minutos por cluster).

O K3s resolve isso: instalado em uma VM de R$ ~0,15/hora, fica pronto em menos de 2 minutos. Para um ambiente de aprendizado onde o cluster pode ser criado e destruído múltiplas vezes, faz todo sentido.

**O que importa pedagogicamente:** os manifests YAML que você escreve para o K3s são idênticos aos que você vai usar no MKS. O objetivo do curso é ensinar Kubernetes — não K3s especificamente.

---

## Setup do curso

```
VM: BV2-2-40 (2 vCPU, 2 GB RAM, 40 GB disco)
OS: Ubuntu 24.04 LTS
Rede: vpc_default da Magalu Cloud, IP público associado
Security Group: sg-k3s (porta 22, 8000, 6443)
K3s: single node, --tls-san <IP-DA-VM> para acesso remoto
Registry: MCR via kubectl secret (docker-registry) — igual ao MKS
Service: type: LoadBalancer (Klipper) na porta 8000
```

---

## O que é idêntico entre K3s e Kubernetes (MKS)

Esta é a parte que mais importa: **tudo que você aprende aqui funciona no MKS sem alterações.**

### Manifests YAML

O manifesto que aplicamos no lab:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minha-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minha-api
  template:
    metadata:
      labels:
        app: minha-api
    spec:
      containers:
      - name: minha-api
        image: container-registry.br-se1.magalu.cloud/meu-registry/minha-api:v1
        ports:
        - containerPort: 8000
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 10
          periodSeconds: 15
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 5
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: minha-api
spec:
  type: LoadBalancer
  selector:
    app: minha-api
  ports:
  - port: 8000
    targetPort: 8000
```

**Esse arquivo funciona no MKS sem mudar uma vírgula.**

### Comandos kubectl

Todos os comandos que você usa no K3s funcionam no MKS:

```bash
kubectl apply -f k8s/app.yaml
kubectl get pods
kubectl get pods -w
kubectl get svc
kubectl describe pod NOME
kubectl logs NOME
kubectl logs NOME -f
kubectl logs -l app=minha-api --tail=50
kubectl rollout status deployment/minha-api
kubectl scale deployment minha-api --replicas=3
kubectl delete -f k8s/app.yaml
```

### Conceitos que transferem diretamente

| Conceito | K3s | MKS | Igual? |
|---|---|---|---|
| Deployment | ✅ | ✅ | Idêntico |
| Service (ClusterIP, NodePort, LoadBalancer) | ✅ | ✅ | Idêntico |
| ConfigMap / Secret | ✅ | ✅ | Idêntico |
| Namespace | ✅ | ✅ | Idêntico |
| Liveness / Readiness Probe | ✅ | ✅ | Idêntico |
| Rolling Update | ✅ | ✅ | Idêntico |
| Labels e Selectors | ✅ | ✅ | Idêntico |
| `kubectl rollout status` | ✅ | ✅ | Idêntico |
| `kubectl scale` | ✅ | ✅ | Idêntico |
| Ingress | ✅ (Traefik) | ✅ (configurável) | YAML igual, controller diferente |

---

## O que é diferente

### Load Balancer: Klipper vs. Cloud Load Balancer

Esta é a diferença mais visível no dia a dia.

**No K3s com Klipper:**
```
curl http://201.23.84.164:8000/health

kubectl get svc minha-api
# NAME        TYPE           CLUSTER-IP    EXTERNAL-IP    PORT(S)
# minha-api   LoadBalancer   10.43.x.x     172.18.x.x     8000:xxxxx/TCP
```
- O `EXTERNAL-IP` é o IP **privado** da VM (ex: `172.18.1.241`)
- O acesso externo usa o **IP público da VM** (ex: `201.23.84.164`)
- O IP público e o IP do LoadBalancer são a **mesma máquina**

**No MKS com Cloud Load Balancer:**
```
kubectl get svc minha-api
# NAME        TYPE           CLUSTER-IP    EXTERNAL-IP      PORT(S)
# minha-api   LoadBalancer   10.43.x.x     201.23.76.42     8000:xxxxx/TCP
```
- O `EXTERNAL-IP` é um IP **público dedicado** provisionado pela cloud
- É um balanceador de carga real, **separado dos nós**
- Os nós do cluster ficam em sub-rede privada, sem IP público direto

### Runtime de containers

Ambos usam `containerd` (o Docker foi removido do Kubernetes desde a versão 1.24). Em ambos os casos, a autenticação no registry é feita via Kubernetes Secret do tipo `docker-registry` — a mesma abordagem, o mesmo comando.

### Ingress Controller

| | K3s | MKS |
|---|---|---|
| Default | Traefik 2.x | Configurável (Nginx, Traefik, etc.) |
| Impacto | Traefik ocupa as portas 80/443 do nó | Depende do setup do cluster |

No nosso lab usamos `type: LoadBalancer` diretamente na porta 8000, contornando o Traefik. Em produção com MKS, o padrão é usar Ingress na porta 80/443 com Traefik ou Nginx.

---

## Limitações do nosso setup (K3s single node)

Estas são limitações reais que importam para a tomada de decisão em produção. Elas não invalidam o aprendizado — mas precisam ser conhecidas.

### 1. Sem alta disponibilidade (HA)

**O problema:** toda a aplicação e o próprio Kubernetes rodam na mesma VM. Se a VM cair (manutenção da cloud, falha de hardware, consumo de memória), o cluster inteiro some junto com a aplicação.

**No MKS:** o control plane é gerenciado pela Magalu Cloud com redundância. Os nós de trabalho são VMs separadas — se uma cair, os pods migram para as outras.

### 2. Single Point of Failure no etcd

**O problema:** o banco de estado do cluster (etcd) fica no SQLite local da VM. Não há réplicas. Se o disco corromper, o estado do cluster se perde.

**No MKS:** etcd distribuído e replicado, gerenciado pela cloud com backups automáticos.

### 3. IP público é o IP da VM

**O problema:** o IP da aplicação é o mesmo IP da VM. Se a VM for substituída (upgrade de flavor, recriação após falha), o IP muda e você perde o endpoint.

**No MKS:** o IP do Load Balancer é independente dos nós. Você pode substituir todos os nós sem o IP da aplicação mudar.

### 4. Armazenamento efêmero

**O problema:** o `local-path-provisioner` do K3s cria volumes no disco local da VM. Se a VM for destruída, os dados somem junto.

**No MKS:** integração com Block Storage persistente da Magalu Cloud. Os volumes sobrevivem à substituição de nós.

### 5. Sem auto-scaling de nós

**O problema:** se a carga aumentar além da capacidade da VM (2 vCPU, 2 GB), não há como adicionar nós automaticamente.

**No MKS:** Node Auto-Provisioner pode adicionar e remover nós conforme a demanda.

### 6. Sem RBAC configurado

**O problema:** no curso usamos `sudo kubectl` — ou seja, o usuário `ubuntu` acessa o cluster como root via sudo. Em produção, cada pessoa ou sistema teria sua própria conta com permissões restritas (RBAC).

**No MKS:** integração com IAM da Magalu Cloud e configuração de RBAC por namespace/recurso.

### 7. Gerenciamento manual de atualizações

**O problema:** você é responsável por atualizar o K3s, o Ubuntu e todos os pacotes da VM. Um K3s desatualizado é um risco de segurança.

**No MKS:** a Magalu Cloud gerencia as atualizações do control plane. Updates de nós podem ser automatizados.

### 8. Sem múltiplas zonas de disponibilidade

**O problema:** a VM fica em uma única AZ (`br-se1-a`). Uma falha naquela zona derruba tudo.

**No MKS:** nós distribuídos em múltiplas AZs por padrão.

### 9. Traefik pode conflitar com a aplicação

**O problema:** o Traefik do K3s ocupa as portas 80 e 443 do nó. Se você tentar criar um Service LoadBalancer nessas portas, vai ter conflito.

**Workaround:** usar uma porta diferente (como 8000, que é o que fazemos no curso) ou desabilitar o Traefik na instalação com `--disable traefik`.

---

## Comparativo final

| Aspecto | K3s (curso) | MKS (produção) |
|---|---|---|
| **Custo** | ~R$ 0,15/hora (VM) | Control plane + nós (cobrado separado) |
| **Provisionamento** | ~2 minutos | ~5-10 minutos |
| **Alta disponibilidade** | ❌ Single node | ✅ Multi-master gerenciado |
| **IP do LoadBalancer** | IP da VM (compartilhado) | IP dedicado e estável |
| **Armazenamento** | Disco local (efêmero) | Block Storage persistente |
| **Auto-scaling de nós** | ❌ | ✅ |
| **Atualizações** | Manuais (você) | Gerenciadas (MGC) |
| **Múltiplas AZs** | ❌ | ✅ |
| **RBAC / IAM** | Manual | Integrado com IAM da MGC |
| **Manifests YAML** | ✅ Padrão Kubernetes | ✅ Padrão Kubernetes |
| **kubectl** | ✅ Idêntico | ✅ Idêntico |
| **type: LoadBalancer** | ✅ (Klipper) | ✅ (Cloud LB dedicado) |
| **Adequado para produção** | ⚠️ Apenas cargas pequenas e tolerantes a falha | ✅ |

---

## Quando migrar do K3s para o MKS

Migrar é simples porque os manifests são idênticos. Você precisará migrar quando:

- A aplicação precisar de **alta disponibilidade** (SLA > 99%)
- Precisar de **IP público estável** para o LoadBalancer (independente de VMs)
- A carga exigir **múltiplos nós** com auto-scaling
- Precisar de **armazenamento persistente** via Block Storage
- O ambiente exigir **conformidade** com RBAC e auditoria de acesso

**O processo de migração:**

1. Criar um cluster no MKS da Magalu Cloud
2. Configurar o kubeconfig apontando para o novo cluster
3. Criar um Secret de autenticação para o MCR:
   ```bash
   kubectl create secret docker-registry mcr-credentials \
     --docker-server=container-registry.br-se1.magalu.cloud \
     --docker-username=<usuario> \
     --docker-password=<senha>
   ```
4. Adicionar `imagePullSecrets` ao Deployment (única mudança no manifest)
5. Aplicar o `k8s/app.yaml` — o resto é idêntico

---

## Referências

- [K3s — documentação oficial](https://docs.k3s.io)
- [Klipper ServiceLB](https://github.com/k3s-io/klipper-lb)
- [Kubernetes — tipos de Service](https://kubernetes.io/docs/concepts/services-networking/service/#publishing-services-service-types)
- [MKS — documentação Magalu Cloud](https://docs.magalu.cloud/docs/kubernetes)
