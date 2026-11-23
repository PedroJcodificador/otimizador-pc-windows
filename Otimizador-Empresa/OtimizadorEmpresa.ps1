#Requires -Version 5.1
<#
    OTIMIZADOR EMPRESARIAL - Manutenção de estações de trabalho
    - Diagnóstico completo com relatório HTML (para anexar em chamados)
    - Limpeza de todos os perfis de usuário, otimização para trabalho, rede, atualizações, reparo
    - Toda alteração de registro tem backup e pode ser desfeita (opção 10)

    Uso:
      Interativo  : INICIAR_EMPRESA.bat
      Automático  : MANUTENCAO_AUTOMATICA.bat  (limpeza segura + relatório, sem perguntas)
      Parâmetros  : -Automatico  -PastaRelatorio "\\servidor\ti\relatorios"
#>
param(
    [switch]$Automatico,
    [string]$PastaRelatorio
)

# ---------- Autoelevação segura para Administrador ----------
function ConvertTo-ArgumentoSeguro([string]$valor) {
    if ([string]::IsNullOrEmpty($valor)) { return '""' }
    # Dobra barras invertidas antes de aspas e no final da string para preservar argumentos no CommandLineToArgvW
    $escapado = ($valor -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1'
    return '"' + $escapado + '"'
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($Automatico) {
        Write-Error "O modo -Automatico exige execução com privilégios de Administrador (ou conta SYSTEM)."
        exit 1
    }
    $partesArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-ArgumentoSeguro $PSCommandPath))
    if ($PastaRelatorio) {
        $partesArgs += @('-PastaRelatorio', (ConvertTo-ArgumentoSeguro $PastaRelatorio))
    }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ($partesArgs -join ' ') -ErrorAction Stop
        exit 0
    } catch {
        Write-Host "Não foi possível obter elevação para Administrador: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

$ErrorActionPreference = 'Continue'
$Script:ErrosExecucao = New-Object System.Collections.ArrayList

# ---------- Controle de execução simultânea (instância única) ----------
$Script:MutexInstancia = $null
$Script:MutexAdquirido = $false
try {
    try {
        $Script:MutexInstancia = New-Object System.Threading.Mutex($false, 'Global\OtimizadorEmpresarial_ExecucaoUnica')
    } catch [System.UnauthorizedAccessException] {
        # Em sessões com restrição no namespace Global, utiliza escopo local da sessão
        $Script:MutexInstancia = New-Object System.Threading.Mutex($false, 'Local\OtimizadorEmpresarial_ExecucaoUnica')
    }
    try {
        $Script:MutexAdquirido = $Script:MutexInstancia.WaitOne(0, $false)
    } catch [System.Threading.AbandonedMutexException] {
        # A execução anterior foi encerrada de forma abrupta; assume o controle com segurança
        $Script:MutexAdquirido = $true
    }
    if (-not $Script:MutexAdquirido) {
        Write-Warning "Já existe outra instância do Otimizador Empresarial em execução nesta máquina."
        if ($Script:MutexInstancia) { $Script:MutexInstancia.Dispose() }
        exit 3
    }
} catch {
    Write-Warning "Não foi possível inicializar o controle de instância única: $($_.Exception.Message)"
}

$Script:CodigoSaida = 0
# Bloco principal protegido por try/finally para garantir liberação do Mutex ao encerrar
try {

# ---------- Diretórios e isolamento por máquina ----------
$Base             = Split-Path -Parent $PSCommandPath
$ProgramaDataBase = Join-Path $env:ProgramData 'OtimizadorEmpresa'
$BackupDir        = Join-Path $ProgramaDataBase 'backup'
$BackupLegadoDir  = Join-Path $Base 'backup'

try {
    New-Item -ItemType Directory -Force -Path $BackupDir -ErrorAction Stop | Out-Null
} catch {
    # Fallback isolado por nome do computador caso ProgramData esteja indisponível
    $BackupDir = Join-Path $BackupLegadoDir $env:COMPUTERNAME
    try {
        New-Item -ItemType Directory -Force -Path $BackupDir -ErrorAction Stop | Out-Null
    } catch {
        [void]$Script:ErrosExecucao.Add("Não foi possível criar diretório de backup '$BackupDir': $($_.Exception.Message)")
    }
}

$LogDir = Join-Path $Base 'logs'
try {
    New-Item -ItemType Directory -Force -Path $LogDir -ErrorAction Stop | Out-Null
} catch {
    # Fallback local caso o script esteja sendo executado de um compartilhamento somente leitura
    $LogDir = Join-Path $ProgramaDataBase 'logs'
    try {
        New-Item -ItemType Directory -Force -Path $LogDir -ErrorAction Stop | Out-Null
    } catch {
        [void]$Script:ErrosExecucao.Add("Não foi possível criar diretório de logs '$LogDir': $($_.Exception.Message)")
    }
}

$BackupFile = Join-Path $BackupDir 'registro.json'
$LogFile    = Join-Path $LogDir ("{0}_{1:yyyy-MM-dd_HH-mm}.txt" -f $env:COMPUTERNAME, (Get-Date))

function Log($msg, $cor = 'Gray') {
    if (-not $Automatico) { Write-Host $msg -ForegroundColor $cor }
    try {
        Add-Content -LiteralPath $LogFile -Value ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $msg) -Encoding UTF8 -ErrorAction Stop
    } catch {
        if (-not $Automatico) { Write-Host "  [AVISO] Falha ao gravar log: $($_.Exception.Message)" -ForegroundColor DarkYellow }
    }
}
function Registrar-Erro($msg) {
    [void]$Script:ErrosExecucao.Add("$msg")
    Log "  [ERRO] $msg" 'Red'
}
function Titulo($t) { if (-not $Automatico) { Write-Host "" }; Log "=== $t ===" 'Cyan' }
function Pergunta($t, [bool]$padraoAutomatico = $false) {
    if ($Automatico) { return $padraoAutomatico }
    $r = Read-Host "$t (S/N)"; return ($r -match '^[sSyY]')
}
function Pausa { if (-not $Automatico) { Write-Host ""; Read-Host "Pressione ENTER para voltar ao menu" | Out-Null } }
function FormatTam([double]$b) {
    if ($b -ge 1GB) { return "{0:N2} GB" -f ($b / 1GB) }
    if ($b -ge 1MB) { return "{0:N1} MB" -f ($b / 1MB) }
    return "{0:N0} KB" -f ($b / 1KB)
}

# Prepara a pasta de relatórios com fallback local caso o caminho de rede esteja inacessível
$pastaRelatorioInformada = -not [string]::IsNullOrWhiteSpace($PastaRelatorio)
if (-not $pastaRelatorioInformada) { $PastaRelatorio = Join-Path $Base 'relatorios' }
try {
    New-Item -ItemType Directory -Force -Path $PastaRelatorio -ErrorAction Stop | Out-Null
    $arquivoTeste = Join-Path $PastaRelatorio (".teste_escrita_{0}.tmp" -f $PID)
    [IO.File]::WriteAllText($arquivoTeste, 'ok')
    Remove-Item -LiteralPath $arquivoTeste -Force -ErrorAction SilentlyContinue
} catch {
    $fallbackRelatorio = Join-Path $ProgramaDataBase 'relatorios'
    if ($pastaRelatorioInformada) {
        Registrar-Erro "Pasta de relatórios '$PastaRelatorio' inacessível ($($_.Exception.Message)). Usando fallback local: $fallbackRelatorio"
    }
    $PastaRelatorio = $fallbackRelatorio
    try {
        New-Item -ItemType Directory -Force -Path $PastaRelatorio -ErrorAction Stop | Out-Null
    } catch {
        Registrar-Erro "Não foi possível criar diretório de relatórios '$PastaRelatorio': $($_.Exception.Message)"
    }
}

# Migração retrocompatível: preserva backup legado criado em pasta local antes da mudança para ProgramData
if ((-not $Base.StartsWith('\\')) -and (-not (Test-Path -LiteralPath $BackupFile))) {
    $backupLegado = Join-Path $BackupLegadoDir 'registro.json'
    if (Test-Path -LiteralPath $backupLegado) {
        try {
            Copy-Item -LiteralPath $backupLegado -Destination $BackupFile -Force -ErrorAction Stop
            $planoLegado = Join-Path $BackupLegadoDir 'plano_energia.txt'
            $planoDestino = Join-Path $BackupDir 'plano_energia.txt'
            if ((Test-Path -LiteralPath $planoLegado) -and (-not (Test-Path -LiteralPath $planoDestino))) {
                Copy-Item -LiteralPath $planoLegado -Destination $planoDestino -Force -ErrorAction Stop
            }
            Log "Backup legado migrado para diretório isolado da máquina: $BackupDir" 'DarkGray'
        } catch {
            Registrar-Erro "Falha ao migrar backup legado de '$backupLegado': $($_.Exception.Message)"
        }
    }
}

# ---------- Helpers de segurança, escrita atômica e contexto de usuário ----------
function Write-ArquivoAtomico([string]$Caminho, [string]$Conteudo, [bool]$ComBom = $false) {
    $dir = Split-Path -Parent $Caminho
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null
    }
    $tmp = "$Caminho.$PID.tmp"
    $enc = New-Object System.Text.UTF8Encoding($ComBom)
    try {
        [IO.File]::WriteAllText($tmp, $Conteudo, $enc)
        Move-Item -LiteralPath $tmp -Destination $Caminho -Force -ErrorAction Stop
    } catch {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Test-ReparsePoint([IO.FileSystemInfo]$item) {
    if ($null -eq $item) { return $false }
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-CaminhoSeguroUsuario([string]$perfilRaiz, [string]$subCaminho) {
    # Verifica cada segmento dentro do perfil do usuário para impedir travessia por symlinks/junctions
    try {
        $dirPerfil = New-Object IO.DirectoryInfo($perfilRaiz)
        if (-not $dirPerfil.Exists -or (Test-ReparsePoint $dirPerfil)) { return $false }
        $acumulado = $dirPerfil.FullName
        foreach ($parte in ($subCaminho -split '[\\/]+')) {
            if ([string]::IsNullOrWhiteSpace($parte)) { continue }
            $acumulado = Join-Path $acumulado $parte
            if (Test-Path -LiteralPath $acumulado) {
                $info = Get-Item -LiteralPath $acumulado -Force -ErrorAction Stop
                if (Test-ReparsePoint $info) {
                    Log "  [AVISO] Caminho ignorado por conter link simbólico/junction: $acumulado" 'DarkYellow'
                    return $false
                }
            }
        }
        return $true
    } catch {
        return $false
    }
}

function Get-ContextoHiveUsuario {
    # Resolve o hive do usuário interativo ativo quando o script roda como SYSTEM ou outro administrador
    $identidadeAtual = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sidAtual = $identidadeAtual.User.Value
    $ehSystem = ($sidAtual -eq 'S-1-5-18')

    $usuarioAtivo = $null
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($cs -and -not [string]::IsNullOrWhiteSpace($cs.UserName)) {
            $usuarioAtivo = $cs.UserName.Trim()
        }
    } catch { }

    if ($usuarioAtivo) {
        try {
            $nt = New-Object System.Security.Principal.NTAccount($usuarioAtivo)
            $sidAtivo = $nt.Translate([System.Security.Principal.SecurityIdentifier]).Value
            if ($sidAtivo -eq $sidAtual) {
                return [pscustomobject]@{
                    Disponivel     = $true
                    HiveBase       = 'HKCU:'
                    EhOutroUsuario = $false
                    UsuarioNome    = $usuarioAtivo
                    Sid            = $sidAtivo
                    Motivo         = $null
                }
            }
            $caminhoHku = "Registry::HKEY_USERS\$sidAtivo"
            if (Test-Path -LiteralPath $caminhoHku) {
                return [pscustomobject]@{
                    Disponivel     = $true
                    HiveBase       = $caminhoHku
                    EhOutroUsuario = $true
                    UsuarioNome    = $usuarioAtivo
                    Sid            = $sidAtivo
                    Motivo         = $null
                }
            }
        } catch { }
    }

    if ($ehSystem) {
        return [pscustomobject]@{
            Disponivel     = $false
            HiveBase       = $null
            EhOutroUsuario = $false
            UsuarioNome    = $null
            Sid            = $null
            Motivo         = 'Executando como SYSTEM sem sessão de usuário interativo carregada no registro'
        }
    }

    return [pscustomobject]@{
        Disponivel     = $true
        HiveBase       = 'HKCU:'
        EhOutroUsuario = $false
        UsuarioNome    = $identidadeAtual.Name
        Sid            = $sidAtual
        Motivo         = $null
    }
}

# ---------- Registro com backup ----------
function Get-Backup {
    if (-not (Test-Path -LiteralPath $BackupFile)) { return @() }
    try {
        $conteudo = [IO.File]::ReadAllText($BackupFile, [Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($conteudo)) { return @() }
        $dados = $conteudo | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $dados) { return @() }
        return @($dados)
    } catch {
        $corrompido = Join-Path $BackupDir ("registro_corrompido_{0:yyyyMMdd_HHmmss}.json" -f (Get-Date))
        try { Copy-Item -LiteralPath $BackupFile -Destination $corrompido -Force -ErrorAction Stop } catch { }
        $msg = "Arquivo de backup '$BackupFile' está corrompido (cópia preservada em '$corrompido'): $($_.Exception.Message)"
        Registrar-Erro $msg
        throw $msg
    }
}

function Set-RegSeguro($Path, $Name, $Value, $Type = 'DWord') {
    try {
        $backup = @(Get-Backup)
        if (-not ($backup | Where-Object { $_.Path -eq $Path -and $_.Name -eq $Name })) {
            $existe = $false; $antigo = $null; $tipoAntigo = $null
            if (Test-Path -LiteralPath $Path) {
                $item = Get-Item -LiteralPath $Path -ErrorAction Stop
                if ($item.GetValueNames() -contains $Name) {
                    $existe = $true; $antigo = $item.GetValue($Name); $tipoAntigo = $item.GetValueKind($Name).ToString()
                }
            }
            $backup += [pscustomobject]@{ Path = $Path; Name = $Name; Existed = $existe; Value = $antigo; Type = $tipoAntigo }
            $json = $backup | ConvertTo-Json -Depth 4
            # Grava o backup atomicamente antes de aplicar a mudança no registro
            Write-ArquivoAtomico -Caminho $BackupFile -Conteudo $json -ComBom $false
        }
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        Log "  [reg] $Path\$Name = $Value" 'DarkGray'
        return $true
    } catch {
        Registrar-Erro "Falha ao alterar registro '$Path\$Name': $($_.Exception.Message)"
        return $false
    }
}

function Novo-PontoRestauracao {
    Log "Criando ponto de restauração do sistema..." 'Yellow'
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        Checkpoint-Computer -Description "Otimizador Empresarial" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Log "  Ponto de restauração criado." 'Green'
    } catch {
        Log "  Não foi possível criar agora (limite de 1 a cada 24h ou proteção desativada por política)." 'DarkYellow'
    }
}

# ---------- Status: ligado desde, último desligamento e memória RAM ----------
function Get-StatusPC {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $ligadoDesde = if ($os -and $os.LastBootUpTime) { $os.LastBootUpTime } else { Get-Date }
    $uptime = (Get-Date) - $ligadoDesde

    # Último desligamento: 1074 = desligar/reiniciar iniciado por usuário/programa, 6008 = inesperado, 6006 = normal
    $ultUsuario = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1074 } -MaxEvents 1 -ErrorAction SilentlyContinue
    $ultInesp   = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 6008 } -MaxEvents 1 -ErrorAction SilentlyContinue
    $ultNormal  = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 6006 } -MaxEvents 1 -ErrorAction SilentlyContinue
    $desligamento = 'sem registro'; $inesperado = $false
    if ($ultInesp -and (-not $ultUsuario -or $ultInesp.TimeCreated -gt $ultUsuario.TimeCreated) -and $ultInesp.Properties.Count -ge 2) {
        $quando = ("{0} {1}" -f "$($ultInesp.Properties[1].Value)", "$($ultInesp.Properties[0].Value)") -replace '[^\d:/\.\- ]', ''
        $desligamento = "$($quando.Trim()) - INESPERADO (queda de energia, botão ou travamento)"
        $inesperado = $true
    } elseif ($ultUsuario -and $ultUsuario.Properties.Count -ge 7) {
        $tipo = "$($ultUsuario.Properties[4].Value)".ToLower()
        $quem = "$($ultUsuario.Properties[6].Value)"
        $prog = (Split-Path -Leaf "$($ultUsuario.Properties[0].Value)") -replace '\s*\(.*$', ''
        $desligamento = "{0:dd/MM/yyyy HH:mm} - {1} por {2} ({3})" -f $ultUsuario.TimeCreated, $tipo, $quem, $prog
    } elseif ($ultNormal) {
        $desligamento = "{0:dd/MM/yyyy HH:mm} - desligamento normal" -f $ultNormal.TimeCreated
    }

    $ramTotal = if ($os -and $os.TotalVisibleMemorySize) { [double]$os.TotalVisibleMemorySize * 1KB } else { 0 }
    $ramLivre = if ($os -and $os.FreePhysicalMemory) { [double]$os.FreePhysicalMemory * 1KB } else { 0 }
    $ramUsada = [math]::Max(0, $ramTotal - $ramLivre)
    $ramPct   = if ($ramTotal -gt 0) { $ramUsada / $ramTotal * 100 } else { 0 }

    $pentes = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
    $velocidade = ($pentes | Measure-Object ConfiguredClockSpeed -Maximum).Maximum
    $slots = (Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction SilentlyContinue | Measure-Object MemoryDevices -Sum).Sum
    $hiber = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled

    return [pscustomobject]@{
        LigadoDesde   = $ligadoDesde
        Uptime        = $uptime
        Desligamento  = $desligamento
        Inesperado    = $inesperado
        FastStartup   = ($hiber -eq 1)
        RamTotal      = $ramTotal
        RamUsada      = $ramUsada
        RamLivre      = $ramLivre
        RamPct        = $ramPct
        Pentes        = ("{0} pente(s): {1}{2}{3}" -f $pentes.Count,
                            (($pentes | ForEach-Object { FormatTam $_.Capacity }) -join ' + '),
                            $(if ($velocidade) { " a $velocidade MHz" } else { '' }),
                            $(if ($slots) { " ($slots slots na placa)" } else { '' }))
        UmPente       = ($pentes.Count -eq 1)
    }
}

