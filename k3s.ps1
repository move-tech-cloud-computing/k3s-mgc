#Requires -Version 5.1
# k3s.ps1 — Emula mgc kubernetes para clusters K3s na Magalu Cloud
# Move Tech 2026 (Magalu × Prósper Digital Skills)
#
# Uso:
#   .\k3s.ps1 kubernetes cluster create     --name NOME
#   .\k3s.ps1 kubernetes cluster start      --cluster-id ID
#   .\k3s.ps1 kubernetes cluster stop       --cluster-id ID
#   .\k3s.ps1 kubernetes cluster kubeconfig --cluster-id ID --raw > arquivo.yaml
#   .\k3s.ps1 kubernetes cluster list
#   .\k3s.ps1 kubernetes cluster get        --cluster-id ID
#   .\k3s.ps1 kubernetes cluster delete     --cluster-id ID

$ErrorActionPreference = 'Stop'

# ─── Auto-update ──────────────────────────────────────────────────────────────
$SCRIPT_URL = "https://raw.githubusercontent.com/move-tech-cloud-computing/k3s-mgc/main/k3s.ps1"

function Invoke-CheckUpdate {
    try {
        $remote = Invoke-WebRequest -Uri $SCRIPT_URL -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
    } catch { return }

    # Normaliza LF para comparação (GitHub sempre entrega LF)
    $sha256    = [System.Security.Cryptography.SHA256]::Create()
    $localNorm = (Get-Content -Path $PSCommandPath -Raw) -replace "`r`n","`n"
    $localHash = [BitConverter]::ToString($sha256.ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($localNorm))) -replace '-',''
    $remoteNorm = $remote.Content -replace "`r`n","`n"
    $remoteHash = [BitConverter]::ToString($sha256.ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($remoteNorm))) -replace '-',''

    if ($localHash -eq $remoteHash) { Write-Host "✓ Script atualizado." -ForegroundColor Green; return }

    Write-Host ""
    Write-Host "⚠ Uma versão mais recente do script está disponível." -ForegroundColor Yellow
    $upd = Read-Host "  Atualizar agora? [s/N]"
    if ($upd.ToLower() -eq 's') {
        try {
            $remote.Content | Set-Content -Path $PSCommandPath -Encoding UTF8 -NoNewline
            Write-Host "✓ Script atualizado. Rode o comando novamente." -ForegroundColor Green
        } catch {
            Write-Host "✗ Falha ao salvar a atualização: $_" -ForegroundColor Red
        }
        exit 0
    }
    Write-Host ""
}

# ─── Constantes ───────────────────────────────────────────────────────────────
$K3S_DIR      = "$env:USERPROFILE\.k3s-mgc"
$STATE        = "$K3S_DIR\clusters.json"
$SG_NAME      = "sg-k3s"
$MACHINE_TYPE = "BV2-2-40"
$IMAGE_NAME   = "cloud-ubuntu-24.04 LTS"
$VM_USER      = "ubuntu"
$SSH_KEY_NAME = "k3s-cluster"
$SSH_KEY_PATH = "$env:USERPROFILE\.ssh\$SSH_KEY_NAME"

# ─── Saída colorida ───────────────────────────────────────────────────────────
function Write-Ok   { param($msg) Write-Host "✓ $msg" -ForegroundColor Green }
function Write-Info { param($msg) Write-Host "→ $msg" -ForegroundColor Cyan }
function Write-Warn { param($msg) Write-Host "⚠ $msg" -ForegroundColor Yellow }
function Write-Dot  { Write-Host "." -NoNewline -ForegroundColor DarkGray }
function Stop-Script {
    param($msg)
    Write-Host "`n✗ $msg`n" -ForegroundColor Red
    exit 1
}

# ─── mgc wrapper: strip ANSI e converte JSON ──────────────────────────────────
function Invoke-Mgc {
    param([string[]]$MgcArgs)
    $raw = & mgc @MgcArgs --output json 2>$null
    if (-not $raw) { return $null }
    $clean = $raw -replace '\x1b\[[0-9;]*m', ''
    try { return $clean | ConvertFrom-Json }
    catch { return $null }
}

# ─── Estado em JSON ───────────────────────────────────────────────────────────
function Initialize-State {
    if (-not (Test-Path $K3S_DIR)) { New-Item -ItemType Directory -Path $K3S_DIR | Out-Null }
    if (-not (Test-Path $STATE))   { '{}' | Set-Content -Path $STATE -Encoding UTF8 }
}

function Get-State {
    try { return Get-Content $STATE -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return [PSCustomObject]@{} }
}

