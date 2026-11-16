#Requires -Version 5.1
<#
    OTIMIZADOR DO PC - Limpeza, desempenho e jogos
    - Toda alteração de registro é salva em backup\registro.json e pode ser desfeita (opção 7)
    - Cria ponto de restauração antes de otimizar
    - Log de tudo em logs\
#>

# ---------- Autoelevação para Administrador ----------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$ErrorActionPreference = 'SilentlyContinue'
$Base       = Split-Path -Parent $PSCommandPath
$BackupDir  = Join-Path $Base 'backup'
$LogDir     = Join-Path $Base 'logs'
$BackupFile = Join-Path $BackupDir 'registro.json'
New-Item -ItemType Directory -Force -Path $BackupDir, $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("log_{0:yyyy-MM-dd_HH-mm}.txt" -f (Get-Date))

function Log($msg, $cor = 'Gray') {
    Write-Host $msg -ForegroundColor $cor
    Add-Content -Path $LogFile -Value ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $msg) -Encoding UTF8
}
function Titulo($t) { Write-Host ""; Log "=== $t ===" 'Cyan' }
function Pergunta($t) { $r = Read-Host "$t (S/N)"; return ($r -match '^[sSyY]') }
function Pausa { Write-Host ""; Read-Host "Pressione ENTER para voltar ao menu" | Out-Null }
function FormatTam([double]$b) {
    if ($b -ge 1GB) { return "{0:N2} GB" -f ($b / 1GB) }
    if ($b -ge 1MB) { return "{0:N1} MB" -f ($b / 1MB) }
    return "{0:N0} KB" -f ($b / 1KB)
}

# ---------- Registro com backup ----------
function Get-Backup {
    if (Test-Path $BackupFile) { return @(Get-Content $BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json) }
    return @()
}
function Set-RegSeguro($Path, $Name, $Value, $Type = 'DWord') {
    $backup = Get-Backup
    $jaSalvo = $backup | Where-Object { $_.Path -eq $Path -and $_.Name -eq $Name }
    if (-not $jaSalvo) {
        $existe = $false; $antigo = $null; $tipoAntigo = $null
        if (Test-Path $Path) {
            $item = Get-Item $Path
            if ($item.GetValueNames() -contains $Name) {
                $existe = $true
                $antigo = $item.GetValue($Name)
                $tipoAntigo = $item.GetValueKind($Name).ToString()
            }
        }
        $backup += [pscustomobject]@{ Path = $Path; Name = $Name; Existed = $existe; Value = $antigo; Type = $tipoAntigo }
        $backup | ConvertTo-Json -Depth 4 | Set-Content $BackupFile -Encoding UTF8
    }
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    Log "  [reg] $Path\$Name = $Value" 'DarkGray'
}

function Novo-PontoRestauracao {
    Log "Criando ponto de restauração do sistema..." 'Yellow'
    Enable-ComputerRestore -Drive "$env:SystemDrive\"
    try {
        Checkpoint-Computer -Description "Otimizador - antes das alteracoes" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Log "  Ponto de restauração criado." 'Green'
    } catch {
        Log "  Não foi possível criar agora (o Windows permite 1 a cada 24h). O backup do registro continua ativo." 'DarkYellow'
    }
}