function Barra([double]$pct, [int]$largura = 20) {
    $pctSeguro = [math]::Max(0, [math]::Min(100, $pct))
    $cheio = [int][math]::Round($pctSeguro / 100 * $largura)
    return ('█' * $cheio) + ('░' * ($largura - $cheio))
}

function Get-PerfisUsuarios {
    $raizUsers = "$env:SystemDrive\Users"
    if (-not (Test-Path -LiteralPath $raizUsers -PathType Container)) { return @() }
    Get-ChildItem -LiteralPath $raizUsers -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object {
            -not (Test-ReparsePoint $_) -and
            $_.Name -notin 'Public', 'Default', 'Default User', 'All Users', 'defaultuser0' -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'AppData') -PathType Container)
        }
}

# =====================================================================
# 1. DIAGNÓSTICO + RELATÓRIO HTML
# =====================================================================
$Script:Relatorio = New-Object System.Collections.ArrayList
function Item($secao, $nome, $valor, $status = 'ok') {
    [void]$Script:Relatorio.Add([pscustomobject]@{ Secao = $secao; Nome = $nome; Valor = "$valor"; Status = $status })
    $cor = switch ($status) { 'erro' { 'Red' } 'aviso' { 'Yellow' } default { 'Gray' } }
    Log ("  {0,-34} {1}" -f $nome, $valor) $cor
}

function Get-TamanhoPastaSeguro([string]$caminho) {
    if (-not (Test-Path -LiteralPath $caminho -PathType Container)) { return 0 }
    try {
        $dirRaiz = New-Object IO.DirectoryInfo($caminho)
        if (-not $dirRaiz.Exists -or (Test-ReparsePoint $dirRaiz)) { return 0 }
        $raizNormalizada = $dirRaiz.FullName.TrimEnd('\') + '\'
        $pilha = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
        $pilha.Push($dirRaiz)
        [double]$total = 0

        while ($pilha.Count -gt 0) {
            $atual = $pilha.Pop()
            if (Test-ReparsePoint $atual) { continue }
            if ($atual.FullName -ne $dirRaiz.FullName -and -not $atual.FullName.StartsWith($raizNormalizada, [StringComparison]::OrdinalIgnoreCase)) { continue }
            try {
                foreach ($sub in $atual.EnumerateDirectories()) {
                    if (-not (Test-ReparsePoint $sub)) { $pilha.Push($sub) }
                }
            } catch { }
            try {
                foreach ($arq in $atual.EnumerateFiles()) {
                    if (-not (Test-ReparsePoint $arq) -and $arq.FullName.StartsWith($raizNormalizada, [StringComparison]::OrdinalIgnoreCase)) {
                        $total += $arq.Length
                    }
                }
            } catch { }
        }
        return $total
    } catch {
        return 0
    }
}

function Diagnostico {
    $Script:Relatorio.Clear()
    Titulo "DIAGNÓSTICO DA ESTAÇÃO $env:COMPUTERNAME"
    $os   = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs   = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
    $cpus = @(Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue)
    $cpu  = $cpus | Select-Object -First 1

    # --- Identificação
    $s = 'Identificação'
    Log "$s" 'White'
    Item $s 'Nome do computador' $env:COMPUTERNAME
    Item $s 'Domínio / grupo de trabalho' $(if ($cs) { $cs.Domain } else { 'não identificado' })
    Item $s 'Usuário logado' $(if ($cs -and $cs.UserName) { $cs.UserName } else { 'nenhum no momento' })
    Item $s 'Fabricante / modelo' $(if ($cs) { ("{0} {1}" -f $cs.Manufacturer, $cs.Model).Trim() } else { 'não identificado' })
    Item $s 'Número de série' $(if ($bios) { $bios.SerialNumber } else { 'não identificado' })
    Item $s 'Sistema' $(if ($os) { "{0} (build {1})" -f $os.Caption, $os.BuildNumber } else { 'não identificado' })
    $st = Get-StatusPC
    Item $s 'Ligado desde (último boot)' ("{0:dd/MM/yyyy HH:mm} - há {1} dia(s) e {2} h" -f $st.LigadoDesde, $st.Uptime.Days, $st.Uptime.Hours) $(if ($st.Uptime.TotalDays -gt 7) { 'aviso' } else { 'ok' })
    Item $s 'Último desligamento' $st.Desligamento $(if ($st.Inesperado) { 'erro' } else { 'ok' })
    if ($st.FastStartup) {
        Item $s 'Inicialização Rápida' 'ativa: "Desligar" não reinicia o Windows de verdade, só "Reiniciar" limpa a memória' 'aviso'
    }

    # --- Hardware
    $s = 'Hardware'
    Log "$s" 'White'
    if ($cpu) {
        Item $s 'Processador' ("{0} ({1} núcleos)" -f $cpu.Name.Trim(), $cpu.NumberOfCores)
        $cargaCpu = ($cpus | Measure-Object LoadPercentage -Average).Average
        if ($null -ne $cargaCpu) {
            Item $s 'Uso de CPU agora' ("{0:N0}%" -f $cargaCpu) $(if ($cargaCpu -gt 85) { 'aviso' } else { 'ok' })
        }
    }
    $ramTotal = $st.RamTotal; $ramLivre = $st.RamLivre; $usoRam = $st.RamPct
    if ($ramTotal -gt 0) {
        $stRam = 'ok'; if ($ramTotal -lt 7.5GB) { $stRam = 'aviso' }; if ($usoRam -gt 90) { $stRam = 'erro' }
        Item $s 'Memória RAM' ("{0} {1:N0}% - {2} em uso de {3}, {4} livre" -f (Barra $usoRam), $usoRam, (FormatTam $st.RamUsada), (FormatTam $ramTotal), (FormatTam $ramLivre)) $stRam
    }
    Item $s 'Pentes de memória' ($st.Pentes + $(if ($st.UmPente) { ' - pente único: adicionar outro igual ativa o dual channel (mais rápido)' } else { '' })) $(if ($st.UmPente) { 'aviso' } else { 'ok' })
    foreach ($d in Get-PhysicalDisk -ErrorAction SilentlyContinue) {
        $rel = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        $extra = ''
        if ($rel -and $rel.Wear) { $extra += " | desgaste $($rel.Wear)%" }
        if ($rel -and $rel.Temperature) { $extra += " | $($rel.Temperature) °C" }
        $stDisco = 'ok'
        if ($d.HealthStatus -ne 'Healthy' -or ($rel -and $rel.Wear -gt 80)) { $stDisco = 'erro' } elseif ($d.MediaType -eq 'HDD') { $stDisco = 'aviso' }
        Item $s ("Disco: {0}" -f $d.FriendlyName) ("{0} {1} - saúde: {2}{3}" -f $d.MediaType, (FormatTam $d.Size), $d.HealthStatus, $extra) $stDisco
    }
    foreach ($v in Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.Size -gt 0 -and $_.DriveType -eq 'Fixed' }) {
        $pct = $v.SizeRemaining / $v.Size * 100
        $stVol = 'ok'; if ($pct -lt 15) { $stVol = 'aviso' }; if ($pct -lt 5) { $stVol = 'erro' }
        Item $s ("Unidade {0}:" -f $v.DriveLetter) ("{0} livres de {1} ({2:N0}%)" -f (FormatTam $v.SizeRemaining), (FormatTam $v.Size), $pct) $stVol
    }
    $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($bat) {
        $full = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue | Select-Object -First 1).FullChargedCapacity
        $proj = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue | Select-Object -First 1).DesignedCapacity
        if ($full -and $proj -and $proj -gt 0) {
            $saude = $full / $proj * 100
            Item $s 'Saúde da bateria' ("{0:N0}% da capacidade original" -f $saude) $(if ($saude -lt 60) { 'aviso' } else { 'ok' })
        }
    }

    # --- Segurança
    $s = 'Segurança'
    Log "$s" 'White'
    $avs = Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue
    if ($avs) {
        foreach ($av in $avs) {
            if ($null -eq $av.productState) { continue }
            $hex = '{0:X6}' -f [int]$av.productState
            if ($hex.Length -lt 6) { continue }
            $ativo = $hex.Substring(2, 2) -in '10', '11'
            $atual = $hex.Substring(4, 2) -eq '00'
            $stAv = if ($ativo -and $atual) { 'ok' } elseif ($ativo) { 'aviso' } else { 'erro' }
            Item $s ("Antivírus: {0}" -f $av.displayName) ("{0}, {1}" -f $(if ($ativo) { 'ativo' } else { 'DESATIVADO' }), $(if ($atual) { 'atualizado' } else { 'DESATUALIZADO' })) $stAv
        }
    } else { Item $s 'Antivírus' 'nenhum detectado' 'erro' }
    foreach ($fw in Get-NetFirewallProfile -ErrorAction SilentlyContinue) {
        Item $s ("Firewall ({0})" -f $fw.Name) $(if ($fw.Enabled) { 'ativo' } else { 'DESATIVADO' }) $(if ($fw.Enabled) { 'ok' } else { 'erro' })
    }
    $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue
    if ($bl) {
        Item $s ("BitLocker ({0})" -f $env:SystemDrive) $bl.ProtectionStatus $(if ("$($bl.ProtectionStatus)" -eq 'On') { 'ok' } else { 'aviso' })
    }

    # --- Atualizações
    $s = 'Atualizações'
    Log "$s" 'White'
    $ultima = Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
    if ($ultima) {
        $dias = [int]((Get-Date) - $ultima.InstalledOn).TotalDays
        Item $s 'Última atualização instalada' ("{0} em {1:dd/MM/yyyy} ({2} dias)" -f $ultima.HotFixID, $ultima.InstalledOn, $dias) $(if ($dias -gt 45) { 'erro' } elseif ($dias -gt 30) { 'aviso' } else { 'ok' })
    }
    $pend = (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
            (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    Item $s 'Reinicialização pendente' $(if ($pend) { 'SIM - reinicie para concluir atualizações' } else { 'não' }) $(if ($pend) { 'aviso' } else { 'ok' })
    # 22 = desativado pelo usuário, 24/45 = dispositivo desconectado (não é problema)
    $prob = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -notin 22, 24, 45 })
    Item $s 'Dispositivos com problema' $(if ($prob) { ($prob | ForEach-Object { $_.Name }) -join '; ' } else { 'nenhum' }) $(if ($prob) { 'aviso' } else { 'ok' })

    # --- Rede
    $s = 'Rede'
    Log "$s" 'White'
    foreach ($n in Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway }) {
        Item $s ("Adaptador: {0}" -f $n.InterfaceAlias) ("IP {0} | gateway {1} | DNS {2}" -f ($n.IPv4Address.IPAddress -join ', '), $n.IPv4DefaultGateway.NextHop, (($n.DNSServer.ServerAddresses | Select-Object -Unique) -join ', '))
    }
    $internet = Test-NetConnection -ComputerName 'www.microsoft.com' -Port 443 -InformationLevel Quiet -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    Item $s 'Acesso à internet (HTTPS)' $(if ($internet) { 'OK' } else { 'FALHOU' }) $(if ($internet) { 'ok' } else { 'erro' })

    # --- Desempenho
    $s = 'Desempenho'
    Log "$s" 'White'
    $startup = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue)
    Item $s 'Programas na inicialização' $startup.Count $(if ($startup.Count -gt 12) { 'aviso' } else { 'ok' })
    $planoBruto = (powercfg /getactivescheme 2>$null)
    $plano = if ($planoBruto) { "$planoBruto" -replace '.*\((.*)\).*', '$1' } else { 'não identificado' }
    Item $s 'Plano de energia' $plano
    [double]$tempUsuarios = 0
    foreach ($p in Get-PerfisUsuarios) {
        if (Test-CaminhoSeguroUsuario $p.FullName 'AppData\Local\Temp') {
            $tempUsuarios += Get-TamanhoPastaSeguro (Join-Path $p.FullName 'AppData\Local\Temp')
        }
    }
    Item $s 'Temporários (todos os usuários)' (FormatTam $tempUsuarios) $(if ($tempUsuarios -gt 2GB) { 'aviso' } else { 'ok' })
    $top = Get-Process -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 | ForEach-Object { "{0} ({1})" -f $_.ProcessName, (FormatTam $_.WorkingSet64) }
    Item $s 'Maiores consumidores de memória' ($top -join '; ')

    Titulo "POSSÍVEIS PROBLEMAS E CAUSAS"
    Analisar-Problemas
    Mostrar-Achados

    $arq = Exportar-Relatorio
    Write-Host ""
    $erros = @($Script:Relatorio | Where-Object { $_.Status -eq 'erro' }).Count
    $avisos = @($Script:Relatorio | Where-Object { $_.Status -eq 'aviso' }).Count
    Log ("Resumo: {0} problema(s) crítico(s), {1} aviso(s)" -f $erros, $avisos) $(if ($erros) { 'Red' } elseif ($avisos) { 'Yellow' } else { 'Green' })
    if ($arq) {
        Log "Relatório salvo em: $arq" 'Cyan'
        if (Pergunta "Abrir o relatório agora?") {
            try {
                Start-Process -FilePath $arq -ErrorAction Stop
            } catch {
                Registrar-Erro "Não foi possível abrir o relatório '$arq': $($_.Exception.Message)"
            }
        }
    }
    Pausa
}