function Get-ClusterState {
    param([string]$Name)
    $data = Get-State
    if ($data.PSObject.Properties[$Name]) { return $data.$Name }
    return $null
}

function Save-ClusterState {
    param([string]$Name, [string]$VmId, [string]$SgId, [string]$Ip, [string]$SshKey)
    $data = Get-State
    $data | Add-Member -Force -NotePropertyName $Name -NotePropertyValue ([PSCustomObject]@{
        vm_id   = $VmId
        sg_id   = $SgId
        ip      = $Ip
        ssh_key = $SshKey
    })
    $data | ConvertTo-Json -Depth 5 | Set-Content -Path $STATE -Encoding UTF8
}

function Remove-ClusterState {
    param([string]$Name)
    $data = Get-State
    $data.PSObject.Properties.Remove($Name)
    $data | ConvertTo-Json -Depth 5 | Set-Content -Path $STATE -Encoding UTF8
}

function Get-ClusterCount {
    $data = Get-State
    return ($data.PSObject.Properties | Measure-Object).Count
}

function Get-ClusterStateById {
    param([string]$ClusterId)
    $data = Get-State
    foreach ($prop in $data.PSObject.Properties) {
        if ($prop.Value.vm_id -eq $ClusterId) {
            $c = $prop.Value
            $c | Add-Member -Force -NotePropertyName 'name' -NotePropertyValue $prop.Name
            return $c
        }
    }
    return $null
}

# ─── Pré-requisitos ───────────────────────────────────────────────────────────
function Test-Prerequisites {
    foreach ($cmd in @('mgc', 'ssh', 'kubectl')) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            if ($cmd -eq 'kubectl') {
                Write-Warn "kubectl não encontrado. Instale em: https://kubernetes.io/docs/tasks/tools/"
            } else {
                Stop-Script "$cmd não encontrado. Verifique sua instalação."
            }
        }
    }
    $test = Invoke-Mgc @('virtual-machine', 'instances', 'list')
    if (-not $test) { Stop-Script "mgc não autenticado. Execute: mgc auth login" }
}

# ─── Garante chave SSH dedicada ───────────────────────────────────────────────
function Ensure-SshKey {
    # Gera a chave local se não existir
    if (-not (Test-Path $SSH_KEY_PATH)) {
        Write-Info "Gerando chave SSH '$SSH_KEY_NAME'"
        $sshDir = Split-Path $SSH_KEY_PATH
        if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }
        & ssh-keygen -t ed25519 -N '""' -f $SSH_KEY_PATH -C "k3s-mgc" | Out-Null
        Write-Ok "Chave SSH gerada em $SSH_KEY_PATH"
    }

    # Cadastra na MGC se ainda não estiver registrada
    $keys = Invoke-Mgc @('profile', 'ssh-keys', 'list')
    $registered = $keys.results | Where-Object { $_.name -eq $SSH_KEY_NAME }
    if (-not $registered) {
        Write-Info "Cadastrando chave SSH na Magalu Cloud"
        $pubKeyContent = (Get-Content "$SSH_KEY_PATH.pub" -Raw).Trim()
        Invoke-Mgc @('profile', 'ssh-keys', 'create', "--name=$SSH_KEY_NAME", "--key=$pubKeyContent") | Out-Null
        Write-Ok "Chave SSH cadastrada na Magalu Cloud"
    }
}

# ─── SSH helper ───────────────────────────────────────────────────────────────
function Invoke-Ssh {
    param([string]$Ip, [string]$Command)
    & ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes "${VM_USER}@${Ip}" $Command
}