# =====================================================================
# 1. DIAGNÓSTICO (somente leitura)
# =====================================================================
function Diagnostico {
    Titulo "DIAGNÓSTICO DO SISTEMA"
    $os  = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $gpu = Get-CimInstance Win32_VideoController
    $ramTotal = $os.TotalVisibleMemorySize * 1KB
    $ramLivre = $os.FreePhysicalMemory * 1KB
    $uptime = (Get-Date) - $os.LastBootUpTime

    Log ("Sistema : {0} (build {1})" -f $os.Caption, $os.BuildNumber)
    Log ("CPU     : {0} ({1} núcleos / {2} threads)" -f $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
    foreach ($g in $gpu) { Log ("GPU     : {0} (driver {1})" -f $g.Name, $g.DriverVersion) }
    Log ("RAM     : {0} total, {1} livre ({2:N0}% em uso)" -f (FormatTam $ramTotal), (FormatTam $ramLivre), (100 - $ramLivre / $ramTotal * 100))
    $corUp = 'Gray'; if ($uptime.TotalDays -gt 7) { $corUp = 'Yellow' }
    Log ("Ligado  : {0} dias {1} h {2}" -f $uptime.Days, $uptime.Hours, $(if ($uptime.TotalDays -gt 7) { '-> reinicie o PC, ajuda bastante' } else { '' })) $corUp

    Write-Host ""
    foreach ($d in Get-PhysicalDisk) { Log ("Disco   : {0} - {1} - {2}" -f $d.FriendlyName, $d.MediaType, (FormatTam $d.Size)) }
    foreach ($v in Get-Volume | Where-Object { $_.DriveLetter -and $_.Size -gt 0 }) {
        $pct = $v.SizeRemaining / $v.Size * 100
        $cor = 'Gray'; if ($pct -lt 15) { $cor = 'Red' }
        Log ("Unidade {0}: {1} livres de {2} ({3:N0}%)" -f $v.DriveLetter, (FormatTam $v.SizeRemaining), (FormatTam $v.Size), $pct) $cor
    }

    Write-Host ""
    $plano = (powercfg /getactivescheme) -replace '.*\((.*)\).*', '$1'
    Log "Plano de energia ativo: $plano"
    $gm = (Get-ItemProperty 'HKCU:\Software\Microsoft\GameBar').AutoGameModeEnabled
    Log ("Modo de Jogo: {0}" -f $(if ($gm -eq 0) { 'DESATIVADO' } else { 'ativado' }))
    $hags = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers').HwSchMode
    Log ("Agendamento de GPU acelerado por hardware: {0}" -f $(if ($hags -eq 2) { 'ativado' } else { 'desativado' }))
    $startup = @(Get-CimInstance Win32_StartupCommand)
    Log ("Programas na inicialização: {0}" -f $startup.Count)

    Write-Host ""
    Log "Top 10 processos por uso de memória:" 'Yellow'
    Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 10 | ForEach-Object {
        Log ("  {0,-30} {1,10}" -f $_.ProcessName, (FormatTam $_.WorkingSet64))
    }
    Pausa
}

# =====================================================================
# 2. LIMPEZA
# =====================================================================
function Limpar-Pasta($caminho, $descricao, [int]$diasMin = 0, [switch]$Quieto) {
    if (-not (Test-Path $caminho)) { return 0 }
    $limite = (Get-Date).AddDays(-$diasMin)
    $arquivos = Get-ChildItem $caminho -Recurse -Force -File | Where-Object { $_.LastWriteTime -lt $limite }
    $liberado = 0
    foreach ($a in $arquivos) {
        $tam = $a.Length
        Remove-Item $a.FullName -Force
        if (-not (Test-Path $a.FullName)) { $liberado += $tam }
    }
    # remove pastas vazias
    Get-ChildItem $caminho -Recurse -Force -Directory | Sort-Object { $_.FullName.Length } -Descending |
        Where-Object { -not (Get-ChildItem $_.FullName -Force) } | Remove-Item -Force
    if (-not $Quieto) { Log ("  {0,-42} {1}" -f $descricao, (FormatTam $liberado)) 'Green' }
    return $liberado
}

# ---------- Cache dos navegadores (NÃO mexe em histórico, senhas, cookies ou logins) ----------
$Navegadores = @(
    @{ Nome = 'Google Chrome';  Proc = 'chrome';  Tipo = 'Chromium'; Pasta = "$env:LOCALAPPDATA\Google\Chrome\User Data" }
    @{ Nome = 'Microsoft Edge'; Proc = 'msedge';  Tipo = 'Chromium'; Pasta = "$env:LOCALAPPDATA\Microsoft\Edge\User Data" }
    @{ Nome = 'Brave';          Proc = 'brave';   Tipo = 'Chromium'; Pasta = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data" }
    @{ Nome = 'Vivaldi';        Proc = 'vivaldi'; Tipo = 'Chromium'; Pasta = "$env:LOCALAPPDATA\Vivaldi\User Data" }
    @{ Nome = 'Opera';          Proc = 'opera';   Tipo = 'Opera';    Pasta = 'Opera Stable' }
    @{ Nome = 'Opera GX';       Proc = 'opera';   Tipo = 'Opera';    Pasta = 'Opera GX Stable' }
    @{ Nome = 'Firefox';        Proc = 'firefox'; Tipo = 'Firefox';  Pasta = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles" }
)

function Get-PastasCacheNavegador($nav) {
    $caches = @()
    switch ($nav.Tipo) {
        'Chromium' {
            if (-not (Test-Path $nav.Pasta)) { return @() }
            $caches += 'ShaderCache', 'GrShaderCache', 'GraphiteDawnCache' | ForEach-Object { Join-Path $nav.Pasta $_ }
            $perfis = Get-ChildItem $nav.Pasta -Directory -Force | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' }
            foreach ($p in $perfis) {
                $caches += 'Cache', 'Code Cache', 'GPUCache', 'DawnGraphiteCache', 'DawnWebGPUCache' | ForEach-Object { Join-Path $p.FullName $_ }
            }
        }
        'Opera' {
            foreach ($raiz in "$env:LOCALAPPDATA\Opera Software\$($nav.Pasta)", "$env:APPDATA\Opera Software\$($nav.Pasta)") {
                $caches += 'Cache', 'Code Cache', 'GPUCache', 'ShaderCache' | ForEach-Object { Join-Path $raiz $_ }
            }
        }
        'Firefox' {
            if (-not (Test-Path $nav.Pasta)) { return @() }
            foreach ($p in Get-ChildItem $nav.Pasta -Directory -Force) {
                $caches += 'cache2', 'startupCache', 'jumpListCache' | ForEach-Object { Join-Path $p.FullName $_ }
            }
        }
    }
    return @($caches | Where-Object { Test-Path $_ })
}

function Limpar-CacheNavegadores {
    $total = 0
    foreach ($nav in $Navegadores) {
        $pastas = Get-PastasCacheNavegador $nav
        if (-not $pastas) { continue }
        $procs = @(Get-Process -Name $nav.Proc -ErrorAction SilentlyContinue)
        if ($procs | Where-Object { $_.MainWindowHandle -ne 0 }) {
            if (Pergunta "  $($nav.Nome) está aberto. Fechar agora para limpar? (as abas voltam ao abrir de novo)") {
                $procs | ForEach-Object { [void]$_.CloseMainWindow() }
                Start-Sleep -Seconds 4
            } else {
                Log ("  {0,-42} pulado (navegador aberto)" -f "Cache do $($nav.Nome)") 'DarkYellow'
                continue
            }
        }
        $liberado = 0
        foreach ($p in $pastas) { $liberado += Limpar-Pasta $p '' 0 -Quieto }
        Log ("  {0,-42} {1}" -f "Cache do $($nav.Nome)", (FormatTam $liberado)) 'Green'
        $total += $liberado
    }
    return $total
}

function Limpeza {
    Titulo "LIMPEZA DE ARQUIVOS INÚTEIS"
    $antes = (Get-Volume -DriveLetter $env:SystemDrive[0]).SizeRemaining
    $total = 0

    $total += Limpar-Pasta $env:TEMP "Temporários do usuário (> 1 dia)" 1
    $total += Limpar-Pasta "$env:SystemRoot\Temp" "Temporários do Windows (> 1 dia)" 1
    $total += Limpar-Pasta "$env:LOCALAPPDATA\CrashDumps" "Despejos de travamento de apps"
    $total += Limpar-Pasta "$env:ProgramData\Microsoft\Windows\WER\ReportArchive" "Relatórios de erro (arquivados)"
    $total += Limpar-Pasta "$env:ProgramData\Microsoft\Windows\WER\ReportQueue" "Relatórios de erro (fila)"
    $total += Limpar-Pasta "$env:SystemRoot\Logs\CBS" "Logs antigos do Windows (> 7 dias)" 7
    $total += Limpar-Pasta "$env:LOCALAPPDATA\Microsoft\Windows\INetCache" "Cache de internet do sistema"

    # Cache de miniaturas
    $thumb = 0
    Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" -Filter 'thumbcache_*.db' -Force | ForEach-Object {
        $t = $_.Length; Remove-Item $_.FullName -Force; if (-not (Test-Path $_.FullName)) { $thumb += $t }
    }
    Log ("  {0,-42} {1}" -f "Cache de miniaturas", (FormatTam $thumb)) 'Green'; $total += $thumb

    # Cache do Windows Update
    Log "  Parando Windows Update para limpar o cache de downloads..." 'DarkGray'
    Stop-Service wuauserv, bits -Force
    $total += Limpar-Pasta "$env:SystemRoot\SoftwareDistribution\Download" "Downloads antigos do Windows Update"
    Start-Service wuauserv, bits

    # Otimização de Entrega
    $do = 0
    if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
        $do = (Get-DeliveryOptimizationStatus | Measure-Object -Property FileSize -Sum).Sum
        Delete-DeliveryOptimizationCache -Force
        Log ("  {0,-42} {1}" -f "Cache de Otimização de Entrega", (FormatTam $do)) 'Green'
    }

    # DNS
    Clear-DnsClientCache
    Log "  Cache DNS limpo" 'Green'

    Write-Host ""
    if (Pergunta "Limpar o cache dos navegadores? (histórico, senhas, cookies e logins NÃO são apagados)") {
        $total += Limpar-CacheNavegadores
    }
    if (Pergunta "Esvaziar a Lixeira? (exclusão PERMANENTE do que estiver nela)") {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Log "  Lixeira esvaziada" 'Green'
    }
    if (Pergunta "Limpar cache de shaders da GPU? (bom após atualizar driver ou se jogos travarem; 1ª abertura dos jogos fica um pouco mais lenta)") {
        $total += Limpar-Pasta "$env:LOCALAPPDATA\D3DSCache" "Cache de shaders DirectX"
        $total += Limpar-Pasta "$env:LOCALAPPDATA\NVIDIA\DXCache" "Cache de shaders NVIDIA (DX)"
        $total += Limpar-Pasta "$env:LOCALAPPDATA\NVIDIA\GLCache" "Cache de shaders NVIDIA (GL)"
        $total += Limpar-Pasta "$env:LOCALAPPDATA\AMD\DxCache" "Cache de shaders AMD"
    }
    if (Pergunta "Limpar componentes antigos do Windows (DISM)? Libera vários GB, mas leva de 5 a 20 min") {
        Log "  Executando DISM /StartComponentCleanup..." 'Yellow'
        Dism.exe /Online /Cleanup-Image /StartComponentCleanup | Out-Null
        Log "  Componentes antigos removidos" 'Green'
    }

    $depois = (Get-Volume -DriveLetter $env:SystemDrive[0]).SizeRemaining
    Write-Host ""
    Log ("ESPAÇO LIBERADO NO DISCO {0}: {1}" -f $env:SystemDrive, (FormatTam ([math]::Max(0, $depois - $antes)))) 'Cyan'
    Pausa
}

# =====================================================================
# 3. OTIMIZAÇÃO DE DESEMPENHO E JOGOS
# =====================================================================
function Ativar-PlanoMaximo {
    $ultimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    $atual = ((powercfg /getactivescheme) -split '\s+') | Where-Object { $_ -match '^[0-9a-f-]{36}$' } | Select-Object -First 1
    if (-not (Test-Path (Join-Path $BackupDir 'plano_energia.txt'))) { Set-Content (Join-Path $BackupDir 'plano_energia.txt') $atual }

    $existente = (powercfg /list) | Select-String 'Desempenho Máximo|Ultimate Performance|Desempenho Final'
    if ($existente) {
        $guid = ($existente[0].ToString() -split '\s+') | Where-Object { $_ -match '^[0-9a-f-]{36}$' } | Select-Object -First 1
    } else {
        $saida = powercfg -duplicatescheme $ultimate
        $guid = ($saida -split '\s+') | Where-Object { $_ -match '^[0-9a-f-]{36}$' } | Select-Object -First 1
    }
    if (-not $guid) { $guid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }  # Alto desempenho como alternativa
    powercfg /setactive $guid
    Log "  Plano de energia de desempenho máximo ativado" 'Green'
}

function Otimizar {
    Titulo "OTIMIZAÇÃO DE DESEMPENHO E JOGOS"
    $notebook = [bool](Get-CimInstance Win32_Battery)
    Novo-PontoRestauracao

    # Plano de energia
    if ($notebook) {
        if (Pergunta "Notebook detectado. Ativar plano de desempenho máximo? (gasta mais bateria; ideal na tomada)") { Ativar-PlanoMaximo }
    } else { Ativar-PlanoMaximo }

    # Modo de Jogo e gravação em segundo plano
    Log "Modo de Jogo e Xbox Game Bar:" 'Yellow'
    Set-RegSeguro 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
    Set-RegSeguro 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
    Set-RegSeguro 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
    Set-RegSeguro 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
    Log "  Modo de Jogo ativado, gravação em segundo plano desativada" 'Green'

    # GPU
    Log "Placa de vídeo:" 'Yellow'
    Set-RegSeguro 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
    Log "  Agendamento de GPU acelerado por hardware ativado (vale após reiniciar)" 'Green'

    # Prioridade multimídia para jogos
    Log "Prioridade de CPU/GPU para jogos:" 'Yellow'
    $mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    Set-RegSeguro $mm 'SystemResponsiveness' 10
    Set-RegSeguro $mm 'NetworkThrottlingIndex' 0xffffffff
    $games = "$mm\Tasks\Games"
    Set-RegSeguro $games 'GPU Priority' 8
    Set-RegSeguro $games 'Priority' 6
    Set-RegSeguro $games 'Scheduling Category' 'High' 'String'
    Set-RegSeguro $games 'SFIO Priority' 'High' 'String'
    Log "  Jogos recebem prioridade maior de CPU, GPU e disco" 'Green'

    # Efeitos visuais
    if (Pergunta "Reduzir animações e transparência do Windows? (deixa o sistema mais ágil)") {
        Set-RegSeguro 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
        Set-RegSeguro 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0
        Set-RegSeguro 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '50' 'String'
        Set-RegSeguro 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
        Log "  Animações e transparência reduzidas" 'Green'
    }

    # Mouse
    if (Pergunta "Desativar aceleração do mouse? (mira mais precisa em jogos de tiro)") {
        Set-RegSeguro 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
        Set-RegSeguro 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
        Set-RegSeguro 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String'
        Log "  Aceleração do mouse desativada" 'Green'
    }

    # Apps em segundo plano
    if (Pergunta "Impedir que apps da Microsoft Store rodem em segundo plano?") {
        Set-RegSeguro 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
        Set-RegSeguro 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0
        Log "  Apps da Store em segundo plano bloqueados" 'Green'
    }

    # SSD TRIM / HDD desfragmentação
    Log "Otimizando unidades (TRIM em SSD / desfragmentação em HD)..." 'Yellow'
    Optimize-Volume -DriveLetter $env:SystemDrive[0] -Verbose:$false
    Log "  Unidade do sistema otimizada" 'Green'

    Write-Host ""
    Log "Concluído! REINICIE o computador para aplicar tudo." 'Cyan'
    Log "Para desfazer: opção 7 do menu." 'Cyan'
    Pausa
}

# =====================================================================
# 4. PROGRAMAS NA INICIALIZAÇÃO
# =====================================================================
function Inicializacao {
    Titulo "PROGRAMAS QUE ABREM COM O WINDOWS"
    $itens = Get-CimInstance Win32_StartupCommand | Sort-Object Name
    $i = 0
    foreach ($s in $itens) { $i++; Log ("  {0,2}. {1,-35} {2}" -f $i, $s.Name, $s.Location) }
    Write-Host ""
    Write-Host "Dica: desative tudo que não precisa abrir sozinho (launchers de jogos, Spotify, Discord," -ForegroundColor Yellow
    Write-Host "atualizadores, OneDrive se não usa). Mantenha antivírus, drivers de áudio/vídeo e touchpad." -ForegroundColor Yellow
    if (Pergunta "Abrir o Gerenciador de Tarefas na aba Inicialização para desativar?") { Start-Process taskmgr.exe -ArgumentList '/0 /startup' }
    Pausa
}

# =====================================================================
# 5. REPARO DO WINDOWS
# =====================================================================
function Reparo {
    Titulo "VERIFICAÇÃO E REPARO DO WINDOWS"
    Write-Host "Isso corrige arquivos corrompidos do sistema (causa comum de lentidão e travamentos)."
    Write-Host "Pode levar de 10 a 30 minutos." -ForegroundColor Yellow
    if (-not (Pergunta "Continuar?")) { return }
    Log "Etapa 1/2: DISM RestoreHealth..." 'Yellow'
    Dism.exe /Online /Cleanup-Image /RestoreHealth
    Log "Etapa 2/2: SFC /scannow..." 'Yellow'
    sfc.exe /scannow
    Log "Reparo concluído." 'Green'
    Pausa
}

# =====================================================================
# 8. PLACA DE VÍDEO - identificação e melhor configuração
# =====================================================================
$TelaCode = @"
using System;
using System.Runtime.InteropServices;
public class Tela {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra;
        public int dmFields; public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
        public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight;
        public int dmDisplayFlags; public int dmDisplayFrequency; public int dmICMMethod; public int dmICMIntent;
        public int dmMediaType; public int dmDitherType; public int dmReserved1; public int dmReserved2;
        public int dmPanningWidth; public int dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet = CharSet.Ansi)] public static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
    [DllImport("user32.dll", CharSet = CharSet.Ansi)] public static extern int ChangeDisplaySettings(ref DEVMODE dm, int flags);
}
"@