function Exportar-Relatorio {
    $nomeArq = "{0}_{1:yyyy-MM-dd_HH-mm}.html" -f $env:COMPUTERNAME, (Get-Date)
    $arq = Join-Path $PastaRelatorio $nomeArq
    $esc = { param($t) [System.Net.WebUtility]::HtmlEncode("$t") }
    $erros = @($Script:Relatorio | Where-Object { $_.Status -eq 'erro' }).Count + @($Script:Achados | Where-Object { $_.Gravidade -eq 'erro' }).Count
    $avisos = @($Script:Relatorio | Where-Object { $_.Status -eq 'aviso' }).Count + @($Script:Achados | Where-Object { $_.Gravidade -eq 'aviso' }).Count
    $nomePcEsc = & $esc $env:COMPUTERNAME
    $usuarioEsc = & $esc $env:USERNAME
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(@"
<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Relatório $nomePcEsc</title><style>
body{font-family:Segoe UI,Arial,sans-serif;background:#f4f6f8;color:#1f2933;margin:0;padding:24px}
.wrap{max-width:960px;margin:auto}h1{margin:0 0 4px;font-size:24px}.sub{color:#52606d;margin-bottom:20px}
.resumo{display:flex;gap:12px;margin-bottom:20px;flex-wrap:wrap}.card{background:#fff;border-radius:8px;padding:12px 18px;box-shadow:0 1px 3px rgba(0,0,0,.08)}
.card b{font-size:22px;display:block}h2{font-size:16px;margin:24px 0 8px;color:#323f4b}
table{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,.08)}
td{padding:8px 12px;border-bottom:1px solid #e4e7eb;vertical-align:top;font-size:14px}td:first-child{width:34%;color:#52606d}
.st{width:14px}.ok{color:#2f8132}.aviso{color:#b7791f}.erro{color:#c53030;font-weight:600}
</style></head><body><div class="wrap">
<h1>Relatório de manutenção - $nomePcEsc</h1>
<div class="sub">Gerado em $(Get-Date -Format 'dd/MM/yyyy HH:mm') por $usuarioEsc</div>
<div class="resumo"><div class="card"><b class="erro">$erros</b>problemas críticos</div><div class="card"><b class="aviso">$avisos</b>avisos</div>
<div class="card"><b class="ok">$(@($Script:Relatorio | Where-Object { $_.Status -eq 'ok' }).Count)</b>itens OK</div></div>
"@)
    if ($Script:Achados.Count) {
        $ordem = @{ erro = 0; aviso = 1; info = 2 }
        [void]$sb.Append("<h2>Possíveis problemas e causas</h2><table>")
        foreach ($a in $Script:Achados | Sort-Object { $ordem[$_.Gravidade] }) {
            $icone = switch ($a.Gravidade) { 'erro' { '&#10006;' } 'aviso' { '&#9888;' } default { '&#8505;' } }
            $classe = if ($a.Gravidade -eq 'info') { '' } else { $a.Gravidade }
            [void]$sb.Append("<tr><td class='$classe'>$icone $(& $esc $a.Categoria)<br><b>$(& $esc $a.Problema)</b></td>")
            [void]$sb.Append("<td>$(& $esc $a.Evidencia)<br><b>O que fazer:</b> $(& $esc $a.Solucao)</td></tr>")
        }
        [void]$sb.Append("</table>")
    }
    foreach ($g in $Script:Relatorio | Group-Object Secao) {
        [void]$sb.Append("<h2>$(& $esc $g.Name)</h2><table>")
        foreach ($i in $g.Group) {
            $icone = switch ($i.Status) { 'erro' { '&#10006;' } 'aviso' { '&#9888;' } default { '&#10004;' } }
            [void]$sb.Append("<tr><td>$(& $esc $i.Nome)</td><td class='$($i.Status)'>$icone $(& $esc $i.Valor)</td></tr>")
        }
        [void]$sb.Append("</table>")
    }
    [void]$sb.Append("</div></body></html>")
    $conteudoHtml = $sb.ToString()
    try {
        Write-ArquivoAtomico -Caminho $arq -Conteudo $conteudoHtml -ComBom $true
        return $arq
    } catch {
        Registrar-Erro "Falha ao salvar relatório em '$arq': $($_.Exception.Message)"
        $arqFallback = Join-Path (Join-Path $ProgramaDataBase 'relatorios') $nomeArq
        if ($arqFallback -ne $arq) {
            try {
                Write-ArquivoAtomico -Caminho $arqFallback -Conteudo $conteudoHtml -ComBom $true
                Log "Relatório salvo no fallback local: $arqFallback" 'Yellow'
                return $arqFallback
            } catch {
                Registrar-Erro "Falha ao salvar relatório no fallback '$arqFallback': $($_.Exception.Message)"
            }
        }
        return $null
    }
}

# =====================================================================
# 2. ANÁLISE DE PROBLEMAS - identifica sintomas e aponta causas prováveis
# =====================================================================
$Script:Achados   = New-Object System.Collections.ArrayList
$Script:Correcoes = New-Object System.Collections.ArrayList

function Achado(
    [string]$categoria,
    [string]$problema,
    [string]$evidencia,
    [string]$solucao,
    [string]$gravidade = 'aviso',
    $correcao = $null,
    [string]$descCorrecao = $null,
    [string]$tipoCorrecao = 'AcaoDireta',
    $alvoCorrecao = $null
) {
    [void]$Script:Achados.Add([pscustomobject]@{
        Categoria = $categoria; Problema = $problema; Evidencia = $evidencia; Solucao = $solucao; Gravidade = $gravidade
    })
    $temCorrecao = ($null -ne $correcao) -or ($null -ne $alvoCorrecao)
    if ($temCorrecao -and $descCorrecao -and -not ($Script:Correcoes | Where-Object { $_.Descricao -eq $descCorrecao })) {
        [void]$Script:Correcoes.Add([pscustomobject]@{
            Descricao = $descCorrecao
            Tipo      = $tipoCorrecao
            Alvo      = $alvoCorrecao
            Acao      = $correcao
        })
    }
}

function Executar-Correcao($Correcao) {
    # Despachante estruturado que substitui execução dinâmica de código montado via strings
    switch ($Correcao.Tipo) {
        'ReiniciarDispositivo' {
            & pnputil.exe /restart-device $Correcao.Alvo | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "pnputil.exe retornou código $LASTEXITCODE ao reiniciar dispositivo."
            }
        }
        'AtivarDispositivoPnp' {
            Enable-PnpDevice -InstanceId $Correcao.Alvo -Confirm:$false -ErrorAction Stop | Out-Null
        }
        'AlterarRegistro' {
            $ok = Set-RegSeguro $Correcao.Alvo.Path $Correcao.Alvo.Name $Correcao.Alvo.Value $Correcao.Alvo.Type
            if (-not $ok) {
                throw "Não foi possível atualizar '$($Correcao.Alvo.Path)\$($Correcao.Alvo.Name)'."
            }
        }
        'IniciarServico' {
            Start-Service -Name $Correcao.Alvo -ErrorAction Stop
        }
        'ReiniciarServico' {
            Restart-Service -Name $Correcao.Alvo -Force -ErrorAction Stop
        }
        'AcaoDireta' {
            if ($Correcao.Acao -is [scriptblock]) {
                & $Correcao.Acao
            } else {
                throw "Ação de correção inválida."
            }
        }
        default {
            throw "Tipo de correção desconhecido: $($Correcao.Tipo)"
        }
    }
}

# Processos que costumam aparecer como "vilões" e o que significam
$ProcessosConhecidos = @{
    'MsMpEng' = 'antivírus Defender verificando'; 'NisSrv' = 'antivírus Defender'
    'TiWorker' = 'Windows Update instalando'; 'TrustedInstaller' = 'Windows Update instalando'
    'MoUsoCoreWorker' = 'Windows Update procurando atualizações'; 'wuauserv' = 'Windows Update'
    'SearchIndexer' = 'indexação da pesquisa'; 'SearchProtocolHost' = 'indexação da pesquisa'
    'OneDrive' = 'OneDrive sincronizando'; 'ms-teams' = 'Microsoft Teams'; 'Teams' = 'Microsoft Teams'
    'chrome' = 'Chrome: muitas abas/extensões'; 'msedge' = 'Edge: muitas abas/extensões'; 'firefox' = 'Firefox: muitas abas/extensões'
    'OUTLOOK' = 'Outlook: caixa grande ou indexando'; 'CompatTelRunner' = 'telemetria do Windows'
    'WmiPrvSE' = 'consultas WMI de software de gestão/antivírus'; 'dwm' = 'gerenciador de janelas/driver de vídeo'
    'Memory Compression' = 'Windows comprimindo memória por falta de RAM'
}
function Nome-Amigavel($proc) { $d = $ProcessosConhecidos[$proc]; if ($d) { "$proc ($d)" } else { $proc } }

function Eventos([hashtable]$filtro, [int]$dias) {
    $filtro.StartTime = (Get-Date).AddDays(-$dias)
    return @(Get-WinEvent -FilterHashtable $filtro -ErrorAction SilentlyContinue)
}
function DadoEvento($evento, $nome) {
    try {
        return (([xml]$evento.ToXml()).Event.EventData.Data | Where-Object { $_.Name -eq $nome } | Select-Object -First 1).'#text'
    } catch {
        return $null
    }
}

function Analisar-Problemas {
    $Script:Achados.Clear(); $Script:Correcoes.Clear()
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $nucleos = [Environment]::ProcessorCount
    if ($nucleos -le 0) { $nucleos = 1 }
    $reiniciar = {
        shutdown.exe /r /t 120 /c "Reinicio agendado pela equipe de TI (Otimizador Empresarial). Salve seus arquivos."
        if ($LASTEXITCODE -ne 0) { throw "shutdown.exe retornou código $LASTEXITCODE." }
    }

    # ---------- Medição em tempo real (5 s) ----------
    Log "  Medindo CPU, memória e disco por 5 segundos..." 'Yellow'
    $antes = @{}
    foreach ($proc in Get-Process -ErrorAction SilentlyContinue) {
        try {
            if ($proc.TotalProcessorTime) { $antes[$proc.Id] = $proc.TotalProcessorTime.TotalMilliseconds }
        } catch { }
    }
    $inicio = Get-Date
    $amostras = @(for ($i = 0; $i -lt 5; $i++) {
        Start-Sleep -Seconds 1
        $mem = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction SilentlyContinue
        $dsk = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction SilentlyContinue
        $cpu = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction SilentlyContinue
        if ($mem -or $dsk -or $cpu) {
            [pscustomobject]@{
                Cpu    = if ($cpu) { [double]$cpu.PercentProcessorTime } else { $null }
                Perf   = if ($cpu) { [double]$cpu.PercentProcessorPerformance } else { $null }
                Pages  = if ($mem) { [double]$mem.PagesPersec } else { $null }
                Commit = if ($mem) { [double]$mem.PercentCommittedBytesInUse } else { $null }
                Ocioso = if ($dsk) { [double]$dsk.PercentIdleTime } else { $null }
                Fila   = if ($dsk) { [double]$dsk.CurrentDiskQueueLength } else { $null }
            }
        }
    })
    $ms = ((Get-Date) - $inicio).TotalMilliseconds
    if ($ms -le 0) { $ms = 1 }
    $media = {
        param($p)
        $vals = @($amostras | Where-Object { $null -ne $_.$p })
        if ($vals.Count -eq 0) { return $null }
        return ($vals | Measure-Object $p -Average).Average
    }
    $cpuMedia = & $media 'Cpu'; $perfMedia = & $media 'Perf'; $pages = & $media 'Pages'
    $commit = & $media 'Commit'; $ocioso = & $media 'Ocioso'; $fila = & $media 'Fila'

    $topCpu = Get-Process -ErrorAction SilentlyContinue | Where-Object { $antes.ContainsKey($_.Id) -and $_.ProcessName -ne 'Idle' } | ForEach-Object {
        try {
            if ($_.TotalProcessorTime) {
                [pscustomobject]@{ Nome = $_.ProcessName; Cpu = ($_.TotalProcessorTime.TotalMilliseconds - $antes[$_.Id]) / $ms / $nucleos * 100 }
            }
        } catch { }
    } | Group-Object Nome | ForEach-Object { [pscustomobject]@{ Nome = $_.Name; Cpu = ($_.Group | Measure-Object Cpu -Sum).Sum } } |
        Sort-Object Cpu -Descending | Select-Object -First 4
    $txtCpu = ($topCpu | Where-Object { $_.Cpu -ge 2 } | ForEach-Object { "{0} {1:N0}%" -f (Nome-Amigavel $_.Nome), $_.Cpu }) -join '; '
    $topMem = Get-Process -ErrorAction SilentlyContinue | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{ Nome = $_.Name; Mem = ($_.Group | Measure-Object WorkingSet64 -Sum).Sum } } | Sort-Object Mem -Descending | Select-Object -First 4
    $txtMem = ($topMem | ForEach-Object { "{0} {1}" -f (Nome-Amigavel $_.Nome), (FormatTam $_.Mem) }) -join '; '

    # ---------- LENTIDÃO: reinício ----------
    Log "  Verificando lentidão..." 'Yellow'
    if ($os -and $os.LastBootUpTime) {
        $uptime = (Get-Date) - $os.LastBootUpTime
        $fastStartup = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled -eq 1
        if ($uptime.TotalDays -ge 5) {
            $sol = 'Reiniciar o computador. Oriente o usuário a usar "Reiniciar" pelo menos 1x por semana'
            if ($fastStartup) { $sol += ' (a Inicialização Rápida está ativa: "Desligar" NÃO limpa a memória, só o "Reiniciar")' }
            Achado 'Lentidão' 'Computador sem reiniciar há muito tempo' ("Ligado há {0} dias" -f [int]$uptime.TotalDays) $sol `
                $(if ($uptime.TotalDays -ge 14) { 'erro' } else { 'aviso' }) $reiniciar 'Reiniciar o computador em 2 minutos'
        }
    }
    if ((Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
        Achado 'Lentidão' 'Atualizações aguardando reinicialização' 'O Windows instalou atualizações e precisa reiniciar para concluir' `
            'Reiniciar o computador; atualizações pendentes deixam o sistema mais lento e instável' 'aviso' $reiniciar 'Reiniciar o computador em 2 minutos'
    }

    # ---------- LENTIDÃO: memória RAM ----------
    if ($os -and $os.TotalVisibleMemorySize -gt 0) {
        $ramTotal = [double]$os.TotalVisibleMemorySize * 1KB
        $ramUso = 100 - ([double]$os.FreePhysicalMemory / [double]$os.TotalVisibleMemorySize * 100)
        $pagesSeg = if ($null -ne $pages) { $pages } else { 0 }
        $commitPct = if ($null -ne $commit) { $commit } else { 0 }
        if ($ramUso -ge 85 -or $pagesSeg -gt 1500 -or $commitPct -gt 90) {
            Achado 'Lentidão' 'Memória RAM esgotada' ("{0:N0}% da RAM em uso, {1:N0} páginas/s gravadas em disco. Maiores consumidores: {2}" -f $ramUso, $pagesSeg, $txtMem) `
                'Fechar programas e abas que não estão em uso. Se acontecer todo dia, a máquina precisa de mais memória RAM' $(if ($ramUso -ge 92) { 'erro' } else { 'aviso' })
        }
        if ($ramTotal -lt 7.5GB) {
            Achado 'Lentidão' 'Pouca memória RAM instalada' ("{0} instalados" -f (FormatTam $ramTotal)) `
                'Para uso corporativo (navegador, Office, Teams) o mínimo é 8 GB; o ideal é 16 GB' 'aviso'
        }
    }

    # ---------- LENTIDÃO: processador ----------
    if ($null -ne $cpuMedia -and $cpuMedia -ge 50) {
        Achado 'Lentidão' 'Processador sobrecarregado' ("Uso médio de {0:N0}% durante a medição. Maiores consumidores: {1}" -f $cpuMedia, $txtCpu) `
            'Verificar os programas listados. Se for antivírus ou Windows Update, é temporário: aguarde terminar' $(if ($cpuMedia -ge 80) { 'erro' } else { 'aviso' })
    }
    $limitacao = Eventos @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Processor-Power'; Id = 37 } 7
    if ($limitacao.Count -gt 0 -or ($null -ne $cpuMedia -and $cpuMedia -ge 50 -and $null -ne $perfMedia -and $perfMedia -gt 0 -and $perfMedia -lt 60)) {
        $perfTexto = if ($null -ne $perfMedia) { "{0:N0}%" -f $perfMedia } else { 'indisponível' }
        Achado 'Lentidão' 'Processador reduzindo a velocidade (superaquecimento ou energia)' `
            ("{0} avisos de velocidade limitada nos últimos 7 dias; desempenho atual {1} do nominal" -f $limitacao.Count, $perfTexto) `
            'Limpar poeira das ventoinhas, verificar pasta térmica e, em notebooks, usar o carregador original' 'aviso'
    }

    # ---------- LENTIDÃO: disco ----------
    if ($null -ne $ocioso -and $null -ne $fila -and $ocioso -lt 10 -and $fila -ge 2) {
        Achado 'Lentidão' 'Disco sobrecarregado' ("Disco ocupado {0:N0}% do tempo, {1:N1} operações na fila" -f (100 - $ocioso), $fila) `
            'Normal por alguns minutos após ligar ou durante atualizações. Se for constante, o disco é o gargalo (ver troca por SSD)' 'aviso'
    }
    $partSistema = Get-Partition -DriveLetter $env:SystemDrive[0] -ErrorAction SilentlyContinue
    if ($partSistema) {
        $discoSistema = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { "$($_.DeviceId)" -eq "$($partSistema.DiskNumber)" }
        if ($discoSistema -and $discoSistema.MediaType -eq 'HDD') {
            Achado 'Lentidão' 'Windows instalado em HD mecânico' ("{0} ({1})" -f $discoSistema.FriendlyName, $discoSistema.MediaType) `
                'Trocar por SSD: é a melhoria de velocidade mais perceptível em computadores antigos' 'aviso'
        }
    }
    $volSistema = Get-Volume -DriveLetter $env:SystemDrive[0] -ErrorAction SilentlyContinue
    if ($volSistema -and $volSistema.Size -gt 0) {
        $livre = $volSistema.SizeRemaining / $volSistema.Size * 100
        if ($livre -lt 10) {
            Achado 'Lentidão' "Pouco espaço livre no disco $env:SystemDrive" ("{0} livres ({1:N0}%)" -f (FormatTam $volSistema.SizeRemaining), $livre) `
                'Rodar a limpeza e mover arquivos grandes para a rede/nuvem. Com menos de 10% livre o Windows fica lento' `
                $(if ($livre -lt 5) { 'erro' } else { 'aviso' }) { Limpeza } 'Executar a limpeza de arquivos'
        }
    }
    $errosDisco = Eventos @{ LogName = 'System'; ProviderName = 'disk', 'Ntfs', 'stornvme', 'storahci', 'iaStorA', 'iaStorAC'; Level = 1, 2, 3 } 30
    if ($errosDisco.Count -gt 0) {
        Achado 'Hardware' 'Erros de leitura/gravação no disco' ("{0} erros registrados nos últimos 30 dias" -f $errosDisco.Count) `
            'FAZER BACKUP dos arquivos do usuário e verificar o disco (opção 7). Erros de disco costumam piorar até a falha total' 'erro'
    }
    foreach ($d in Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.HealthStatus -ne 'Healthy' }) {
        Achado 'Hardware' "Disco com saúde comprometida: $($d.FriendlyName)" ("Status SMART: {0}" -f $d.HealthStatus) `
            'Fazer backup imediatamente e providenciar a troca do disco' 'erro'
    }

    # ---------- LENTIDÃO: inicialização ----------
    $boots = Eventos @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } 30 | Select-Object -First 5
    if ($boots) {
        $temposBoot = @()
        foreach ($bEvt in $boots) {
            [double]$valorBoot = 0
            if ([double]::TryParse((DadoEvento $bEvt 'BootTime'), [ref]$valorBoot)) { $temposBoot += $valorBoot }
        }
        if ($temposBoot.Count -gt 0) {
            $bootSeg = ($temposBoot | Measure-Object -Average).Average / 1000
            if ($bootSeg -gt 90) {
                $lentos = Eventos @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 101, 102, 103, 106, 109 } 30 | ForEach-Object {
                    $n = DadoEvento $_ 'FriendlyName'; if (-not $n) { $n = DadoEvento $_ 'Name' }; $n
                } | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { $_.Name }
                $ev = "Tempo médio para ligar: {0:N0} segundos" -f $bootSeg
                if ($lentos) { $ev += ". Itens que mais atrasam: " + ($lentos -join '; ') }
                Achado 'Lentidão' 'Windows demora para iniciar' $ev 'Desativar programas desnecessários na inicialização (opção 5) e atualizar os drivers listados' `
                    $(if ($bootSeg -gt 180) { 'erro' } else { 'aviso' })
            }
        }
    }
    $qtdStartup = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue).Count
    if ($qtdStartup -gt 12) {
        Achado 'Lentidão' 'Muitos programas abrindo com o Windows' "$qtdStartup programas na inicialização" `
            'Desativar os que não são necessários (opção 5)' 'aviso' { Inicializacao } 'Ver e desativar programas da inicialização'
    }

    # ---------- LENTIDÃO: energia ----------
    $planoBruto = (powercfg /getactivescheme 2>$null)
    $plano = if ($planoBruto) { "$planoBruto" -replace '.*\((.*)\).*', '$1' } else { '' }
    if ($plano -match 'Economia|Power saver') {
        $ativarEquilibrado = {
            powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Falha ao ativar plano Equilibrado (código $LASTEXITCODE)." }
        }
        Achado 'Lentidão' 'Plano de energia em modo Economia' "Plano ativo: $plano" 'Usar o plano Equilibrado ou Alto desempenho' 'aviso' `
            $ativarEquilibrado 'Ativar o plano de energia Equilibrado'
    }
    $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($bat) {
        if ($bat.BatteryStatus -eq 1) {
            Achado 'Lentidão' 'Notebook funcionando na bateria' 'Fora da tomada o Windows reduz o desempenho para economizar energia' `
                'Ligar na tomada com o carregador original' 'info'
        }
        $cheia = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue | Select-Object -First 1).FullChargedCapacity
        $projeto = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue | Select-Object -First 1).DesignedCapacity
        if ($cheia -and $projeto -and $projeto -gt 0 -and ($cheia / $projeto) -lt 0.6) {
            Achado 'Hardware' 'Bateria desgastada' ("Bateria segura {0:N0}% da carga original" -f ($cheia / $projeto * 100)) `
                'Solicitar troca da bateria; bateria fraca também limita o desempenho' 'aviso'
        }
    }

    # ---------- TRAVAMENTOS E ESTABILIDADE ----------
    Log "  Verificando travamentos e erros de hardware..." 'Yellow'
    $bsod = Eventos @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001 } 30
    if ($bsod.Count) {
        $causasBsod = @{
            0x0A = 'IRQL_NOT_LESS_OR_EQUAL: driver com defeito ou memória RAM'
            0x1A = 'MEMORY_MANAGEMENT: provável problema na memória RAM'
            0x3B = 'SYSTEM_SERVICE_EXCEPTION: driver com defeito'
            0x50 = 'PAGE_FAULT_IN_NONPAGED_AREA: memória RAM ou driver'
            0x7A = 'KERNEL_DATA_INPAGE_ERROR: falha ao ler o disco (disco/cabo)'
            0x7E = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED: driver com defeito'
            0x9F = 'DRIVER_POWER_STATE_FAILURE: driver falhou ao suspender/retomar'
            0xD1 = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL: driver com defeito (comum em placa de rede)'
            0xEF = 'CRITICAL_PROCESS_DIED: arquivos do Windows corrompidos (rodar opção 7)'
            0xF4 = 'CRITICAL_OBJECT_TERMINATION: falha no disco/SSD'
            0x116 = 'VIDEO_TDR_FAILURE: driver ou placa de vídeo'
            0x124 = 'WHEA_UNCORRECTABLE_ERROR: falha de hardware (processador, fonte, superaquecimento)'
            0x133 = 'DPC_WATCHDOG_VIOLATION: driver travado (geralmente SSD/armazenamento, chipset ou rede; atualizar firmware do SSD e drivers do chipset)'
            0x139 = 'KERNEL_SECURITY_CHECK_FAILURE: driver incompatível ou memória RAM'
            0x154 = 'UNEXPECTED_STORE_EXCEPTION: falha no disco/SSD'
        }
        $codigos = $bsod | ForEach-Object {
            if ($_.Properties.Count -ge 1 -and "$($_.Properties[0].Value)" -match '0x[0-9a-fA-F]+') { [Convert]::ToInt64($matches[0], 16) }
        } | Group-Object | Sort-Object Count -Descending | ForEach-Object {
            $cod = [int64]$_.Name
            $desc = $causasBsod[[int]$cod]; if (-not $desc) { $desc = 'código não catalogado' }
            "0x{0:X} ({1}x) = {2}" -f $cod, $_.Count, $desc
        }
        Achado 'Travamentos' 'Telas azuis (o Windows travou e reiniciou)' ("{0} nos últimos 30 dias. {1}" -f $bsod.Count, ($codigos -join ' | ')) `
            'Atualizar drivers e Windows (opção 8). Se continuar, testar a memória RAM com o Diagnóstico de Memória' 'erro' `
            { Start-Process mdsched.exe } 'Abrir o Diagnóstico de Memória do Windows (testa a RAM ao reiniciar)'
    }
    $quedas = Eventos @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41 } 30
    if ($quedas.Count) {
        Achado 'Travamentos' 'Desligamentos inesperados' ("{0} vezes nos últimos 30 dias o PC desligou sem encerrar o Windows" -f $quedas.Count) `
            'Causas comuns: queda de energia, botão desligar pressionado, fonte de alimentação ou superaquecimento. Verificar nobreak, fonte e ventilação' `
            $(if ($quedas.Count -ge 3) { 'erro' } else { 'aviso' })
    }
    $whea = Eventos @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger' } 30
    if ($whea.Count) {
        $graves = @($whea | Where-Object { $_.Level -le 2 }).Count
        Achado 'Hardware' 'Erros de hardware registrados pelo Windows' ("{0} eventos ({1} graves) nos últimos 30 dias" -f $whea.Count, $graves) `
            'Indica falha de processador, memória RAM ou placa-mãe. Testar a memória e acionar a garantia/fabricante se persistir' `
            $(if ($graves) { 'erro' } else { 'aviso' }) { Start-Process mdsched.exe } 'Abrir o Diagnóstico de Memória do Windows (testa a RAM ao reiniciar)'
    }
    $falhasApp = Eventos @{ LogName = 'Application'; ProviderName = 'Application Error', 'Application Hang'; Id = 1000, 1002 } 7
    $piores = $falhasApp | Where-Object { $_.Properties.Count -ge 1 } | ForEach-Object { "$($_.Properties[0].Value)" } | Group-Object | Where-Object { $_.Count -ge 3 } | Sort-Object Count -Descending | Select-Object -First 4
    if ($piores) {
        Achado 'Travamentos' 'Programas travando ou fechando sozinhos' (($piores | ForEach-Object { "{0} ({1}x)" -f $_.Name, $_.Count }) -join '; ') `
            'Atualizar ou reparar o programa (Configurações > Aplicativos > Modificar/Reparar). No Office, usar "Reparo Rápido"' 'aviso'
    }

    # ---------- DISPOSITIVOS ----------
    Log "  Verificando dispositivos (câmera, áudio, USB...)..." 'Yellow'
    $significado = @{
        1 = 'não configurado corretamente'; 3 = 'driver corrompido ou falta de memória'; 10 = 'o dispositivo não consegue iniciar'
        12 = 'conflito de recursos'; 14 = 'precisa reiniciar o computador'; 18 = 'driver precisa ser reinstalado'; 19 = 'configuração corrompida'
        28 = 'driver não instalado'; 31 = 'driver não carregou'; 32 = 'driver desativado'; 39 = 'driver corrompido ou ausente'
        43 = 'o dispositivo relatou falha (hardware ou driver)'; 48 = 'driver bloqueado por incompatibilidade'; 52 = 'driver sem assinatura válida'
    }
    $tipos = @{
        Camera = 'Câmera'; Image = 'Câmera'; AudioEndpoint = 'Áudio'; MEDIA = 'Áudio'; Net = 'Rede'; Bluetooth = 'Bluetooth'; USB = 'USB'
        Display = 'Vídeo'; Monitor = 'Monitor'; Printer = 'Impressora'; Keyboard = 'Teclado'; Mouse = 'Mouse'; HIDClass = 'Dispositivo USB'
        Biometric = 'Leitor biométrico'; SmartCardReader = 'Leitor de cartão/certificado'; DiskDrive = 'Disco'; Ports = 'Porta serial/USB'
    }
    $pnpTodos = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue)
    foreach ($d in $pnpTodos | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -notin 22, 24, 45 }) {
        $cat = $tipos["$($d.PNPClass)"]; if (-not $cat) { $cat = 'Dispositivo' }
        $desc = $significado[[int]$d.ConfigManagerErrorCode]; if (-not $desc) { $desc = 'erro desconhecido' }
        $nome = if ($d.Name) { $d.Name } else { $d.PNPDeviceID }
        Achado $cat "$nome não está funcionando" ("Erro {0}: {1}" -f $d.ConfigManagerErrorCode, $desc) `
            'Reiniciar o dispositivo; se persistir, reinstalar o driver pelo site do fabricante ou pelo Windows Update (opção 8)' 'erro' `
            $null "Reiniciar o dispositivo: $nome" 'ReiniciarDispositivo' $d.PNPDeviceID
    }

    # Câmera e microfone (considera usuário interativo ativo quando executado como SYSTEM/outro admin)
    $cams = @($pnpTodos | Where-Object { $_.PNPClass -in 'Camera', 'Image' -and $_.Present })
    if (-not $cams) {
        Achado 'Câmera' 'Nenhuma câmera detectada' 'O Windows não encontrou nenhuma câmera conectada' `
            'Se a máquina deveria ter câmera: verificar cabo/porta USB, tampa ou tecla de privacidade do notebook e se não foi desativada na BIOS' 'info'
    }
    foreach ($c in $cams | Where-Object { $_.ConfigManagerErrorCode -eq 22 }) {
        Achado 'Câmera' "Câmera desativada: $($c.Name)" 'A câmera foi desativada no Gerenciador de Dispositivos' 'Reativar a câmera' 'erro' `
            $null "Reativar a câmera: $($c.Name)" 'AtivarDispositivoPnp' $c.PNPDeviceID
    }
    $ctxUsuario = Get-ContextoHiveUsuario
    foreach ($rec in @(@{ Chave = 'webcam'; Nome = 'câmera'; Cat = 'Câmera' }, @{ Chave = 'microphone'; Nome = 'microfone'; Cat = 'Áudio' })) {
        $politica = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' -ErrorAction SilentlyContinue)."LetAppsAccess$(if ($rec.Chave -eq 'webcam') { 'Camera' } else { 'Microphone' })"
        if ($politica -eq 2) {
            Achado $rec.Cat "Acesso à $($rec.Nome) bloqueado por política" 'Uma política de grupo (GPO/Intune) impede os apps de usar o dispositivo' `
                'Verificar a política com a equipe de TI responsável pelo domínio' 'erro'
        }
        $chaveMachine = "HKLM:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$($rec.Chave)"
        if ((Get-ItemProperty -LiteralPath $chaveMachine -ErrorAction SilentlyContinue).Value -eq 'Deny') {
            Achado $rec.Cat "Acesso à $($rec.Nome) bloqueado nas configurações de privacidade" "Bloqueado para todos os usuários em Configurações > Privacidade" `
                "Liberar o acesso à $($rec.Nome)" 'erro' $null "Liberar o acesso à $($rec.Nome) (para todos os usuários)" `
                'AlterarRegistro' @{ Path = $chaveMachine; Name = 'Value'; Value = 'Allow'; Type = 'String' }
        }
        if ($ctxUsuario.Disponivel) {
            $chaveUser = "$($ctxUsuario.HiveBase)\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$($rec.Chave)"
            $escopoUser = if ($ctxUsuario.EhOutroUsuario) { "para $($ctxUsuario.UsuarioNome)" } else { 'para este usuário' }
            if ((Get-ItemProperty -LiteralPath $chaveUser -ErrorAction SilentlyContinue).Value -eq 'Deny') {
                Achado $rec.Cat "Acesso à $($rec.Nome) bloqueado nas configurações de privacidade" "Bloqueado $escopoUser em Configurações > Privacidade" `
                    "Liberar o acesso à $($rec.Nome)" 'erro' $null "Liberar o acesso à $($rec.Nome) ($escopoUser)" `
                    'AlterarRegistro' @{ Path = $chaveUser; Name = 'Value'; Value = 'Allow'; Type = 'String' }
            }
            $emUso = Get-ChildItem -LiteralPath $chaveUser -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                if ($p -and $p.LastUsedTimeStart -and $p.LastUsedTimeStop -eq 0) { Split-Path -Leaf ($_.PSChildName -replace '#', '\') }
            }
            if ($emUso) {
                Achado $rec.Cat "A $($rec.Nome) está sendo usada por outro programa" ("Em uso agora por: {0}" -f (($emUso | Select-Object -Unique) -join ', ')) `
                    "Se a $($rec.Nome) não funciona no Teams/Zoom/Meet, feche o programa listado: só um app por vez consegue usá-la" 'info'
            }
        }
    }

    # Áudio
    foreach ($svc in 'Audiosrv', 'AudioEndpointBuilder') {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s -and $s.Status -ne 'Running') {
            Achado 'Áudio' "Serviço de áudio parado ($svc)" 'Sem esse serviço não há som nem microfone' 'Iniciar o serviço' 'erro' `
                $null "Iniciar o serviço de áudio $svc" 'IniciarServico' $svc
        }
    }
    if (-not (Get-PnpDevice -Class AudioEndpoint -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'OK' })) {
        Achado 'Áudio' 'Nenhum dispositivo de som ativo' 'Não há alto-falante, fone ou microfone funcionando' `
            'Verificar se o fone/caixa está conectado e o driver de áudio instalado' 'aviso'
    }

    # ---------- REDE ----------
    Log "  Verificando rede..." 'Yellow'
    $conexoes = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.NetAdapter.Status -eq 'Up' })
    $renovarIp = {
        ipconfig /release | Out-Null
        ipconfig /renew | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "ipconfig /renew retornou código $LASTEXITCODE." }
    }
    foreach ($n in $conexoes | Where-Object { $_.IPv4Address.IPAddress -like '169.254.*' }) {
        Achado 'Rede' "Sem endereço IP em $($n.InterfaceAlias)" 'O computador não recebeu IP do servidor DHCP (endereço 169.254.x.x)' `
            'Verificar cabo/Wi-Fi e o roteador/servidor DHCP' 'erro' $renovarIp 'Renovar o endereço IP'
    }
    if (-not ($conexoes | Where-Object { $_.IPv4DefaultGateway })) {
        Achado 'Rede' 'Sem conexão de rede' 'Nenhum adaptador conectado com acesso a gateway' 'Verificar cabo de rede ou conexão Wi-Fi (opção 6 para diagnóstico)' 'erro'
    } else {
        if (-not (Resolve-DnsName 'www.microsoft.com' -DnsOnly -ErrorAction SilentlyContinue)) {
            Achado 'Rede' 'Falha na resolução de nomes (DNS)' 'Os sites não são encontrados pelo nome' `
                'Limpar o cache DNS; se persistir, verificar o servidor DNS da empresa' 'erro' { Clear-DnsClientCache -ErrorAction Stop } 'Limpar o cache DNS'
        }
    }
    $sinal = (netsh wlan show interfaces 2>$null) | Select-String '^\s*(Sinal|Signal)\s*:\s*(\d+)\s*%' | Select-Object -First 1
    if ($sinal -and [int]$sinal.Matches[0].Groups[2].Value -lt 50) {
        Achado 'Rede' 'Sinal de Wi-Fi fraco' ("Intensidade do sinal: {0}%" -f $sinal.Matches[0].Groups[2].Value) `
            'Aproximar do roteador, instalar repetidor/access point ou usar cabo de rede' 'aviso'
    }
    foreach ($a in Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' -and $_.ReceiveLinkSpeed -gt 0 -and $_.ReceiveLinkSpeed -lt 1e9 }) {
        Achado 'Rede' "Rede cabeada lenta ($($a.LinkSpeed))" "O adaptador $($a.Name) conectou a $($a.LinkSpeed) em vez de 1 Gbps" `
            'Possível cabo danificado, conector ruim ou porta do switch limitada. Testar outro cabo/porta' 'aviso'
    }

    # ---------- IMPRESSÃO ----------
    $spooler = Get-Service -Name Spooler -ErrorAction SilentlyContinue
    if ($spooler -and $spooler.Status -ne 'Running') {
        Achado 'Impressora' 'Serviço de impressão parado' 'Nenhuma impressora vai funcionar' 'Iniciar o serviço de impressão' 'erro' `
            $null 'Iniciar o serviço de impressão' 'IniciarServico' 'Spooler'
    } elseif ($spooler) {
        $impressoras = @(Get-Printer -ErrorAction SilentlyContinue)
        $presos = @($impressoras | ForEach-Object { Get-PrintJob -PrinterName $_.Name -ErrorAction SilentlyContinue } |
            Where-Object { "$($_.JobStatus)" -match 'Error|Blocked|Deleting' -or $_.SubmittedTime -lt (Get-Date).AddMinutes(-30) })
        if ($presos) {
            Achado 'Impressora' 'Fila de impressão travada' ("{0} documento(s) parado(s) na fila" -f $presos.Count) `
                'Reiniciar o serviço de impressão e reenviar os documentos' 'aviso' $null 'Reiniciar o serviço de impressão' 'ReiniciarServico' 'Spooler'
        }
        foreach ($p in $impressoras | Where-Object { $_.Name -notmatch 'PDF|XPS|OneNote|Fax' -and "$($_.PrinterStatus)" -match 'Offline|Error|PaperJam|PaperOut|NoToner|TonerLow|DoorOpen' }) {
            Achado 'Impressora' "Impressora com problema: $($p.Name)" "Status: $($p.PrinterStatus)" `
                'Verificar se está ligada, conectada à rede e com papel/toner' 'aviso'
        }
    }
}

function Mostrar-Achados {
    $ordem = @{ erro = 0; aviso = 1; info = 2 }
    if (-not $Script:Achados.Count) { Log "Nenhum problema encontrado." 'Green'; return }
    foreach ($a in $Script:Achados | Sort-Object { $ordem[$_.Gravidade] }) {
        $cor = switch ($a.Gravidade) { 'erro' { 'Red' } 'aviso' { 'Yellow' } default { 'Gray' } }
        $rot = switch ($a.Gravidade) { 'erro' { '[CRÍTICO]' } 'aviso' { '[ATENÇÃO]' } default { '[INFO]   ' } }
        Log ""
        Log ("{0} {1}: {2}" -f $rot, $a.Categoria, $a.Problema) $cor
        Log ("          Evidência   : {0}" -f $a.Evidencia)
        Log ("          O que fazer : {0}" -f $a.Solucao) 'White'
    }
}

function AnaliseProblemas {
    Titulo "ANÁLISE DE PROBLEMAS - CAUSAS PROVÁVEIS"
    Analisar-Problemas
    Mostrar-Achados
    if ($Script:Correcoes.Count -and -not $Automatico) {
        Write-Host ""
        Log "CORREÇÕES DISPONÍVEIS:" 'Cyan'
        $i = 0
        foreach ($c in $Script:Correcoes) { $i++; Write-Host ("  {0}. {1}" -f $i, $c.Descricao) }
        $r = Read-Host "Digite os números separados por vírgula, T para todas ou ENTER para nenhuma"
        $escolha = if ($r -match '^\s*[tT]') { 1..$i } else { $r -split '[,; ]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } }
        # reinício sempre por último
        $escolha = $escolha | Where-Object { $_ -ge 1 -and $_ -le $i } | Select-Object -Unique |
            Sort-Object { $Script:Correcoes[$_ - 1].Descricao -like 'Reiniciar o computador*' }
        foreach ($n in $escolha) {
            $c = $Script:Correcoes[$n - 1]
            Log "Executando: $($c.Descricao)" 'Yellow'
            try {
                Executar-Correcao $c
                Log "  concluído" 'Green'
            } catch {
                Registrar-Erro "Falha ao executar '$($c.Descricao)': $($_.Exception.Message)"
            }
        }
    }
    $Script:Relatorio.Clear()
    $arq = Exportar-Relatorio
    if ($arq) {
        Log "Relatório salvo em: $arq" 'Cyan'
        if (Pergunta "Abrir o relatório agora?") {
            try {
                Start-Process -FilePath $arq -ErrorAction Stop
            } catch {
                Registrar-Erro "Não foi possível abrir o relatório '$arq': $($_.Exception.Message)"
            }
        }
    }
    Pausa
}

# =====================================================================
# 3. LIMPEZA (todos os perfis de usuário)
# =====================================================================
function Limpar-Pasta($caminho, [int]$diasMin = 0) {
    if (-not (Test-Path -LiteralPath $caminho -PathType Container)) { return 0 }
    try {
        $dirRaiz = New-Object IO.DirectoryInfo($caminho)
    } catch {
        return 0
    }
    if (-not $dirRaiz.Exists) { return 0 }
    if (Test-ReparsePoint $dirRaiz) {
        Log "  [AVISO] Pasta ignorada por segurança (link simbólico/junction): $caminho" 'DarkYellow'
        return 0
    }

    $raizNormalizada = $dirRaiz.FullName.TrimEnd('\') + '\'
    $limite = (Get-Date).AddDays(-$diasMin)
    [double]$liberado = 0
    $pilha = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $subpastas = New-Object 'System.Collections.Generic.List[System.IO.DirectoryInfo]'
    $pilha.Push($dirRaiz)

    while ($pilha.Count -gt 0) {
        $atual = $pilha.Pop()
        if (Test-ReparsePoint $atual) { continue }
        if ($atual.FullName -ne $dirRaiz.FullName -and -not $atual.FullName.StartsWith($raizNormalizada, [StringComparison]::OrdinalIgnoreCase)) { continue }

        # Nunca segue junctions ou links simbólicos ao descer na árvore de diretórios
        try {
            foreach ($sub in $atual.EnumerateDirectories()) {
                if (-not (Test-ReparsePoint $sub)) {
                    $pilha.Push($sub)
                    $subpastas.Add($sub)
                }
            }
        } catch { }

        try {
            foreach ($arq in $atual.EnumerateFiles()) {
                if (Test-ReparsePoint $arq) { continue }
                if (-not $arq.FullName.StartsWith($raizNormalizada, [StringComparison]::OrdinalIgnoreCase)) { continue }
                if ($arq.LastWriteTime -lt $limite) {
                    try {
                        $tam = $arq.Length
                        Remove-Item -LiteralPath $arq.FullName -Force -ErrorAction Stop
                        $liberado += $tam
                    } catch { }
                }
            }
        } catch { }
    }

    foreach ($d in ($subpastas | Sort-Object { $_.FullName.Length } -Descending)) {
        if (Test-ReparsePoint $d) { continue }
        try {
            if (-not ($d.EnumerateFileSystemInfos() | Select-Object -First 1)) {
                [IO.Directory]::Delete($d.FullName, $false)
            }
        } catch { }
    }

    return $liberado
}
function Linha($descricao, $bytes) { Log ("  {0,-46} {1}" -f $descricao, (FormatTam $bytes)) 'Green' }

$Navegadores = @(
    @{ Nome = 'Google Chrome';  Proc = 'chrome';  Tipo = 'Chromium'; Rel = 'AppData\Local\Google\Chrome\User Data' }
    @{ Nome = 'Microsoft Edge'; Proc = 'msedge';  Tipo = 'Chromium'; Rel = 'AppData\Local\Microsoft\Edge\User Data' }
    @{ Nome = 'Brave';          Proc = 'brave';   Tipo = 'Chromium'; Rel = 'AppData\Local\BraveSoftware\Brave-Browser\User Data' }
    @{ Nome = 'Firefox';        Proc = 'firefox'; Tipo = 'Firefox';  Rel = 'AppData\Local\Mozilla\Firefox\Profiles' }
)
function Limpar-CacheNavegadores {
    [double]$total = 0
    foreach ($nav in $Navegadores) {
        if (Get-Process -Name $nav.Proc -ErrorAction SilentlyContinue) {
            if (Pergunta "  $($nav.Nome) está aberto. Fechar agora para limpar? (as abas voltam ao abrir de novo)") {
                Get-Process -Name $nav.Proc -ErrorAction SilentlyContinue | ForEach-Object { [void]$_.CloseMainWindow() }
                Start-Sleep -Seconds 4
            }
            if (Get-Process -Name $nav.Proc -ErrorAction SilentlyContinue) { Log ("  {0,-46} pulado (em uso)" -f "Cache do $($nav.Nome)") 'DarkYellow'; continue }
        }
        [double]$liberado = 0
        foreach ($perfil in Get-PerfisUsuarios) {
            if (-not (Test-CaminhoSeguroUsuario $perfil.FullName $nav.Rel)) { continue }
            $raiz = Join-Path $perfil.FullName $nav.Rel
            if (-not (Test-Path -LiteralPath $raiz -PathType Container)) { continue }
            if ($nav.Tipo -eq 'Chromium') {
                foreach ($x in 'ShaderCache', 'GrShaderCache', 'GraphiteDawnCache') { $liberado += Limpar-Pasta (Join-Path $raiz $x) }
                foreach ($p in Get-ChildItem -LiteralPath $raiz -Directory -Force -ErrorAction SilentlyContinue | Where-Object { -not (Test-ReparsePoint $_) -and ($_.Name -eq 'Default' -or $_.Name -like 'Profile *') }) {
                    foreach ($x in 'Cache', 'Code Cache', 'GPUCache') { $liberado += Limpar-Pasta (Join-Path $p.FullName $x) }
                }
            } else {
                foreach ($p in Get-ChildItem -LiteralPath $raiz -Directory -Force -ErrorAction SilentlyContinue | Where-Object { -not (Test-ReparsePoint $_) }) {
                    foreach ($x in 'cache2', 'startupCache') { $liberado += Limpar-Pasta (Join-Path $p.FullName $x) }
                }
            }
        }
        if ($liberado) { Linha "Cache do $($nav.Nome) (todos os usuários)" $liberado; $total += $liberado }
    }
    return $total
}

function Limpeza {
    Titulo "LIMPEZA DE ARQUIVOS DESNECESSÁRIOS"
    $volAntes = Get-Volume -DriveLetter $env:SystemDrive[0] -ErrorAction SilentlyContinue
    $antes = if ($volAntes) { [double]$volAntes.SizeRemaining } else { 0 }

    [double]$t = 0; [double]$c = 0; [double]$m = 0; [double]$w = 0
    foreach ($p in Get-PerfisUsuarios) {
        if (Test-CaminhoSeguroUsuario $p.FullName 'AppData\Local\Temp') {
            $t += Limpar-Pasta (Join-Path $p.FullName 'AppData\Local\Temp') 1
        }
        if (Test-CaminhoSeguroUsuario $p.FullName 'AppData\Local\CrashDumps') {
            $c += Limpar-Pasta (Join-Path $p.FullName 'AppData\Local\CrashDumps')
        }
        if (Test-CaminhoSeguroUsuario $p.FullName 'AppData\Local\Microsoft\Windows\INetCache') {
            $w += Limpar-Pasta (Join-Path $p.FullName 'AppData\Local\Microsoft\Windows\INetCache')
        }
        if (Test-CaminhoSeguroUsuario $p.FullName 'AppData\Local\Microsoft\Windows\Explorer') {
            $explorerDir = Join-Path $p.FullName 'AppData\Local\Microsoft\Windows\Explorer'
            Get-ChildItem -LiteralPath $explorerDir -Filter 'thumbcache_*.db' -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
                if (-not (Test-ReparsePoint $_)) {
                    try {
                        $tam = $_.Length
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                        $m += $tam
                    } catch { }
                }
            }
        }
    }
    Linha "Temporários de todos os usuários (> 1 dia)" $t
    Linha "Despejos de travamento de apps" $c
    Linha "Cache de internet do sistema" $w
    Linha "Cache de miniaturas" $m
    Linha "Temporários do Windows (> 1 dia)" (Limpar-Pasta "$env:SystemRoot\Temp" 1)
    Linha "Relatórios de erro do Windows" ((Limpar-Pasta "$env:ProgramData\Microsoft\Windows\WER\ReportArchive") + (Limpar-Pasta "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"))
    Linha "Logs antigos do Windows (> 7 dias)" (Limpar-Pasta "$env:SystemRoot\Logs\CBS" 7)

    # Garante que wuauserv e bits sejam restaurados mesmo em caso de erro durante a limpeza
    $servicosParaRestaurar = @()
    foreach ($nomeSvc in 'wuauserv', 'bits') {
        $svcObj = Get-Service -Name $nomeSvc -ErrorAction SilentlyContinue
        if ($svcObj -and $svcObj.Status -eq 'Running') { $servicosParaRestaurar += $nomeSvc }
    }
    try {
        foreach ($nomeSvc in $servicosParaRestaurar) {
            try {
                Stop-Service -Name $nomeSvc -Force -ErrorAction Stop
            } catch {
                Registrar-Erro "Não foi possível parar o serviço '$nomeSvc' antes da limpeza do Windows Update: $($_.Exception.Message)"
            }
        }
        Linha "Downloads antigos do Windows Update" (Limpar-Pasta "$env:SystemRoot\SoftwareDistribution\Download")
    } finally {
        foreach ($nomeSvc in $servicosParaRestaurar) {
            try {
                $svcAtual = Get-Service -Name $nomeSvc -ErrorAction Stop
                if ($svcAtual.Status -ne 'Running') {
                    Start-Service -Name $nomeSvc -ErrorAction Stop
                }
            } catch {
                Registrar-Erro "Não foi possível reiniciar o serviço '$nomeSvc' após a limpeza do Windows Update: $($_.Exception.Message)"
            }
        }
    }

    if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
        try {
            $do = (Get-DeliveryOptimizationStatus -ErrorAction SilentlyContinue | Measure-Object -Property FileSize -Sum).Sum
            Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
            Linha "Cache de Otimização de Entrega" $(if ($do) { $do } else { 0 })
        } catch {
            Log "  [AVISO] Não foi possível limpar o cache de Otimização de Entrega: $($_.Exception.Message)" 'DarkYellow'
        }
    }
    try {
        Clear-DnsClientCache -ErrorAction Stop
        Log "  Cache DNS limpo" 'Green'
    } catch {
        Registrar-Erro "Falha ao limpar o cache DNS: $($_.Exception.Message)"
    }

    if (-not $Automatico) { Write-Host "" }
    # No modo automático: limpa cache de navegadores fechados; NÃO esvazia lixeira nem roda DISM
    if (Pergunta "Limpar o cache dos navegadores de todos os usuários? (histórico, senhas, cookies e logins NÃO são apagados)" $true) {
        [void](Limpar-CacheNavegadores)
    }
    if (Pergunta "Esvaziar a Lixeira de todos os usuários? (exclusão PERMANENTE)") {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Log "  Lixeira esvaziada" 'Green'
    }
    if (Pergunta "Limpar componentes antigos do Windows (DISM)? Libera vários GB, leva de 5 a 20 min") {
        Log "  Executando DISM /StartComponentCleanup..." 'Yellow'
        Dism.exe /Online /Cleanup-Image /StartComponentCleanup | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Log "  Componentes antigos removidos" 'Green'
        } else {
            Registrar-Erro "DISM /StartComponentCleanup retornou código $LASTEXITCODE."
        }
    }

    $volDepois = Get-Volume -DriveLetter $env:SystemDrive[0] -ErrorAction SilentlyContinue
    if ($volAntes -and $volDepois) {
        Log ("ESPAÇO LIBERADO NO DISCO {0}: {1}" -f $env:SystemDrive, (FormatTam ([math]::Max(0, ([double]$volDepois.SizeRemaining - $antes))))) 'Cyan'
    }
    Pausa
}