function Wait-Ssh {
    param([string]$Ip)
    Write-Info "Aguardando VM inicializar"
    for ($i = 1; $i -le 60; $i++) {
        $result = & ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes `
            "${VM_USER}@${Ip}" "exit 0" 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Host ""; Write-Ok "VM acessível via SSH"; return }
        Write-Dot
        Start-Sleep -Seconds 5
    }
    Write-Host ""
    Stop-Script "Timeout ao aguardar SSH (300s). Verifique a VM no console da MGC."
}

# ─── Garante Security Group ───────────────────────────────────────────────────
function Ensure-SecurityGroup {
    $sgs = Invoke-Mgc @('network', 'security-groups', 'list')
    $existing = $sgs.security_groups | Where-Object { $_.name -eq $SG_NAME } | Select-Object -First 1
    if ($existing) { return $existing.id }

    Write-Info "Criando Security Group '$SG_NAME'"
    $sg = Invoke-Mgc @('network', 'security-groups', 'create', "--name=$SG_NAME", "--description=K3s — Move Tech")
    if (-not $sg.id) { Stop-Script "Falha ao criar Security Group" }
    $sgId = $sg.id

    foreach ($port in @(22, 8000, 6443)) {
        Invoke-Mgc @('network', 'security-groups', 'rules', 'create',
            "--security-group-id=$sgId", '--direction=ingress', '--ethertype=IPv4',
            '--protocol=tcp', "--port-range-min=$port", "--port-range-max=$port",
            '--remote-ip-prefix=0.0.0.0/0', '--wait') | Out-Null
        Invoke-Mgc @('network', 'security-groups', 'rules', 'create',
            "--security-group-id=$sgId", '--direction=ingress', '--ethertype=IPv6',
            '--protocol=tcp', "--port-range-min=$port", "--port-range-max=$port",
            '--remote-ip-prefix=::/0', '--wait') | Out-Null
    }
    Invoke-Mgc @('network', 'security-groups', 'rules', 'create',
        "--security-group-id=$sgId", '--direction=egress', '--ethertype=IPv4',
        '--protocol=tcp', '--remote-ip-prefix=0.0.0.0/0', '--wait') | Out-Null
    Invoke-Mgc @('network', 'security-groups', 'rules', 'create',
        "--security-group-id=$sgId", '--direction=egress', '--ethertype=IPv6',
        '--protocol=tcp', '--remote-ip-prefix=::/0', '--wait') | Out-Null

    Write-Ok "Security Group criado (portas: 22, 8000, 6443)"
    return $sgId
}

# ─── COMANDO: create ──────────────────────────────────────────────────────────
function Invoke-Create {
    param([string[]]$CmdArgs)

    $name = ''
    for ($i = 0; $i -lt $CmdArgs.Count; $i++) {
        switch ($CmdArgs[$i]) {
            '--name' { $name = $CmdArgs[++$i] }
            default  { if ($CmdArgs[$i] -match '^--name=(.+)') { $name = $Matches[1] } }
        }
    }
    if (-not $name) { Stop-Script "Informe o nome do cluster: --name NOME" }

    Initialize-State
    $vmName = "k3s-cluster"

    Write-Host "`nCriando cluster '$name'" -ForegroundColor White
    Write-Host ("━" * 48)

    Test-Prerequisites

    # Chave SSH dedicada (gerada e cadastrada automaticamente)
    Ensure-SshKey
    Write-Ok "Chave SSH: $SSH_KEY_NAME"

    $sgId = Ensure-SecurityGroup
    Write-Ok "Security Group: $sgId"

    # Recupera estado salvo
    $saved = Get-ClusterState -Name $name
    $vmId  = if ($saved) { $saved.vm_id } else { '' }
    $vmIp  = if ($saved) { $saved.ip }    else { '' }

    # VM: verifica se já existe
    if (-not $vmId) {
        $instances = Invoke-Mgc @('virtual-machine', 'instances', 'list')
        $existing = $instances.instances | Where-Object { $_.name -eq $vmName } | Select-Object -First 1
        if ($existing) { $vmId = $existing.id }
    }

    if ($vmId) {
        Write-Ok "VM já existe (id: $vmId)"
    } else {
        # Verifica IPs públicos órfãos antes de criar
        $pubIps = Invoke-Mgc @('network', 'public-ips', 'list')
        $orphanIps = $pubIps.public_ips | Where-Object { -not $_.port_id -and $_.status -eq 'created' }
        if ($orphanIps.Count -gt 0) {
            Write-Warn "Há $($orphanIps.Count) IP(s) público(s) órfão(s) que podem estar consumindo sua cota."
            Write-Warn "Se a criação falhar por cota de rede, execute:"
            Write-Warn "  .\k3s.ps1 network ip-cleanup"
            Write-Host ""
        }

        $vpcs = Invoke-Mgc @('network', 'vpcs', 'list')
        $vpc = $vpcs.vpcs | Where-Object { $_.name -eq 'vpc_default' } | Select-Object -First 1
        if (-not $vpc) { Stop-Script "vpc_default não encontrada." }

        Write-Info "Criando VM '$vmName' ($MACHINE_TYPE)"
        $sgJson = "[{`"id`":`"$sgId`"}]"
        $vm = Invoke-Mgc @('virtual-machine', 'instances', 'create',
            "--name=$vmName", "--machine-type.name=$MACHINE_TYPE",
            "--image.name=$IMAGE_NAME", "--ssh-key-name=$SSH_KEY_NAME",
            "--network.vpc.id=$($vpc.id)", '--network.associate-public-ip=true',
            "--network.interface.security-groups=$sgJson")
        if (-not $vm.id) { Stop-Script "Falha ao criar VM" }
        $vmId = $vm.id
        Write-Ok "VM criada (id: $vmId)"
        Save-ClusterState -Name $name -VmId $vmId -SgId $sgId -Ip '' -SshKey $SSH_KEY_NAME
    }

    # IP público
    if (-not $vmIp) {
        Write-Info "Aguardando IP público"
        for ($i = 1; $i -le 30; $i++) {
            $vmData = Invoke-Mgc @('virtual-machine', 'instances', 'get', $vmId)
            $ip = $vmData.network.interfaces[0].associated_public_ipv4
            if ($ip) { $vmIp = $ip; break }
            Write-Dot; Start-Sleep -Seconds 5
        }
        Write-Host ""
        if (-not $vmIp) { Stop-Script "IP público não atribuído. Se houver IPs órfãos, execute: .\k3s.ps1 network ip-cleanup" }
        Save-ClusterState -Name $name -VmId $vmId -SgId $sgId -Ip $vmIp -SshKey $SSH_KEY_NAME
    }
    Write-Ok "IP público: $vmIp"

    Wait-Ssh -Ip $vmIp

    # K3s: instala só se ainda não estiver presente
    $k3sCheck = Invoke-Ssh -Ip $vmIp -Command "command -v k3s >/dev/null 2>&1 && echo yes || echo no"
    if ($k3sCheck -eq 'yes') {
        Write-Ok "K3s já instalado"
    } else {
        Write-Info "Instalando K3s"
        Invoke-Ssh -Ip $vmIp -Command "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--tls-san $vmIp' sudo -E sh - 2>&1 | tail -3"
        Write-Ok "K3s instalado"
    }

    # Aguarda K3s Ready
    Write-Info "Aguardando cluster ficar pronto"
    $status = ''
    for ($i = 1; $i -le 24; $i++) {
        $status = Invoke-Ssh -Ip $vmIp -Command "sudo k3s kubectl get nodes --no-headers 2>/dev/null | awk '{print `$2}'" 2>$null
        if ($status -eq 'Ready') { break }
        Write-Dot; Start-Sleep -Seconds 5
    }
    Write-Host ""
    if ($status -ne 'Ready') { Stop-Script "K3s não ficou Ready após 120s." }

    Save-ClusterState -Name $name -VmId $vmId -SgId $sgId -Ip $vmIp -SshKey $SSH_KEY_NAME

    # Kubeconfig → $HOME\.kube\config
    Write-Info "Configurando kubectl"
    $kubeDir = "$env:USERPROFILE\.kube"
    if (-not (Test-Path $kubeDir)) { New-Item -ItemType Directory -Path $kubeDir | Out-Null }
    $kubeconfigPath = "$kubeDir\config"
    $k3sYaml = Invoke-Ssh -Ip $vmIp -Command "sudo cat /etc/rancher/k3s/k3s.yaml"
    ($k3sYaml -replace '127\.0\.0\.1', $vmIp) | Set-Content -Path $kubeconfigPath -Encoding UTF8
    Write-Ok "kubectl configurado ($kubeconfigPath)"

    # ── Container Registry (interativo) ──────────────────────────────────────
    Write-Host ""
    $regAns = Read-Host "  Deseja configurar acesso a um Container Registry? [s/N]"
    if ($regAns.ToLower() -eq 's') {
        Invoke-SetupRegistry
    }

    Write-Host ""
    Write-Host ("━" * 48)
    Write-Host "✓ Cluster '$name' pronto!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Verifique:"
    Write-Host "  kubectl get nodes" -ForegroundColor Cyan
    Write-Host ("━" * 48)
}