function Novo-DevMode {
    if (-not ('Tela' -as [type])) { Add-Type -TypeDefinition $TelaCode }
    $dm = New-Object Tela+DEVMODE
    $dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'Tela+DEVMODE')
    return $dm
}

function Get-InfoTela {
    $atual = Novo-DevMode
    [void][Tela]::EnumDisplaySettings([NullString]::Value, -1, [ref]$atual)
    $freqs = @(); $i = 0
    $m = Novo-DevMode
    while ([Tela]::EnumDisplaySettings([NullString]::Value, $i, [ref]$m)) {
        if ($m.dmPelsWidth -eq $atual.dmPelsWidth -and $m.dmPelsHeight -eq $atual.dmPelsHeight -and $m.dmBitsPerPel -eq $atual.dmBitsPerPel) {
            $freqs += $m.dmDisplayFrequency
        }
        $i++
    }
    $max = ($freqs | Measure-Object -Maximum).Maximum
    if (-not $max) { $max = $atual.dmDisplayFrequency }
    return [pscustomobject]@{ Largura = $atual.dmPelsWidth; Altura = $atual.dmPelsHeight; Hz = $atual.dmDisplayFrequency; HzMax = $max }
}

function Set-FrequenciaTela([int]$hz) {
    $dm = Novo-DevMode
    [void][Tela]::EnumDisplaySettings([NullString]::Value, -1, [ref]$dm)
    $dm.dmDisplayFrequency = $hz
    $dm.dmFields = 0x400000   # DM_DISPLAYFREQUENCY
    return [Tela]::ChangeDisplaySettings([ref]$dm, 1)   # CDS_UPDATEREGISTRY
}