# =====================================================================
# 4. OTIMIZAÇÃO PARA TRABALHO
# =====================================================================
function Otimizar {
    Titulo "OTIMIZAÇÃO DE DESEMPENHO PARA TRABALHO"
    Novo-PontoRestauracao
    $notebook = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)

    # Plano de energia
    $planoFile = Join-Path $BackupDir 'plano_energia.txt'
    $atualBruto = (powercfg /getactivescheme 2>$null)
    $atual = (($atualBruto -split '\s+') | Where-Object { $_ -match '^[0-9a-f-]{36}$' } | Select-Object -First 1)
    if ($notebook) {
        Log "  Notebook: plano de energia mantido (Equilibrado preserva a bateria)" 'Gray'
    } else {
        if ($atual -and -not (Test-Path -LiteralPath $planoFile)) {
            try {
                Write-ArquivoAtomico -Caminho $planoFile -Conteudo $atual -ComBom $false
            } catch {
                Registrar-Erro "Não foi possível salvar backup do plano de energia: $($_.Exception.Message)"
            }
        }
        $alto = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
        powercfg /setactive $alto | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $novo = ((powercfg -duplicatescheme $alto) -split '\s+') | Where-Object { $_ -match '^[0-9a-f-]{36}$' } | Select-Object -First 1
            if ($novo) { powercfg /setactive $novo | Out-Null }
        }
        if ($LASTEXITCODE -eq 0) {
            Log "  Plano de energia: Alto desempenho" 'Green'
        } else {
            Registrar-Erro "Não foi possível ativar o plano de energia Alto desempenho (código $LASTEXITCODE)."
        }
    }

    # Resolve o hive do usuário ativo (evita aplicar ajustes no perfil errado quando executado como SYSTEM/outro admin)
    $ctxUsuario = Get-ContextoHiveUsuario
    if (-not $ctxUsuario.Disponivel) {
        Log "  Ajustes de perfil de usuário ignorados: $($ctxUsuario.Motivo)" 'DarkYellow'
    } else {
        $hive = $ctxUsuario.HiveBase
        if ($ctxUsuario.EhOutroUsuario) {
            Log "  Aplicando ajustes no perfil do usuário ativo: $($ctxUsuario.UsuarioNome) ($($ctxUsuario.Sid))" 'Cyan'
        }

        # Sugestões, propagandas e instalação silenciosa de apps
        $cdm = "$hive\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        foreach ($v in 'SilentInstalledAppsEnabled', 'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled',
                       'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled', 'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled') {
            [void](Set-RegSeguro $cdm $v 0)
        }
        Log "  Dicas, sugestões e instalação automática de apps patrocinados desativadas" 'Green'

        # Programas da inicialização abrem sem atraso
        [void](Set-RegSeguro "$hive\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" 'StartupDelayInMSec' 0)
        Log "  Atraso artificial na inicialização removido" 'Green'

        if (Pergunta "Reduzir animações e transparência do Windows? (sistema mais ágil em máquinas modestas)") {
            [void](Set-RegSeguro "$hive\Control Panel\Desktop\WindowMetrics" 'MinAnimate' '0' 'String')
            [void](Set-RegSeguro "$hive\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'TaskbarAnimations' 0)
            [void](Set-RegSeguro "$hive\Control Panel\Desktop" 'MenuShowDelay' '50' 'String')
            [void](Set-RegSeguro "$hive\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" 'EnableTransparency' 0)
            Log "  Animações e transparência reduzidas" 'Green'
        }
        if (Pergunta "Impedir que apps da Microsoft Store rodem em segundo plano?") {
            [void](Set-RegSeguro "$hive\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" 'GlobalUserDisabled' 1)
            [void](Set-RegSeguro "$hive\Software\Microsoft\Windows\CurrentVersion\Search" 'BackgroundAppGlobalToggle' 0)
            Log "  Apps da Store em segundo plano bloqueados" 'Green'
        }
    }

    Log "Otimizando unidades (TRIM em SSD / desfragmentação em HD)..." 'Yellow'
    foreach ($vol in Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' }) {
        try {
            Optimize-Volume -DriveLetter $vol.DriveLetter -ErrorAction Stop
        } catch {
            Log "  [AVISO] Não foi possível otimizar unidade $($vol.DriveLetter):: $($_.Exception.Message)" 'DarkYellow'
        }
    }
    Log "  Unidades otimizadas" 'Green'
    Log "Concluído. Reinicie o computador. Para desfazer: opção 10." 'Cyan'
    Pausa
}