# ─── Helper: configurar Container Registry no cluster ────────────────────────
function Invoke-SetupRegistry {
    Write-Info "Buscando Container Registries disponíveis"
    try {
        $regList = Invoke-Mgc @('container-registry', 'registries', 'list')
    } catch {
        Write-Warn "Falha ao listar registries."; return
    }
    $registries = $regList.results

    $regName = ''

    if ($registries -and $registries.Count -gt 0) {
        Write-Host ""
        for ($i = 0; $i -lt $registries.Count; $i++) {
            Write-Host "  [$($i+1)] $($registries[$i].name)"
        }
        Write-Host "  [$($registries.Count+1)] Criar novo registry"
        Write-Host "  [0] Pular"
        Write-Host ""
        $choice = Read-Host "  Escolha"

        if ($choice -eq '0') {
            Write-Warn "Registry não configurado. Para configurar depois: .\k3s.ps1 kubernetes cluster configure-registry --cluster-id ID"
            return
        }

        $choiceInt = [int]$choice
        if ($choiceInt -ge 1 -and $choiceInt -le $registries.Count) {
            $regName = $registries[$choiceInt - 1].name
        } else {
            $regName = Read-Host "  Nome do novo registry"
            if (-not $regName) { Write-Warn "Nome inválido. Pulando."; return }
            Write-Info "Criando registry '$regName'"
            try {
                Invoke-Mgc @('container-registry', 'registries', 'create', "--name=$regName") | Out-Null
                Write-Ok "Registry '$regName' criado"
            } catch {
                Write-Warn "Falha ao criar registry."; return
            }
        }
    } else {
        Write-Host ""
        Write-Host "  Nenhum Container Registry encontrado."
        Write-Host "  [1] Criar novo registry"
        Write-Host "  [0] Pular"
        Write-Host ""
        $choice = Read-Host "  Escolha"
        if ($choice -ne '1') {
            Write-Warn "Registry não configurado. Para configurar depois: .\k3s.ps1 kubernetes cluster configure-registry --cluster-id ID"
            return
        }
        $regName = Read-Host "  Nome do novo registry"
        if (-not $regName) { Write-Warn "Nome inválido. Pulando."; return }
        Write-Info "Criando registry '$regName'"
        try {
            Invoke-Mgc @('container-registry', 'registries', 'create', "--name=$regName") | Out-Null
            Write-Ok "Registry '$regName' criado"
        } catch {
            Write-Warn "Falha ao criar registry."; return
        }
    }

    Write-Info "Obtendo credenciais do Container Registry"
    try {
        $creds = Invoke-Mgc @('container-registry', 'credentials', 'get')
    } catch {
        Write-Warn "Falha ao obter credenciais."; return
    }
    $crUser = $creds.username
    $crPass = $creds.password
    if (-not $crUser -or -not $crPass) { Write-Warn "Credenciais vazias."; return }

    kubectl create secret docker-registry mgc-registry-secret `
        --docker-server="container-registry.br-se1.magalu.cloud" `
        "--docker-username=$crUser" `
        "--docker-password=$crPass" `
        --dry-run=client -o yaml | kubectl apply -f - | Out-Null

    kubectl patch serviceaccount default `
        -p '{"imagePullSecrets": [{"name": "mgc-registry-secret"}]}' | Out-Null

    Write-Ok "Registry '$(if ($regName) { $regName } else { 'container-registry' })' configurado (mgc-registry-secret)"
}

# ─── COMANDO: cluster configure-registry ─────────────────────────────────────
function Invoke-ConfigureRegistry {
    param([string[]]$CmdArgs)

    $clusterId = ''
    for ($i = 0; $i -lt $CmdArgs.Count; $i++) {
        switch ($CmdArgs[$i]) {
            '--cluster-id' { $clusterId = $CmdArgs[++$i] }
            default { if ($CmdArgs[$i] -match '^--cluster-id=(.+)') { $clusterId = $Matches[1] } }
        }
    }
    if (-not $clusterId) { Stop-Script "Informe o ID do cluster: --cluster-id ID" }

    Initialize-State
    $cluster = Get-ClusterStateById -ClusterId $clusterId
    if (-not $cluster) { Stop-Script "Cluster '$clusterId' não encontrado." }

    Invoke-SetupRegistry
}

# ─── COMANDO: kubeconfig ──────────────────────────────────────────────────────
function Invoke-Kubeconfig {
    param([string[]]$CmdArgs)

    $clusterId = ''; $raw = $false
    for ($i = 0; $i -lt $CmdArgs.Count; $i++) {
        switch ($CmdArgs[$i]) {
            '--cluster-id' { $clusterId = $CmdArgs[++$i] }
            '--raw'        { $raw = $true }
            '-r'           { $raw = $true }
            default {
                if ($CmdArgs[$i] -match '^--cluster-id=(.+)') { $clusterId = $Matches[1] }
            }
        }
    }
    if (-not $clusterId) { Stop-Script "Informe o ID do cluster: --cluster-id ID" }

    Initialize-State
    $cluster = Get-ClusterStateById -ClusterId $clusterId
    if (-not $cluster) { Stop-Script "Cluster '$clusterId' não encontrado. Liste com: .\k3s.ps1 kubernetes cluster list" }

    $vmIp = $cluster.ip

    if ($raw) {
        $k3sYaml = Invoke-Ssh -Ip $vmIp -Command "sudo cat /etc/rancher/k3s/k3s.yaml"
        $k3sYaml -replace '127\.0\.0\.1', $vmIp
    } else {
        Stop-Script "Use --raw para obter o kubeconfig:`n  .\k3s.ps1 kubernetes cluster kubeconfig --cluster-id $clusterId --raw > meu-cluster.yaml"
    }
}

