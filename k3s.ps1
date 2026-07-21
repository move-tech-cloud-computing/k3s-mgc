#Requires -Version 5.1
# k3s.ps1 — Emula mgc kubernetes para clusters K3s na Magalu Cloud
# Move Tech 2026 (Magalu × Prósper Digital Skills)
#
# Uso:
#   .\k3s.ps1 kubernetes cluster create              --name NOME
#   .\k3s.ps1 kubernetes cluster start               --cluster-id ID
#   .\k3s.ps1 kubernetes cluster stop                --cluster-id ID
#   .\k3s.ps1 kubernetes cluster kubeconfig          --cluster-id ID --raw > arquivo.yaml
#   .\k3s.ps1 kubernetes cluster list
#   .\k3s.ps1 kubernetes cluster get                 --cluster-id ID
#   .\k3s.ps1 kubernetes cluster delete              --cluster-id ID
#   .\k3s.ps1 kubernetes cluster configure-registry  --cluster-id ID

$ErrorActionPreference = 'Stop'

# ─── Auto-update ──────────────────────────────────────────────────────────────
$SCRIPT_URL = "https://raw.githubusercontent.com/move-tech-cloud-computing/k3s-mgc/main/k3s.ps1"

function Invoke-CheckUpdate {
    try {
        $remote = Invoke-WebRequest -Uri $SCRIPT_URL -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
    } catch { return }

    $sha256    = [System.Security.Cryptography.SHA256]::Create()
    $localNorm = (Get-Content -Path $PSCommandPath -Raw) -replace "`r`n","`n"
    $localHash = [BitConverter]::ToString($sha256.ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($localNorm))) -replace '-',''
    $remoteNorm = $remote.Content -replace "`r`n","`n"
    $remoteHash = [BitConverter]::ToString($sha256.ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($remoteNorm))) -replace '-',''

    if ($localHash -eq $remoteHash) { return }

    Write-Host ""
    Write-Host "⚠ Uma versão mais recente do script está disponível." -ForegroundColor Yellow
    $upd = if ([Environment]::UserInteractive) { Read-Host "  Atualizar agora? [s/N]" } else { 'n' }
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
$SG_NAME      = "sg-k3s-cluster"
$MACHINE_TYPE = "BV2-2-40"
$IMAGE_NAME   = "cloud-ubuntu-24.04 LTS"
$VM_USER      = "ubuntu"
$SSH_KEY_NAME = "ssh-k3s-cluster"
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

# ─── Lookups de cluster via API ───────────────────────────────────────────────

function Get-ClusterById {
    param([string]$ClusterId)
    try {
        $vm = Invoke-Mgc @('virtual-machine', 'instances', 'get', $ClusterId)
    } catch { return $null }
    if (-not $vm -or -not $vm.name.StartsWith('vm-k3s-cluster-')) { return $null }
    $ip = ''
    if ($vm.network.interfaces -and $vm.network.interfaces.Count -gt 0) {
        $ip = $vm.network.interfaces[0].associated_public_ipv4
    }
    return [PSCustomObject]@{
        vm_id = $ClusterId
        name  = $vm.name.Substring('vm-k3s-cluster-'.Length)
        ip    = $ip
    }
}

function Get-AllClusters {
    $instances = Invoke-Mgc @('virtual-machine', 'instances', 'list')
    if (-not $instances) { return @() }
    return $instances.instances | Where-Object { $_.name -like 'vm-k3s-cluster-*' } | ForEach-Object {
        $ip = if ($_.network.interfaces -and $_.network.interfaces.Count -gt 0) {
            $_.network.interfaces[0].associated_public_ipv4
        } else { '—' }
        [PSCustomObject]@{
            vm_id = $_.id
            name  = $_.name.Substring('vm-k3s-cluster-'.Length)
            ip    = $ip
        }
    }
}