# =====================================================================
# 5. INICIALIZAÇÃO
# =====================================================================
function Inicializacao {
    Titulo "PROGRAMAS QUE ABREM COM O WINDOWS"
    $i = 0
    foreach ($s in Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | Sort-Object Name) {
        $i++; Log ("  {0,2}. {1,-35} {2} ({3})" -f $i, $s.Name, $s.Location, $s.User)
    }
    Write-Host ""
    Write-Host "Mantenha: antivírus, VPN corporativa, agentes de gestão/inventário, OneDrive/Teams se a empresa usa," -ForegroundColor Yellow
    Write-Host "drivers de áudio/vídeo/touchpad. Desative: atualizadores, launchers, apps pessoais." -ForegroundColor Yellow
    if (Pergunta "Abrir o Gerenciador de Tarefas na aba Inicialização?") {
        try {
            Start-Process taskmgr.exe -ArgumentList '/0 /startup' -ErrorAction Stop
        } catch {
            Registrar-Erro "Não foi possível abrir o Gerenciador de Tarefas: $($_.Exception.Message)"
        }
    }
    Pausa
}

# =====================================================================
# 6. REDE
# =====================================================================
function Rede {
    Titulo "DIAGNÓSTICO E REPARO DE REDE"
    foreach ($n in Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.NetAdapter.Status -eq 'Up' }) {
        Log ("Adaptador {0}: IP {1}" -f $n.InterfaceAlias, ($n.IPv4Address.IPAddress -join ', ')) 'White'
        if ($n.IPv4DefaultGateway) {
            $gw = $n.IPv4DefaultGateway.NextHop
            $okGw = Test-Connection -ComputerName $gw -Count 2 -Quiet -ErrorAction SilentlyContinue
            Log ("  Gateway {0}: {1}" -f $gw, $(if ($okGw) { 'responde' } else { 'NÃO responde' })) $(if ($okGw) { 'Green' } else { 'Red' })
        }
        Log ("  DNS: {0}" -f (($n.DNSServer.ServerAddresses | Select-Object -Unique) -join ', '))
    }
    $dns = [bool](Resolve-DnsName 'www.microsoft.com' -DnsOnly -ErrorAction SilentlyContinue)
    Log ("Resolução de nomes (DNS): {0}" -f $(if ($dns) { 'OK' } else { 'FALHOU' })) $(if ($dns) { 'Green' } else { 'Red' })
    $web = Test-NetConnection -ComputerName 'www.microsoft.com' -Port 443 -InformationLevel Quiet -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    Log ("Acesso à internet (HTTPS): {0}" -f $(if ($web) { 'OK' } else { 'FALHOU' })) $(if ($web) { 'Green' } else { 'Red' })

    try {
        Clear-DnsClientCache -ErrorAction Stop
        Log "Cache DNS limpo." 'Green'
    } catch {
        Registrar-Erro "Falha ao limpar o cache DNS: $($_.Exception.Message)"
    }
    Write-Host ""
    Write-Host "ATENÇÃO: o reset abaixo derruba a conexão e exige reiniciar. Não use se estiver em acesso remoto." -ForegroundColor Yellow
    if (Pergunta "Resetar Winsock e pilha TCP/IP? (resolve 'conectado sem internet' e erros de rede persistentes)") {
        netsh winsock reset | Out-Null
        $codWinsock = $LASTEXITCODE
        netsh int ip reset | Out-Null
        $codIp = $LASTEXITCODE
        if ($codWinsock -eq 0 -and $codIp -eq 0) {
            Log "Pilha de rede resetada. REINICIE o computador." 'Cyan'
        } else {
            Registrar-Erro "Reset de rede concluiu com avisos/erros (winsock=$codWinsock, ip=$codIp)."
        }
    }
    Pausa
}