# ─── COMANDO: list ────────────────────────────────────────────────────────────
function Invoke-List {
    Initialize-State
    $data = Get-State
    $clusters = $data.PSObject.Properties

    if (-not $clusters) { Write-Host "Nenhum cluster encontrado."; return }

    Write-Host ("{0,-20} {1,-40} {2,-15}" -f "NOME", "ID (--cluster-id)", "IP")
    Write-Host ("{0,-20} {1,-40} {2,-15}" -f ("─" * 20), ("─" * 40), ("─" * 15))
    foreach ($c in $clusters) {
        $ip    = if ($c.Value.ip)    { $c.Value.ip }    else { "—" }
        $vmId  = if ($c.Value.vm_id) { $c.Value.vm_id } else { "—" }
        Write-Host ("{0,-20} {1,-40} {2,-15}" -f $c.Name, $vmId, $ip)
    }
}

# ─── COMANDO: get ─────────────────────────────────────────────────────────────
function Invoke-Get {
    param([string[]]$CmdArgs)

    $clusterId = ''
    for ($i = 0; $i -lt $CmdArgs.Count; $i++) {
        switch ($CmdArgs[$i]) {
            '--cluster-id' { $clusterId = $CmdArgs[++$i] }
            default { if ($CmdArgs[$i] -match '^--cluster-id=(.+)') { $clusterId = $Matches[1] } }
        }
    }
    if (-not $clusterId) { Stop-Script "Informe o ID do cluster: --cluster-id ID" }

    Initialize-State
    $cluster = Get-ClusterStateById -ClusterId $clusterId
    if (-not $cluster) { Stop-Script "Cluster '$clusterId' não encontrado." }

    $name   = $cluster.name
    $vmIp   = $cluster.ip
    $vmId   = $cluster.vm_id
    $sshKey = $cluster.ssh_key

    $k3sVersion = Invoke-Ssh -Ip $vmIp -Command "k3s --version 2>/dev/null | head -1 | awk '{print `$3}'" 2>$null
    $k3sStatus  = Invoke-Ssh -Ip $vmIp -Command "sudo k3s kubectl get nodes --no-headers 2>/dev/null | awk '{print `$2}'" 2>$null

    Write-Host ""
    Write-Host "Cluster: $name" -ForegroundColor White
    Write-Host ("━" * 48)
    Write-Host ("  {0,-18} {1}" -f "Nome:",       $name)
    Write-Host ("  {0,-18} {1}" -f "ID:",         $vmId)
    Write-Host ("  {0,-18} {1}" -f "Status:",     $k3sStatus)
    Write-Host ("  {0,-18} {1}" -f "IP:",         $vmIp)
    Write-Host ("  {0,-18} {1}" -f "Versão K3s:", $k3sVersion)
    Write-Host ("  {0,-18} {1}" -f "Chave SSH:",  $sshKey)
    Write-Host ""
}