function Get-GPUs {
    # VRAM real fica no registro (o WMI limita a 4 GB)
    $vram = @{}
    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath
        $q = $p.'HardwareInformation.qwMemorySize'
        if ($p.DriverDesc -and $q) { $vram[$p.DriverDesc] = [double]$q }
    }
    Get-CimInstance Win32_VideoController | ForEach-Object {
        $fab = switch -Regex ($_.PNPDeviceID) { 'VEN_10DE' { 'NVIDIA' } 'VEN_1002' { 'AMD' } 'VEN_8086' { 'Intel' } default { 'Outro' } }
        $mem = $vram[$_.Name]; if (-not $mem) { $mem = [double]$_.AdapterRAM }
        $dedicada = ($fab -eq 'NVIDIA') -or
                    ($fab -eq 'AMD' -and $_.Name -notmatch 'Radeon\(TM\)\s*(Graphics|Vega)|^AMD Radeon(\(TM\))? Graphics') -or
                    ($fab -eq 'Intel' -and $_.Name -match 'Arc\(TM\)\s*[AB]\d')
        [pscustomobject]@{
            Nome = $_.Name; Fabricante = $fab; VRAM = $mem; Driver = $_.DriverVersion
            DataDriver = $_.DriverDate; Dedicada = $dedicada; RTX = ($_.Name -match 'RTX')
        }
    } | Where-Object { $_.Fabricante -ne 'Outro' }
}