# =====================================================================
# 7. REPARO DO WINDOWS
# =====================================================================
function Reparo {
    Titulo "VERIFICAÇÃO E REPARO DO WINDOWS"
    Write-Host "Corrige arquivos de sistema corrompidos e verifica o disco. Leva de 10 a 30 minutos." -ForegroundColor Yellow
    if (-not (Pergunta "Continuar?")) { return }
    $falhou = $false
    Log "Etapa 1/3: DISM RestoreHealth..." 'Yellow'
    Dism.exe /Online /Cleanup-Image /RestoreHealth
    if ($LASTEXITCODE -ne 0) { $falhou = $true; Registrar-Erro "DISM RestoreHealth retornou código $LASTEXITCODE." }

    Log "Etapa 2/3: SFC /scannow..." 'Yellow'
    sfc.exe /scannow
    if ($LASTEXITCODE -ne 0) { $falhou = $true; Registrar-Erro "SFC /scannow retornou código $LASTEXITCODE." }

    Log "Etapa 3/3: verificação do disco (online, sem reiniciar)..." 'Yellow'
    chkdsk.exe $env:SystemDrive /scan
    if ($LASTEXITCODE -ne 0) { $falhou = $true; Registrar-Erro "CHKDSK /scan retornou código $LASTEXITCODE." }

    if ($falhou) {
        Log "Reparo concluído com alertas/erros. Verifique as mensagens acima e o log." 'Yellow'
    } else {
        Log "Reparo concluído." 'Green'
    }
    Pausa
}