# ─── COMANDO: delete ──────────────────────────────────────────────────────────
function Invoke-Delete {
    param([string[]]$CmdArgs)

    $clusterId = ''
    for ($i = 0; $i -lt $CmdArgs.Count; $i++) {
        switch ($CmdArgs[$i]) {
            '--cluster-id' { $clusterId = $CmdArgs[++$i] }
            default { if ($CmdArgs[$i] -match '^--cluster-id=(.+)') { $clusterId = $Matches[1] } }
        }
    }
    if (-not $clusterId) { Stop-Script "Informe o ID do cluster: --cluster-id ID" }

    Initialize-State
    $cluster = Get-ClusterStateById -ClusterId $clusterId
    if (-not $cluster) { Stop-Script "Cluster '$clusterId' não encontrado." }

    $name = $cluster.name
    $vmId = $cluster.vm_id
    $sgId = $cluster.sg_id
    $vmIp = $cluster.ip

    Write-Host "`nDeletando cluster '$name' (VM: $vmIp)" -ForegroundColor Yellow
    $confirm = Read-Host "  Confirmar? [s/N]"
    if ($confirm.ToLower() -ne 's') { Write-Host "Cancelado."; exit 0 }

    Write-Info "Deletando VM ($vmId)"
    Invoke-Mgc @('virtual-machine', 'instances', 'delete', $vmId, '--no-confirm', '--delete-public-ip') | Out-Null
    Write-Ok "VM deletada"

    Remove-ClusterState -Name $name
    $remaining = Get-ClusterCount

    if ($remaining -eq 0) {
        Write-Info "Deletando Security Group (último cluster removido)"
        Invoke-Mgc @('network', 'security-groups', 'delete', "--security-group-id=$sgId", '--no-confirm') | Out-Null
        Write-Ok "Security Group deletado"
    } else {
        Write-Warn "SG mantido — ainda há $remaining cluster(s) usando."
    }

    Write-Ok "Cluster '$name' removido"
}