function Set-DirectXGlobal($chave, $valor) {
    $p = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    $atual = (Get-ItemProperty $p).DirectXUserGlobalSettings
    $d = [ordered]@{}
    if ($atual) { foreach ($par in $atual -split ';') { if ($par -match '^(.+?)=(.*)$') { $d[$matches[1]] = $matches[2] } } }
    $d[$chave] = $valor
    $novo = (($d.Keys | ForEach-Object { "$_=$($d[$_])" }) -join ';') + ';'
    Set-RegSeguro $p 'DirectXUserGlobalSettings' $novo 'String'
}

function Get-PastasJogos {
    $pastas = @()
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam').SteamPath
    if ($steam) {
        $libs = @($steam)
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            $libs += Select-String -Path $vdf -Pattern '"path"\s+"(.+?)"' | ForEach-Object { $_.Matches[0].Groups[1].Value -replace '\\\\', '\' }
        }
        foreach ($l in $libs) { $pastas += Join-Path $l 'steamapps\common' }
    }
    foreach ($d in Get-PSDrive -PSProvider FileSystem) {
        $pastas += "$($d.Root)Program Files\Epic Games", "$($d.Root)Riot Games", "$($d.Root)Games", "$($d.Root)Jogos"
    }
    $pastas | Where-Object { Test-Path $_ } | ForEach-Object { (Resolve-Path $_).Path.TrimEnd('\') } | Sort-Object -Unique
}

function Recomendacoes-Painel($gpu) {
    Write-Host ""
    switch ($gpu.Fabricante) {
        'NVIDIA' {
            Log "Ajustes no Painel de Controle NVIDIA (botão direito na Área de Trabalho > Painel de Controle NVIDIA > Gerenciar configurações 3D > Configurações globais):" 'Yellow'
            Log "  - Modo de gerenciamento de energia ....... Preferir desempenho máximo"
            Log "  - Modo de baixa latência .................. Ativado (Ultra se o jogo não tiver NVIDIA Reflex)"
            Log "  - Filtragem de textura - Qualidade ........ Alto desempenho"
            Log "  - Tamanho do cache de sombreador .......... 10 GB"
            Log "  - Taxa de atualização preferida ........... Mais alta disponível"
            Log "  - Sincronização vertical .................. Desligado (ou Ligado só se usar G-SYNC)"
            Log "  - Se tiver G-SYNC: limite o FPS em 3 abaixo da taxa do monitor (ex.: 141 em 144 Hz)"
            if ($gpu.RTX) { Log "  Sua placa é RTX: ative DLSS (Qualidade ou Equilibrado) e NVIDIA Reflex nos jogos que tiverem." 'Green' }
        }
        'AMD' {
            Log "Ajustes no AMD Software: Adrenalin (botão direito na Área de Trabalho > AMD Software > Jogos > Gráficos):" 'Yellow'
            Log "  - Radeon Anti-Lag ......................... Ativado"
            Log "  - Radeon Chill ............................ Desativado"
            Log "  - Radeon Image Sharpening ................. Ativado (50% a 80%)"
            Log "  - Aguardar sincronização vertical ......... Desativado, a menos que o aplicativo especifique"
            Log "  - Cache de shader ......................... Otimizado AMD"
            Log "  - Aba Tela: AMD FreeSync .................. Ativado (se o monitor suportar)"
            Log "  Nos jogos, use FSR (Qualidade) para ganhar FPS." 'Green'
        }
        'Intel' {
            Log "Ajustes no Intel Graphics Software / Arc Control:" 'Yellow'
            Log "  - Perfil de energia ....................... Desempenho máximo"
            Log "  - Sincronização vertical .................. Controlado pelo aplicativo"
            Log "  - Use XeSS ou FSR (Qualidade/Equilibrado) nos jogos."
            if (-not $gpu.Dedicada) {
                Log "  Vídeo integrado usa a RAM do PC: memória em DUAL CHANNEL (2 pentes iguais) pode dar até +30% de FPS." 'Green'
            }
        }
    }
    $gb = $gpu.VRAM / 1GB
    $nivel = if ($gb -lt 3.5) { 'Baixo (texturas no mínimo, resolução 720p/900p ou upscaling)' }
             elseif ($gb -lt 6) { 'Médio (texturas médias)' }
             elseif ($gb -lt 10) { 'Alto (texturas altas)' }
             else { 'Ultra (texturas no máximo)' }
    Log ("  Qualidade de texturas recomendada para {0:N0} GB de VRAM: {1}" -f $gb, $nivel) 'Cyan'
}

function PlacaDeVideo {
    Titulo "PLACA DE VÍDEO - IDENTIFICAÇÃO E MELHOR CONFIGURAÇÃO"
    $gpus = @(Get-GPUs)
    if (-not $gpus) { Log "Nenhuma placa NVIDIA, AMD ou Intel encontrada." 'Red'; Pausa; return }

    foreach ($g in $gpus) {
        $idade = if ($g.DataDriver) { [int]((Get-Date) - $g.DataDriver).TotalDays } else { $null }
        Log ("{0}" -f $g.Nome) 'White'
        Log ("  Fabricante: {0} | Tipo: {1} | VRAM: {2}" -f $g.Fabricante, $(if ($g.Dedicada) { 'dedicada' } else { 'integrada' }), (FormatTam $g.VRAM))
        $cor = 'Gray'; $aviso = ''
        if ($idade -gt 180) { $cor = 'Yellow'; $aviso = ' -> driver antigo, use a opção 9 para atualizar' }
        Log ("  Driver: {0} de {1:dd/MM/yyyy} ({2} dias){3}" -f $g.Driver, $g.DataDriver, $idade, $aviso) $cor
    }
    $principal = $gpus | Sort-Object Dedicada, VRAM -Descending | Select-Object -First 1
    $hibrido = ($gpus | Where-Object Dedicada) -and ($gpus | Where-Object { -not $_.Dedicada })
    $tela = Get-InfoTela
    Log ("Monitor principal: {0}x{1} a {2} Hz (máximo suportado: {3} Hz)" -f $tela.Largura, $tela.Altura, $tela.Hz, $tela.HzMax)
    Write-Host ""
    if (-not (Pergunta "Aplicar a melhor configuração para $($principal.Nome)?")) { return }
    Novo-PontoRestauracao

    # 1) Taxa de atualização do monitor
    if ($tela.HzMax -gt $tela.Hz) {
        if (Pergunta "Seu monitor está em $($tela.Hz) Hz mas suporta $($tela.HzMax) Hz. Mudar para $($tela.HzMax) Hz?") {
            if (-not (Test-Path (Join-Path $BackupDir 'monitor_hz.txt'))) { Set-Content (Join-Path $BackupDir 'monitor_hz.txt') $tela.Hz }
            $r = Set-FrequenciaTela $tela.HzMax
            if ($r -eq 0) { Log "  Monitor agora em $($tela.HzMax) Hz" 'Green' } else { Log "  Não foi possível mudar (código $r). Mude em Configurações > Vídeo > Vídeo avançado." 'Red' }
        }
    } else { Log "  Monitor já está na taxa máxima ($($tela.Hz) Hz)" 'Green' }

    # 2) Agendamento de GPU por hardware + otimizações de jogos em janela
    Set-RegSeguro 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
    Set-DirectXGlobal 'SwapEffectUpgradeEnable' '1'
    Set-DirectXGlobal 'VRROptimizeEnable' '1'
    Log "  Agendamento de GPU por hardware, otimização de jogos em janela e taxa variável ativados" 'Green'

    # 3) PCI Express sem economia de energia (placa responde mais rápido)
    powercfg /setacvalueindex scheme_current SUB_PCIEXPRESS ASPM 0 | Out-Null
    powercfg /setactive scheme_current | Out-Null
    Log "  Economia de energia do PCI Express desligada (na tomada)" 'Green'

    # 4) Notebook com 2 placas: forçar jogos na placa dedicada
    if ($hibrido) {
        Write-Host ""
        Log "Seu PC tem vídeo integrado + dedicado. Jogos às vezes rodam na placa fraca por engano." 'Yellow'
        if (Pergunta "Procurar jogos instalados (Steam, Epic, Riot) e forçar todos na placa dedicada?") {
            $excluir = 'unins|setup|redist|crash|report|install|prereq|helper|updat|easyanticheat|battleye|dxsetup|dotnet|cef|webhelper|launcherpatcher|vc_?redist|bugsplat|handler'
            $n = 0
            foreach ($pasta in Get-PastasJogos) {
                Log "  Procurando em $pasta" 'DarkGray'
                Get-ChildItem $pasta -Recurse -Depth 4 -Filter *.exe -File |
                    Where-Object { $_.Name -notmatch $excluir -and $_.Length -gt 1MB } | ForEach-Object {
                        Set-RegSeguro 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' $_.FullName 'GpuPreference=2;' 'String'
                        $n++
                    }
            }
            Log "  $n executáveis de jogos configurados para usar a placa dedicada" 'Green'
            Log "  Para outros jogos: Configurações > Sistema > Vídeo > Elementos gráficos > Alto desempenho" 'Gray'
        }
    }

    Recomendacoes-Painel $principal
    Write-Host ""
    if (Pergunta "Abrir as configurações de Elementos Gráficos do Windows?") { Start-Process 'ms-settings:display-advancedgraphics' }
    Log "Concluído! Reinicie o PC para o agendamento de GPU valer." 'Cyan'
    Pausa
}

# =====================================================================
# 9. ATUALIZAR DRIVERS
# =====================================================================
function Drivers {
    Titulo "ATUALIZAÇÃO DE DRIVERS"

    # Dispositivos com problema (22 = desativado pelo usuário, ignora)
    $prob = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -notin 22, 24, 45 })
    if ($prob) {
        Log "Dispositivos com problema ou sem driver:" 'Red'
        foreach ($p in $prob) { Log ("  - {0} (código {1})" -f $(if ($p.Name) { $p.Name } else { $p.DeviceID }), $p.ConfigManagerErrorCode) 'Red' }
    } else { Log "Nenhum dispositivo com problema no Gerenciador de Dispositivos." 'Green' }

    Write-Host ""
    Log "Procurando drivers novos no Windows Update (pode levar alguns minutos)..." 'Yellow'
    try {
        $sessao = New-Object -ComObject Microsoft.Update.Session
        $res = $sessao.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
    } catch {
        Log "Não foi possível consultar o Windows Update: $($_.Exception.Message)" 'Red'
        $res = $null
    }

    if ($res -and $res.Updates.Count -gt 0) {
        $lista = @(); for ($i = 0; $i -lt $res.Updates.Count; $i++) { $lista += $res.Updates.Item($i) }
        $temVideo = $false
        for ($i = 0; $i -lt $lista.Count; $i++) {
            $u = $lista[$i]
            if ($u.DriverClass -eq 'Display') { $temVideo = $true }
            Log ("  {0,2}. [{1}] {2}" -f ($i + 1), $u.DriverClass, $u.Title)
        }
        Write-Host ""
        if (Pergunta "Instalar estes $($lista.Count) drivers?") {
            $incluirVideo = $true
            if ($temVideo) {
                Write-Host "O driver de vídeo do Windows Update costuma ser mais antigo que o do fabricante." -ForegroundColor Yellow
                $incluirVideo = Pergunta "Instalar mesmo assim o driver de VÍDEO pelo Windows Update? (recomendado: N, e usar o app do fabricante abaixo)"
            }
            Novo-PontoRestauracao
            $col = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($u in $lista) {
                if ($u.DriverClass -eq 'Display' -and -not $incluirVideo) { continue }
                if (-not $u.EulaAccepted) { $u.AcceptEula() }
                [void]$col.Add($u)
            }
            if ($col.Count -gt 0) {
                try {
                    Log "Baixando $($col.Count) drivers..." 'Yellow'
                    $dl = $sessao.CreateUpdateDownloader(); $dl.Updates = $col; [void]$dl.Download()
                    Log "Instalando..." 'Yellow'
                    $inst = $sessao.CreateUpdateInstaller(); $inst.Updates = $col
                    $r = $inst.Install()
                    for ($i = 0; $i -lt $col.Count; $i++) {
                        $cod = $r.GetUpdateResult($i).ResultCode
                        $txt = switch ($cod) { 2 { 'OK' } 3 { 'OK com avisos' } 4 { 'FALHOU' } 5 { 'cancelado' } default { "código $cod" } }
                        $cor = if ($cod -in 2, 3) { 'Green' } else { 'Red' }
                        Log ("  [{0}] {1}" -f $txt, $col.Item($i).Title) $cor
                    }
                    if ($r.RebootRequired) { Log "Reinicie o computador para concluir a instalação." 'Cyan' }
                } catch { Log "Erro na instalação: $($_.Exception.Message)" 'Red' }
            }
        }
    } elseif ($res) {
        Log "Todos os drivers disponíveis no Windows Update já estão instalados." 'Green'
    }

    # Driver da placa de vídeo pelo fabricante (sempre a versão mais nova)
    Write-Host ""
    Log "Driver da placa de vídeo (direto do fabricante - versão mais nova e otimizada para jogos):" 'Yellow'
    $links = @{
        'NVIDIA' = @('NVIDIA App', 'https://www.nvidia.com/pt-br/drivers/')
        'AMD'    = @('AMD Software: Adrenalin Edition', 'https://www.amd.com/pt/support/download/drivers.html')
        'Intel'  = @('Intel Driver & Support Assistant', 'https://www.intel.com/content/www/us/en/support/detect.html')
    }
    $fabs = @(Get-GPUs | Select-Object -ExpandProperty Fabricante -Unique)
    foreach ($f in $fabs) {
        Log ("  {0}: baixe o {1} em {2}" -f $f, $links[$f][0], $links[$f][1])
        if (Pergunta "  Abrir a página oficial de drivers da $f no navegador?") { Start-Process $links[$f][1] }
    }
    Write-Host ""
    Log "Dica: drivers de chipset/placa-mãe ficam no site do fabricante do PC ou da placa-mãe (Dell, Lenovo, ASUS, Gigabyte...)." 'Gray'
    Pausa
}