function Get-ClusterCountExcept {
    param([string]$ExcludeId)
    $instances = Invoke-Mgc @('virtual-machine', 'instances', 'list')
    if (-not $instances) { return 0 }
    return ($instances.instances | Where-Object {
        $_.name -like 'vm-k3s-cluster-*' -and $_.id -ne $ExcludeId
    } | Measure-Object).Count
}

function Get-SgId {
    $sgs = Invoke-Mgc @('network', 'security-groups', 'list')
    $match = $sgs.security_groups | Where-Object { $_.name -eq $SG_NAME } | Select-Object -First 1
    return if ($match) { $match.id } else { '' }
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
    if (-not (Test-Path $SSH_KEY_PATH)) {
        Write-Info "Gerando chave SSH '$SSH_KEY_NAME'"
        $sshDir = Split-Path $SSH_KEY_PATH
        if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }
        & ssh-keygen -t ed25519 -N '""' -f $SSH_KEY_PATH -C "k3s-mgc" | Out-Null
        Write-Ok "Chave SSH gerada em $SSH_KEY_PATH"
    }

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
    $existing = Get-SgId
    if ($existing) {
        Write-Ok "Security Group: $SG_NAME ($existing)"
        return $existing
    }

    Write-Info "Criando Security Group '$SG_NAME'"
    $sg = Invoke-Mgc @('network', 'security-groups', 'create', "--name=$SG_NAME", "--description=K3s — Move Tech")
    if (-not $sg.id) { Stop-Script "Falha ao criar Security Group" }
    $sgId = $sg.id

    foreach ($port in @(22, 80, 8000, 6443)) {
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

    Write-Ok "Security Group criado (portas: 22, 80, 8000, 6443)"
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

    $vmName = "vm-k3s-cluster-$name"

    Write-Host "`nCriando cluster '$name'" -ForegroundColor White
    Write-Host ("━" * 48)

    Test-Prerequisites
    Ensure-SshKey
    $sgId = Ensure-SecurityGroup

    # VM: verifica se já existe pelo nome
    $instances = Invoke-Mgc @('virtual-machine', 'instances', 'list')
    $existing = $instances.instances | Where-Object { $_.name -eq $vmName } | Select-Object -First 1
    $vmId = if ($existing) { $existing.id } else { '' }

    if ($vmId) {
        Write-Ok "VM já existe ($vmName)"
    } else {
        $pubIps = Invoke-Mgc @('network', 'public-ips', 'list')
        $orphanIps = $pubIps.public_ips | Where-Object { -not $_.port_id -and $_.status -eq 'created' }
        if ($orphanIps.Count -gt 0) {
            Write-Warn "Há $($orphanIps.Count) IP(s) público(s) órfão(s). Se a criação falhar por cota, execute: .\k3s.ps1 network ip-cleanup"
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
    }

    # IP público
    Write-Info "Aguardando IP público"
    $vmIp = ''
    for ($i = 1; $i -le 30; $i++) {
        $vmData = Invoke-Mgc @('virtual-machine', 'instances', 'get', $vmId)
        $ip = $vmData.network.interfaces[0].associated_public_ipv4
        if ($ip) { $vmIp = $ip; break }
        Write-Dot; Start-Sleep -Seconds 5
    }
    Write-Host ""
    if (-not $vmIp) { Stop-Script "IP público não atribuído. Se houver IPs órfãos, execute: .\k3s.ps1 network ip-cleanup" }
    Write-Ok "IP público: $vmIp"

    Wait-Ssh -Ip $vmIp

    # K3s
    $k3sCheck = Invoke-Ssh -Ip $vmIp -Command "command -v k3s >/dev/null 2>&1 && echo yes || echo no"
    if ($k3sCheck -eq 'yes') {
        Write-Ok "K3s já instalado"
    } else {
        Write-Info "Instalando K3s"
        Invoke-Ssh -Ip $vmIp -Command "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--tls-san $vmIp --disable=traefik --node-external-ip=$vmIp' sudo -E sh - 2>&1 | tail -3"
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

    # Kubeconfig
    Write-Info "Configurando kubectl"
    $kubeDir = "$env:USERPROFILE\.kube"
    if (-not (Test-Path $kubeDir)) { New-Item -ItemType Directory -Path $kubeDir | Out-Null }
    $kubeconfigPath = "$kubeDir\config"
    $k3sYaml = Invoke-Ssh -Ip $vmIp -Command "sudo cat /etc/rancher/k3s/k3s.yaml"
    ($k3sYaml -replace '127\.0\.0\.1', $vmIp) | Set-Content -Path $kubeconfigPath -Encoding UTF8
    Write-Ok "kubectl configurado ($kubeconfigPath)"

    if ([Environment]::UserInteractive) {
        Write-Host ""
        $regAns = Read-Host "  Deseja configurar acesso a um Container Registry? [s/N]"
        if ($regAns.ToLower() -eq 's') {
            Invoke-SetupRegistry
        }
    }

    Write-Host ""
    Write-Host ("━" * 48)
    Write-Host "✓ Cluster '$name' pronto!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  ID do cluster: $vmId" -ForegroundColor White
    Write-Host "  Verificar:     kubectl get nodes" -ForegroundColor Cyan
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

    $cluster = Get-ClusterById -ClusterId $clusterId
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

    $cluster = Get-ClusterById -ClusterId $clusterId
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
    $clusters = Get-AllClusters

    if (-not $clusters -or @($clusters).Count -eq 0) {
        Write-Host "Nenhum cluster encontrado."
        return
    }

    Write-Host ("{0,-20} {1,-40} {2,-15}" -f "NOME", "ID (--cluster-id)", "IP")
    Write-Host ("{0,-20} {1,-40} {2,-15}" -f ("─" * 20), ("─" * 40), ("─" * 15))
    foreach ($c in $clusters) {
        $ip   = if ($c.ip)    { $c.ip }    else { "—" }
        $vmId = if ($c.vm_id) { $c.vm_id } else { "—" }
        Write-Host ("{0,-20} {1,-40} {2,-15}" -f $c.name, $vmId, $ip)
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

    $cluster = Get-ClusterById -ClusterId $clusterId
    if (-not $cluster) { Stop-Script "Cluster '$clusterId' não encontrado." }

    $name = $cluster.name
    $vmIp = $cluster.ip

    $k3sVersion = Invoke-Ssh -Ip $vmIp -Command "k3s --version 2>/dev/null | head -1 | awk '{print `$3}'" 2>$null
    $k3sStatus  = Invoke-Ssh -Ip $vmIp -Command "sudo k3s kubectl get nodes --no-headers 2>/dev/null | awk '{print `$2}'" 2>$null

    Write-Host ""
    Write-Host "Cluster: $name" -ForegroundColor White
    Write-Host ("━" * 48)
    Write-Host ("  {0,-18} {1}" -f "Nome:",       $name)
    Write-Host ("  {0,-18} {1}" -f "ID:",         $clusterId)
    Write-Host ("  {0,-18} {1}" -f "Status:",     $k3sStatus)
    Write-Host ("  {0,-18} {1}" -f "IP:",         $vmIp)
    Write-Host ("  {0,-18} {1}" -f "Versão K3s:", $k3sVersion)
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

    $cluster = Get-ClusterById -ClusterId $clusterId
    if (-not $cluster) { Stop-Script "Cluster '$clusterId' não encontrado." }

    $name = $cluster.name
    $vmIp = $cluster.ip

    Write-Host "`nDeletando cluster '$name' ($vmIp)" -ForegroundColor Yellow
    $confirm = if ([Environment]::UserInteractive) { Read-Host "  Confirmar? [s/N]" } else { 'n' }
    if ($confirm.ToLower() -ne 's') { Write-Host "Cancelado."; exit 0 }

    Write-Info "Deletando VM"
    Invoke-Mgc @('virtual-machine', 'instances', 'delete', $clusterId, '--no-confirm', '--delete-public-ip') | Out-Null
    Write-Ok "VM deletada"

    $remaining = Get-ClusterCountExcept -ExcludeId $clusterId

    if ($remaining -eq 0) {
        $sgId = Get-SgId
        if ($sgId) {
            Write-Info "Deletando Security Group (último cluster removido)"
            try {
                Invoke-Mgc @('network', 'security-groups', 'delete', "--security-group-id=$sgId", '--no-confirm') | Out-Null
                Write-Ok "Security Group deletado"
            } catch {
                Write-Warn "Falha ao deletar Security Group (pode já ter sido removido)"
            }
        }
    } else {
        Write-Warn "Security Group mantido — ainda há $remaining cluster(s) usando."
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

    $cluster = Get-ClusterById -ClusterId $clusterId
    if (-not $cluster) { Stop-Script "Cluster '$clusterId' não encontrado. Liste com: .\k3s.ps1 kubernetes cluster list" }

    Write-Info "Parando cluster '$($cluster.name)'"
    Invoke-Mgc @('virtual-machine', 'instances', 'stop', $clusterId) | Out-Null
    Write-Ok "Cluster '$($cluster.name)' parado"
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

    $cluster = Get-ClusterById -ClusterId $clusterId
    if (-not $cluster) { Stop-Script "Cluster '$clusterId' não encontrado. Liste com: .\k3s.ps1 kubernetes cluster list" }

    $name      = $cluster.name
    $vmIpAntes = $cluster.ip

    Write-Info "Iniciando cluster '$name'"
    Invoke-Mgc @('virtual-machine', 'instances', 'start', $clusterId) | Out-Null
    Write-Ok "VM iniciada"

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

    if ($vmIp -ne $vmIpAntes) {
        Write-Warn "IP público alterado: $vmIpAntes → $vmIp"
    }
    Write-Ok "IP público: $vmIp"

    Wait-Ssh -Ip $vmIp

    # Atualiza node-external-ip no K3s se o IP mudou
    if ($vmIp -ne $vmIpAntes) {
        Write-Info "Atualizando IP externo no K3s"
        try {
            Invoke-Ssh -Ip $vmIp -Command "printf 'node-external-ip: $vmIp\ndisable:\n  - traefik\n' | sudo tee /etc/rancher/k3s/config.yaml >/dev/null && sudo systemctl restart k3s"
            Start-Sleep -Seconds 5
            Write-Ok "IP externo atualizado"
        } catch {
            Write-Warn "Não foi possível atualizar node-external-ip (continue manualmente se necessário)"
        }
    }

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
    Write-Host "  .\k3s.ps1 kubernetes cluster create              --name NOME" -ForegroundColor Cyan
    Write-Host "  .\k3s.ps1 kubernetes cluster start               --cluster-id ID" -ForegroundColor Cyan
    Write-Host "  .\k3s.ps1 kubernetes cluster stop                --cluster-id ID" -ForegroundColor Cyan
    Write-Host "  .\k3s.ps1 kubernetes cluster kubeconfig          --cluster-id ID --raw > arquivo.yaml" -ForegroundColor Cyan
    Write-Host "  .\k3s.ps1 kubernetes cluster list" -ForegroundColor Cyan
    Write-Host "  .\k3s.ps1 kubernetes cluster get                 --cluster-id ID" -ForegroundColor Cyan
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
    "kubernetes cluster create*"             { Invoke-Create            -CmdArgs $rest }
    "kubernetes cluster configure-registry*" { Invoke-ConfigureRegistry -CmdArgs $rest }
    "kubernetes cluster start*"              { Invoke-Start             -CmdArgs $rest }
    "kubernetes cluster stop*"               { Invoke-Stop              -CmdArgs $rest }
    "kubernetes cluster kubeconfig*"         { Invoke-Kubeconfig        -CmdArgs $rest }
    "kubernetes cluster list*"               { Invoke-List }
    "kubernetes cluster get*"                { Invoke-Get               -CmdArgs $rest }
    "kubernetes cluster delete*"             { Invoke-Delete            -CmdArgs $rest }
    "network ip-cleanup*"                    { Invoke-IpCleanup }
    default                                  { Show-Help }
}