# ─── COMANDO: stop ────────────────────────────────────────────────────────────
function Invoke-Stop {
    param([string[]]$CmdArgs)

    $clusterId = ''
    for ($i = 0; $i -lt $CmdArgs.Count; $i++) {
        switch ($CmdArgs[$i]) {
            '--cluster-id' { $clusterId = $CmdArgs[++$i] }
            default { if ($CmdArgs[$i] -match '^--cluster-id=(.+)') { $clusterId = $Matches[1] } }
        }
    }
    if (-not $clusterId) { Stop-Script "Informe o ID do cluster: --cluster-id ID" }

    Initialize-State
    $cluster = Get-ClusterStateById -ClusterId $clusterId
    if (-not $cluster) { Stop-Script "Cluster '$clusterId' não encontrado. Liste com: .\k3s.ps1 kubernetes cluster list" }

    $name = $cluster.name
    $vmIp = $cluster.ip

    Write-Info "Parando cluster '$name' ($vmIp)"
    Invoke-Mgc @('virtual-machine', 'instances', 'stop', $clusterId) | Out-Null
    Write-Ok "Cluster '$name' parado"
}

# ─── COMANDO: start ───────────────────────────────────────────────────────────
function Invoke-Start {
    param([string[]]$CmdArgs)

    $clusterId = ''
    for ($i = 0; $i -lt $CmdArgs.Count; $i++) {
        switch ($CmdArgs[$i]) {
            '--cluster-id' { $clusterId = $CmdArgs[++$i] }
            default { if ($CmdArgs[$i] -match '^--cluster-id=(.+)') { $clusterId = $Matches[1] } }
        }
    }
    if (-not $clusterId) { Stop-Script "Informe o ID do cluster: --cluster-id ID" }

    Initialize-State
    $cluster = Get-ClusterStateById -ClusterId $clusterId
    if (-not $cluster) { Stop-Script "Cluster '$clusterId' não encontrado. Liste com: .\k3s.ps1 kubernetes cluster list" }

    $name       = $cluster.name
    $vmIpSaved  = $cluster.ip
    $sgId       = $cluster.sg_id

    Write-Info "Iniciando cluster '$name'"
    Invoke-Mgc @('virtual-machine', 'instances', 'start', $clusterId) | Out-Null
    Write-Ok "VM iniciada"

    # Re-fetch IP (pode ter mudado após stop/start)
    Write-Info "Aguardando IP público"
    $vmIp = ''
    for ($i = 1; $i -le 30; $i++) {
        $vmData = Invoke-Mgc @('virtual-machine', 'instances', 'get', $clusterId)
        $ip = $vmData.network.interfaces[0].associated_public_ipv4
        if ($ip) { $vmIp = $ip; break }
        Write-Dot; Start-Sleep -Seconds 5
    }
    Write-Host ""
    if (-not $vmIp) { Stop-Script "IP público não disponível após iniciar VM." }

    if ($vmIp -ne $vmIpSaved) {
        Save-ClusterState -Name $name -VmId $clusterId -SgId $sgId -Ip $vmIp -SshKey $SSH_KEY_NAME
        Write-Warn "IP público alterado: $vmIpSaved → $vmIp"
    }
    Write-Ok "IP público: $vmIp"

    Wait-Ssh -Ip $vmIp

    # Atualiza kubeconfig com o IP atual
    Write-Info "Atualizando kubectl"
    $kubeDir = "$env:USERPROFILE\.kube"
    if (-not (Test-Path $kubeDir)) { New-Item -ItemType Directory -Path $kubeDir | Out-Null }
    $kubeconfigPath = "$kubeDir\config"
    $k3sYaml = Invoke-Ssh -Ip $vmIp -Command "sudo cat /etc/rancher/k3s/k3s.yaml"
    ($k3sYaml -replace '127\.0\.0\.1', $vmIp) | Set-Content -Path $kubeconfigPath -Encoding UTF8
    Write-Ok "kubectl atualizado ($kubeconfigPath)"

    Write-Host ""
    Write-Host ("━" * 48)
    Write-Host "✓ Cluster '$name' disponível!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  kubectl get nodes" -ForegroundColor Cyan
    Write-Host ("━" * 48)
}