# =====================================================================
# 6. RODAR TUDO
# =====================================================================
function RodarTudo {
    Limpeza
    Otimizar
    PlacaDeVideo
}

# =====================================================================
# 7. DESFAZER
# =====================================================================
function Desfazer {
    Titulo "DESFAZER OTIMIZAÇÕES"
    $backup = Get-Backup
    $hzFile = Join-Path $BackupDir 'monitor_hz.txt'
    if (-not $backup -and -not (Test-Path $hzFile)) { Log "Nenhum backup encontrado. Nada a desfazer." 'Yellow'; Pausa; return }
    if (-not (Pergunta "Restaurar $($backup.Count) configurações ao valor original?")) { return }
    if (Test-Path $hzFile) {
        $hz = [int](Get-Content $hzFile).Trim()
        if ((Set-FrequenciaTela $hz) -eq 0) { Log "  Monitor voltou para $hz Hz" 'Green' }
        Remove-Item $hzFile -Force
    }
    foreach ($b in $backup) {
        if ($b.Existed) {
            $valor = $b.Value
            if ($b.Type -eq 'DWord') { $valor = [int64]$b.Value; if ($valor -gt [int32]::MaxValue) { $valor = [int32]($valor - 4294967296) } }
            New-ItemProperty -Path $b.Path -Name $b.Name -Value $valor -PropertyType $b.Type -Force | Out-Null
        } else {
            Remove-ItemProperty -Path $b.Path -Name $b.Name -Force
        }
        Log "  restaurado: $($b.Path)\$($b.Name)" 'Green'
    }
    $planoFile = Join-Path $BackupDir 'plano_energia.txt'
    if (Test-Path $planoFile) {
        powercfg /setactive (Get-Content $planoFile).Trim()
        Remove-Item $planoFile -Force
        Log "  Plano de energia original restaurado" 'Green'
    }
    if (Test-Path $BackupFile) { Move-Item $BackupFile (Join-Path $BackupDir ("registro_restaurado_{0:yyyyMMdd_HHmm}.json" -f (Get-Date))) -Force }
    Log "Tudo restaurado. Reinicie o computador." 'Cyan'
    Pausa
}

# =====================================================================
# MENU
# =====================================================================
while ($true) {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║          OTIMIZADOR DO PC  -  v1.1           ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "   1. Diagnóstico do sistema (só leitura)"
    Write-Host "   2. Limpeza de arquivos inúteis"
    Write-Host "   3. Otimização de desempenho e jogos"
    Write-Host "   4. Programas que abrem com o Windows"
    Write-Host "   5. Verificar e reparar o Windows (SFC/DISM)"
    Write-Host "   6. RODAR TUDO (limpeza + otimização + placa de vídeo)" -ForegroundColor Green
    Write-Host "   7. Desfazer otimizações" -ForegroundColor Yellow
    Write-Host "   8. Placa de vídeo: identificar e configurar" -ForegroundColor Magenta
    Write-Host "   9. Atualizar drivers" -ForegroundColor Magenta
    Write-Host "   0. Sair"
    Write-Host ""
    switch (Read-Host "  Escolha uma opção") {
        '1' { Diagnostico }
        '2' { Limpeza }
        '3' { Otimizar }
        '4' { Inicializacao }
        '5' { Reparo }
        '6' { RodarTudo }
        '7' { Desfazer }
        '8' { PlacaDeVideo }
        '9' { Drivers }
        '0' { exit }
    }
}