# =====================================================================
# 8. ATUALIZAÇÕES DO WINDOWS E DRIVERS
# =====================================================================
function Atualizacoes {
    Titulo "ATUALIZAÇÕES DO WINDOWS E DRIVERS"
    Log "Procurando atualizações (usa o servidor configurado na empresa, ex.: WSUS/Intune)..." 'Yellow'
    try {
        $sessao = New-Object -ComObject Microsoft.Update.Session
        $res = $sessao.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0")
    } catch {
        Registrar-Erro "Não foi possível consultar o Windows Update: $($_.Exception.Message)"
        Pausa; return
    }

    if ($res.Updates.Count -eq 0) { Log "O computador está em dia." 'Green'; Pausa; return }
    $lista = @(); for ($i = 0; $i -lt $res.Updates.Count; $i++) { $lista += $res.Updates.Item($i) }
    $i = 0
    foreach ($u in $lista) {
        $i++
        $tipo = if ($u.Type -eq 2) { "Driver/$($u.DriverClass)" } else { 'Windows' }
        Log ("  {0,2}. [{1}] {2}" -f $i, $tipo, $u.Title)
    }
    Write-Host ""
    if (-not (Pergunta "Instalar estas $($lista.Count) atualizações?")) { return }
    Novo-PontoRestauracao
    $col = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $lista) { if (-not $u.EulaAccepted) { $u.AcceptEula() }; [void]$col.Add($u) }
    try {
        Log "Baixando..." 'Yellow'
        $dl = $sessao.CreateUpdateDownloader(); $dl.Updates = $col; [void]$dl.Download()
        Log "Instalando (não desligue o computador)..." 'Yellow'
        $inst = $sessao.CreateUpdateInstaller(); $inst.Updates = $col
        $r = $inst.Install()
        for ($i = 0; $i -lt $col.Count; $i++) {
            $cod = $r.GetUpdateResult($i).ResultCode
            $txt = switch ($cod) { 2 { 'OK' } 3 { 'OK com avisos' } 4 { 'FALHOU' } 5 { 'cancelado' } default { "código $cod" } }
            Log ("  [{0}] {1}" -f $txt, $col.Item($i).Title) $(if ($cod -in 2, 3) { 'Green' } else { 'Red' })
        }
        if ($r.RebootRequired) { Log "Reinicie o computador para concluir." 'Cyan' }
    } catch {
        Registrar-Erro "Erro na instalação das atualizações: $($_.Exception.Message)"
    }
    Pausa
}