# ─── COMANDO: network ip-cleanup ─────────────────────────────────────────────
function Invoke-IpCleanup {
    Write-Host "`nIPs públicos órfãos" -ForegroundColor White

    $pubIps = Invoke-Mgc @('network', 'public-ips', 'list')
    $orphans = $pubIps.public_ips | Where-Object { -not $_.port_id -and $_.status -eq 'created' }

    if ($orphans.Count -eq 0) {
        Write-Ok "Nenhum IP público órfão encontrado."
        return
    }

    Write-Host ""
    Write-Host "$($orphans.Count) IP(s) público(s) sem VM associada:" -ForegroundColor Yellow
    foreach ($ip in $orphans) {
        Write-Host "  $($ip.public_ip)  (id: $($ip.id))"
    }
    Write-Host ""
    $confirm = Read-Host "  Deletar todos? [s/N]"
    if ($confirm.ToLower() -ne 's') { Write-Host "Cancelado."; return }

    foreach ($ip in $orphans) {
        try {
            Invoke-Mgc @('network', 'public-ips', 'delete', "--public-ip-id=$($ip.id)", '--no-confirm') | Out-Null
            Write-Ok "Deletado: $($ip.id)"
        } catch {
            Write-Warn "Não foi possível deletar $($ip.id) (pode já ter sido liberado)"
        }
    }
}

# ─── Help ─────────────────────────────────────────────────────────────────────
function Show-Help {
    Write-Host ""
    Write-Host "k3s.ps1 — Kubernetes local via K3s na Magalu Cloud" -ForegroundColor White
    Write-Host ""
    Write-Host "Uso:"
    Write-Host "  .\k3s.ps1 kubernetes cluster create     --name NOME" -ForegroundColor Cyan
    Write-Host "  .\k3s.ps1 kubernetes cluster start      --cluster-id ID" -ForegroundColor Cyan
    Write-Host "  .\k3s.ps1 kubernetes cluster stop       --cluster-id ID" -ForegroundColor Cyan
    Write-Host "  .\k3s.ps1 kubernetes cluster kubeconfig --cluster-id ID --raw > arquivo.yaml" -ForegroundColor Cyan
    Write-Host "  .\k3s.ps1 kubernetes cluster list" -ForegroundColor Cyan
    Write-Host "  .\k3s.ps1 kubernetes cluster get        --cluster-id ID" -ForegroundColor Cyan
    Write-Host "  .\k3s.ps1 kubernetes cluster delete              --cluster-id ID" -ForegroundColor Cyan
    Write-Host "  .\k3s.ps1 kubernetes cluster configure-registry  --cluster-id ID" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  .\k3s.ps1 network ip-cleanup   — lista e remove IPs públicos órfãos" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Equivalente aos comandos 'mgc kubernetes cluster ...' do MKS."
    Write-Host "A região utilizada é a configurada no mgc CLI: mgc profile region set"
    Write-Host ""
}

# ─── Router ───────────────────────────────────────────────────────────────────
if ($args.Count -lt 1) { Show-Help; exit 0 }
Invoke-CheckUpdate

$sub = "$($args[0]) $($args[1]) $($args[2])"
$rest = if ($args.Count -gt 3) { $args[3..($args.Count - 1)] } else { @() }

switch -Wildcard ($sub.Trim()) {
    "kubernetes cluster create*"              { Invoke-Create            -CmdArgs $rest }
    "kubernetes cluster configure-registry*" { Invoke-ConfigureRegistry -CmdArgs $rest }
    "kubernetes cluster start*"      { Invoke-Start      -CmdArgs $rest }
    "kubernetes cluster stop*"       { Invoke-Stop       -CmdArgs $rest }
    "kubernetes cluster kubeconfig*" { Invoke-Kubeconfig -CmdArgs $rest }
    "kubernetes cluster list*"       { Invoke-List }
    "kubernetes cluster get*"        { Invoke-Get        -CmdArgs $rest }
    "kubernetes cluster delete*"     { Invoke-Delete     -CmdArgs $rest }
    "network ip-cleanup*"            { Invoke-IpCleanup }
    default                          { Show-Help }
}