# =====================================================================
# 9. MANUTENÇÃO COMPLETA
# =====================================================================
function ManutencaoCompleta {
    Limpeza
    if (-not $Automatico) { Otimizar }
    Diagnostico
}

# =====================================================================
# 10. DESFAZER
# =====================================================================
function Desfazer {
    Titulo "DESFAZER OTIMIZAÇÕES"
    try {
        $backup = @(Get-Backup)
    } catch {
        Pausa; return
    }
    $planoFile = Join-Path $BackupDir 'plano_energia.txt'
    if (-not $backup.Count -and -not (Test-Path -LiteralPath $planoFile)) {
        Log "Nenhum backup encontrado. Nada a desfazer." 'Yellow'; Pausa; return
    }
    if (-not (Pergunta "Restaurar as configurações originais?")) { return }

    $falhas = 0
    foreach ($b in $backup) {
        try {
            if ($b.Existed) {
                $valor = $b.Value
                if ($b.Type -eq 'DWord') {
                    $v64 = [int64]$b.Value
                    if ($v64 -gt [int32]::MaxValue) { $v64 = $v64 - 4294967296 }
                    $valor = [int32]$v64
                } elseif ($b.Type -eq 'QWord') {
                    $vDec = [decimal]$b.Value
                    if ($vDec -gt [int64]::MaxValue) {
                        $valor = [BitConverter]::ToInt64([BitConverter]::GetBytes([uint64]$vDec), 0)
                    } else {
                        $valor = [int64]$vDec
                    }
                }
                if (-not (Test-Path -LiteralPath $b.Path)) {
                    New-Item -Path $b.Path -Force -ErrorAction Stop | Out-Null
                }
                New-ItemProperty -LiteralPath $b.Path -Name $b.Name -Value $valor -PropertyType $b.Type -Force -ErrorAction Stop | Out-Null
            } else {
                if (Test-Path -LiteralPath $b.Path) {
                    $item = Get-Item -LiteralPath $b.Path -ErrorAction Stop
                    if ($item.GetValueNames() -contains $b.Name) {
                        Remove-ItemProperty -LiteralPath $b.Path -Name $b.Name -Force -ErrorAction Stop
                    }
                }
            }
            Log "  restaurado: $($b.Path)\$($b.Name)" 'Green'
        } catch {
            $falhas++
            Registrar-Erro "Falha ao restaurar '$($b.Path)\$($b.Name)': $($_.Exception.Message)"
        }
    }

    if (Test-Path -LiteralPath $planoFile) {
        try {
            $guidPlano = [IO.File]::ReadAllText($planoFile, [Text.Encoding]::UTF8).Trim()
            if ([string]::IsNullOrWhiteSpace($guidPlano)) {
                throw "Arquivo de plano de energia vazio."
            }
            powercfg /setactive $guidPlano | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "powercfg /setactive retornou código $LASTEXITCODE."
            }
            Remove-Item -LiteralPath $planoFile -Force -ErrorAction Stop
            Log "  Plano de energia original restaurado" 'Green'
        } catch {
            $falhas++
            Registrar-Erro "Falha ao restaurar plano de energia: $($_.Exception.Message)"
        }
    }

    if ($falhas -eq 0) {
        if (Test-Path -LiteralPath $BackupFile) {
            try {
                $arquivoHistorico = Join-Path $BackupDir ("registro_restaurado_{0:yyyyMMdd_HHmm}.json" -f (Get-Date))
                Move-Item -LiteralPath $BackupFile -Destination $arquivoHistorico -Force -ErrorAction Stop
            } catch {
                Registrar-Erro "Restauração aplicada, mas não foi possível arquivar '$BackupFile': $($_.Exception.Message)"
            }
        }
        Log "Tudo restaurado. Reinicie o computador." 'Cyan'
    } else {
        Log "Restauração concluída com $falhas falha(s). O backup foi mantido em '$BackupDir' para nova tentativa." 'Red'
    }
    Pausa
}

# =====================================================================
# MODO AUTOMÁTICO (sem perguntas - para tarefa agendada / GPO / RMM)
# =====================================================================
if ($Automatico) {
    Log "Manutenção automática iniciada em $env:COMPUTERNAME" 'Cyan'
    try {
        ManutencaoCompleta
    } catch {
        Registrar-Erro "Erro inesperado durante a manutenção automática: $($_.Exception.Message)"
    }
    $qtdErrosExec = $Script:ErrosExecucao.Count
    $qtdCriticos = @($Script:Relatorio | Where-Object { $_.Status -eq 'erro' }).Count +
                   @($Script:Achados | Where-Object { $_.Gravidade -eq 'erro' }).Count
    if ($qtdErrosExec -gt 0) {
        Log ("Manutenção automática concluída com {0} erro(s) operacional(is)." -f $qtdErrosExec) 'Red'
        $Script:CodigoSaida = 1
    } elseif ($qtdCriticos -gt 0) {
        Log ("Manutenção automática concluída com {0} problema(s) crítico(s) no diagnóstico." -f $qtdCriticos) 'Yellow'
        $Script:CodigoSaida = 2
    } else {
        Log "Manutenção automática concluída sem problemas críticos." 'Cyan'
        $Script:CodigoSaida = 0
    }
} else {
    # =====================================================================
    # MENU
    # =====================================================================
    $continuarMenu = $true
    while ($continuarMenu) {
        Clear-Host
        Write-Host ""
        Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor DarkCyan
        Write-Host "  ║      OTIMIZADOR EMPRESARIAL  -  v1.1         ║" -ForegroundColor DarkCyan
        Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor DarkCyan
        $st = Get-StatusPC
        $corRam = if ($st.RamPct -ge 85) { 'Red' } elseif ($st.RamPct -ge 70) { 'Yellow' } else { 'Green' }
        $corUp  = if ($st.Uptime.TotalDays -ge 7) { 'Yellow' } else { 'Gray' }
        Write-Host ("   Estação ............ {0}" -f $env:COMPUTERNAME) -ForegroundColor Gray
        Write-Host ("   Ligado desde ....... {0:dd/MM/yyyy HH:mm}  (há {1} dia(s) e {2} h)" -f $st.LigadoDesde, $st.Uptime.Days, $st.Uptime.Hours) -ForegroundColor $corUp
        Write-Host ("   Último desligamento  {0}" -f $st.Desligamento) -ForegroundColor $(if ($st.Inesperado) { 'Red' } else { 'Gray' })
        Write-Host ("   Memória RAM ........ {0} {1:N0}%  ({2} de {3} em uso, {4} livre)" -f (Barra $st.RamPct), $st.RamPct, (FormatTam $st.RamUsada), (FormatTam $st.RamTotal), (FormatTam $st.RamLivre)) -ForegroundColor $corRam
        Write-Host ""
        Write-Host "    1. Diagnóstico completo + relatório HTML"
        Write-Host "    2. Análise de problemas (lentidão, travamentos, câmera, áudio, rede...)"
        Write-Host "    3. Limpeza de arquivos (todos os usuários)"
        Write-Host "    4. Otimização de desempenho para trabalho"
        Write-Host "    5. Programas que abrem com o Windows"
        Write-Host "    6. Diagnóstico e reparo de rede"
        Write-Host "    7. Verificar e reparar o Windows (DISM/SFC/disco)"
        Write-Host "    8. Atualizações do Windows e drivers"
        Write-Host "    9. Manutenção completa (limpeza + otimização + relatório)"
        Write-Host "   10. Desfazer otimizações"
        Write-Host "    0. Sair"
        Write-Host ""
        switch ((Read-Host "  Escolha uma opção").Trim()) {
            '1'  { Diagnostico }
            '2'  { AnaliseProblemas }
            '3'  { Limpeza }
            '4'  { Otimizar }
            '5'  { Inicializacao }
            '6'  { Rede }
            '7'  { Reparo }
            '8'  { Atualizacoes }
            '9'  { ManutencaoCompleta }
            '10' { Desfazer }
            '0'  { $continuarMenu = $false }
        }
    }
}

} finally {
    if ($Script:MutexInstancia) {
        if ($Script:MutexAdquirido) {
            try { $Script:MutexInstancia.ReleaseMutex() } catch { }
        }
        $Script:MutexInstancia.Dispose()
    }
}
exit $Script:CodigoSaida
