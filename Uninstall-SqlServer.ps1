#Requires -Version 5.1
<#
================================================================================
  SQL Server Complete Removal Utility  (Windows)
  Elimina TODO rastro de SQL Server (todas las versiones) y SSMS:
  instancias, servicios, binarios, datos, temporales, claves de registro.
  Deja el sistema listo para una reinstalacion limpia desde cero.

  Incluye un asistente grafico previo a la desinstalacion (bienvenida,
  terminos y condiciones, deteccion, confirmacion y progreso en vivo),
  similar en formato a un instalador convencional.

  Desarrollado por: Kisnner Obando
  Esta herramienta es INDEPENDIENTE: no es un producto oficial de Microsoft,
  ni esta afiliada, respaldada o asociada con Microsoft Corporation.
  "SQL Server" y "SQL Server Management Studio" son marcas registradas de
  Microsoft Corporation, mencionadas aqui solo con fines descriptivos.
================================================================================
  USO:
    # Doble clic en "Ejecutar-Desinstalador.cmd" (recomendado, se autoeleva), o:
    # Abrir PowerShell (no hace falta "Como Administrador": el asistente se
    # reabre solo con privilegios elevados si hace falta) y ejecutar:
    .\Uninstall-SqlServer.ps1                 # asistente grafico (por defecto)

    # Modo automatizacion / scripting, sin interfaz grafica:
    .\Uninstall-SqlServer.ps1 -NoGui                 # pide confirmacion "SI" por consola
    .\Uninstall-SqlServer.ps1 -NoGui -WhatIf         # simulacion: muestra que haria, no borra
    .\Uninstall-SqlServer.ps1 -NoGui -Force          # sin preguntar (peligroso)
    .\Uninstall-SqlServer.ps1 -NoGui -KeepData       # rescata .mdf/.ndf/.ldf/.bak antes de borrar

  Si aparece "no se puede cargar el script", ejecuta primero:
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
================================================================================
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$NoGui,
    [switch]$Force,
    [switch]$KeepData
)

$ErrorActionPreference = 'Continue'

# ============================================================================
#  UTILIDADES COMUNES (usadas tanto por el modo -NoGui como por el asistente)
# ============================================================================

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-DefaultLogPath {
    Join-Path $env:TEMP ("SQLServer_Removal_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
}

function Get-EulaText {
    @"
TERMINOS Y CONDICIONES DE USO
================================================================================

1. NATURALEZA DE LA HERRAMIENTA
   Este programa es una utilidad INDEPENDIENTE desarrollada por Kisnner
   Obando. NO es un producto oficial de Microsoft, no esta afiliado,
   respaldado ni asociado con Microsoft Corporation. "SQL Server" y "SQL
   Server Management Studio" son marcas registradas de Microsoft
   Corporation, mencionadas aqui unicamente con fines descriptivos.

2. NATURALEZA DESTRUCTIVA E IRREVERSIBLE
   Esta herramienta ELIMINA DE FORMA PERMANENTE: los servicios e instancias
   de SQL Server, los programas instalados (SSMS, herramientas, ODBC,
   PolyBase, Reporting/Analysis/Integration Services), TODAS las bases de
   datos y archivos de datos (.mdf/.ndf/.ldf/.bak salvo que actives
   "conservar datos"), carpetas y binarios, claves del registro de Windows,
   accesos directos y archivos temporales relacionados. Esta accion NO SE
   PUEDE DESHACER.

3. RESPONSABILIDAD DEL USUARIO
   Es tu responsabilidad haber realizado una copia de seguridad de
   cualquier dato que necesites conservar antes de continuar. Se
   recomienda usar primero el modo simulacion para revisar exactamente
   que se eliminaria.

4. SIN GARANTIA
   Esta herramienta se entrega "TAL CUAL", sin garantia de ningun tipo. El
   autor no se hace responsable de perdida de datos, tiempo de
   inactividad, o cualquier dano derivado de su uso.

5. PERMISOS
   Requiere privilegios de Administrador para ejecutarse, ya que modifica
   servicios del sistema, el registro de Windows y archivos protegidos.

Al continuar, confirmas que has leido y aceptas estos terminos.
================================================================================
"@
}

# ============================================================================
#  ESCANEO (solo lectura) - usado por la pantalla "Detectado" del asistente
# ============================================================================
function Get-ScanSummary {
    $svcPatterns = @('MSSQL*','SQLSERVERAGENT','SQLAgent*','SQLBrowser','SQLWriter','SQLTELEMETRY*',
                     'MSSQLFDLauncher*','MSSQLServerOLAPService','SSASTELEMETRY*','msftesql*',
                     'ReportServer*','SQLServerReportingServices','MsDtsServer*','SSISTELEMETRY*',
                     'SQLPBDMS*','SQLPBENGINE*','MSSQLLaunchpad*')
    $svcCount = (Get-Service -ErrorAction SilentlyContinue |
                 Where-Object { $n = $_.Name; $svcPatterns | Where-Object { $n -like $_ } } |
                 Select-Object -Unique).Count

    $namePatterns = @('*SQL Server*','*SQL Server Management Studio*','*Microsoft SQL*',
                      '*Native Client*','*SQL Server 20*','*Reporting Services*','*Analysis Services*',
                      '*Integration Services*','*Command Line Utilities*','*ODBC Driver*for SQL Server*',
                      '*Data-Tier*','*SQLXML*','*SQL Server Setup*','*Browser for SQL Server*')
    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $productCount = (
        (foreach ($root in $uninstallRoots) {
            Get-ItemProperty $root -ErrorAction SilentlyContinue | Where-Object {
                $dn = $_.DisplayName; $dn -and ($namePatterns | Where-Object { $dn -like $_ })
            }
        }) | Sort-Object DisplayName -Unique
    ).Count

    $folderPatterns = @(
        "$env:ProgramFiles\Microsoft SQL Server", "${env:ProgramFiles(x86)}\Microsoft SQL Server",
        "$env:ProgramFiles\Microsoft SQL Server Management Studio*", "${env:ProgramFiles(x86)}\Microsoft SQL Server Management Studio*",
        "$env:ProgramData\Microsoft\SQL Server", "$env:ProgramData\Microsoft\Microsoft SQL Server", "$env:ProgramData\Microsoft SQL Server"
    )
    $folderCount = ($folderPatterns | ForEach-Object { Get-Item -Path $_ -ErrorAction SilentlyContinue } | Select-Object -Unique).Count

    [pscustomobject]@{ Services = $svcCount; Products = $productCount; Folders = $folderCount }
}

# ============================================================================
#  MOTOR DE DESINSTALACION (compartido por el modo -NoGui y el asistente)
#  Si se le pasa -SyncHash, reporta el progreso ahi (para la GUI); si no,
#  imprime en consola con Write-Host (modo -NoGui).
# ============================================================================
function Invoke-SqlRemoval {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][bool]$DryRun,
        [bool]$KeepData,
        [Parameter(Mandatory)][string]$LogFile,
        [hashtable]$SyncHash
    )

    $removed = 0; $skipped = 0; $failed = 0
    $totalSteps = 8

    function local:Emit {
        param([string]$Level, [string]$Message)
        $ts = Get-Date -Format 'HH:mm:ss'
        $line = "[$ts] [$Level] $Message"
        Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
        if ($SyncHash) {
            [void]$SyncHash.Log.Add(@{ Level = $Level; Message = $Message })
        } else {
            $color = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'STEP' { 'Cyan' } default { 'Gray' } }
            Write-Host $line -ForegroundColor $color
        }
    }
    function local:SetStep {
        param([int]$N, [string]$Label)
        if ($SyncHash) { $SyncHash.Step = $N; $SyncHash.Total = $totalSteps; $SyncHash.StepLabel = $Label }
    }

    # ================================================================= 1. PROCESOS
    SetStep 1 'Deteniendo procesos...'
    Emit 'STEP' 'PASO 1/8 - Deteniendo procesos de SQL Server...'
    $procNames = @('sqlservr','sqlwriter','sqlbrowser','SQLAGENT','msmdsrv','ReportingServicesService',
                   'MsDtsSrvr','SQLServerManager','Ssms','SqlToolsPS','fdlauncher','fdhost','SQLPS','SqlDumper')
    foreach ($pn in $procNames) {
        Get-Process -Name $pn -ErrorAction SilentlyContinue | ForEach-Object {
            if ($DryRun) {
                Emit 'INFO' "(simulado) Detendria proceso: $($_.Name) (PID $($_.Id))"
            } elseif ($PSCmdlet.ShouldProcess("Proceso $($_.Name) (PID $($_.Id))", 'Detener')) {
                try { Stop-Process -Id $_.Id -Force -ErrorAction Stop; Emit 'OK' "Proceso detenido: $($_.Name)" }
                catch { Emit 'WARN' "No se pudo detener $($_.Name): $($_.Exception.Message)" }
            }
        }
    }

    # ================================================================= 2. SERVICIOS
    SetStep 2 'Deteniendo servicios...'
    Emit 'STEP' 'PASO 2/8 - Deteniendo y deshabilitando servicios...'
    $svcPatterns = @('MSSQL*','SQLSERVERAGENT','SQLAgent*','SQLBrowser','SQLWriter','SQLTELEMETRY*',
                     'MSSQLFDLauncher*','MSSQLServerOLAPService','SSASTELEMETRY*','msftesql*',
                     'ReportServer*','SQLServerReportingServices','MsDtsServer*','SSISTELEMETRY*',
                     'SQLPBDMS*','SQLPBENGINE*','MSSQLLaunchpad*')
    $services = Get-Service -ErrorAction SilentlyContinue |
                Where-Object { $n = $_.Name; $svcPatterns | Where-Object { $n -like $_ } } |
                Select-Object -Unique
    foreach ($svc in $services) {
        if ($DryRun) {
            Emit 'INFO' "(simulado) Detendria y deshabilitaria servicio: $($svc.Name)"
        } elseif ($PSCmdlet.ShouldProcess("Servicio $($svc.Name)", 'Detener y deshabilitar')) {
            try {
                Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
                Set-Service  -Name $svc.Name -StartupType Disabled -ErrorAction SilentlyContinue
                Emit 'OK' "Servicio detenido/deshabilitado: $($svc.Name)"
            } catch { Emit 'WARN' "Problema con servicio $($svc.Name): $($_.Exception.Message)" }
        }
    }

    # ============================================= 3. DESINSTALACION OFICIAL (MSI/setup)
    SetStep 3 'Desinstalando programas...'
    Emit 'STEP' 'PASO 3/8 - Desinstalando productos mediante sus desinstaladores oficiales...'
    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $namePatterns = @('*SQL Server*','*SQL Server Management Studio*','*Microsoft SQL*',
                      '*Native Client*','*SQL Server 20*','*Reporting Services*','*Analysis Services*',
                      '*Integration Services*','*Command Line Utilities*','*ODBC Driver*for SQL Server*',
                      '*Data-Tier*','*SQLXML*','*SQL Server Setup*','*Browser for SQL Server*')

    $products = foreach ($root in $uninstallRoots) {
        Get-ItemProperty $root -ErrorAction SilentlyContinue | Where-Object {
            $dn = $_.DisplayName
            $dn -and ($namePatterns | Where-Object { $dn -like $_ })
        }
    }
    $products = $products | Sort-Object DisplayName -Unique

    if (-not $products) {
        Emit 'INFO' 'No se encontraron productos SQL registrados para desinstalar.'
    }
    foreach ($p in $products) {
        $name = $p.DisplayName
        $cmd  = $p.UninstallString
        if (-not $cmd) { $skipped++; Emit 'INFO' "Sin UninstallString, se limpiara por fuerza: $name"; continue }

        if ($DryRun) {
            Emit 'INFO' "(simulado) Desinstalaria: $name"
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($name, 'Desinstalar (silencioso)')) { continue }
        try {
            if ($cmd -match 'msiexec') {
                if ($cmd -match '\{[0-9A-Fa-f\-]+\}') {
                    $guid = $Matches[0]
                    Emit 'INFO' "Desinstalando (MSI): $name"
                    Start-Process 'msiexec.exe' -ArgumentList "/x $guid /qn /norestart REBOOT=ReallySuppress" -Wait -NoNewWindow
                    $removed++
                }
            }
            elseif ($cmd -match 'setup\.exe') {
                if ($cmd -match '^\s*"([^"]+)"') { $exe = $Matches[1] }
                else { $exe = ($cmd -split '(?<=\.exe)', 2)[0].Trim() }
                if (Test-Path $exe) {
                    Emit 'INFO' "Desinstalando (setup.exe): $name"
                    Start-Process $exe -ArgumentList '/Action=Uninstall /Q /HIDEPROGRESSBAR /IACCEPTSQLSERVERLICENSETERMS' -Wait -NoNewWindow -ErrorAction SilentlyContinue
                    $removed++
                } else {
                    Emit 'WARN' "setup.exe no encontrado para ${name}: $exe (se limpiara por fuerza mas adelante)"
                    $skipped++
                }
            }
            else {
                Emit 'INFO' "Desinstalando (generico): $name"
                Start-Process 'cmd.exe' -ArgumentList "/c `"$cmd`" /quiet /norestart" -Wait -NoNewWindow -ErrorAction SilentlyContinue
                $removed++
            }
        } catch {
            Emit 'WARN' "Fallo desinstalando ${name}: $($_.Exception.Message)"
            $failed++
        }
    }

    # ================================================================= 4. SERVICIOS (borrado)
    SetStep 4 'Eliminando servicios residuales...'
    Emit 'STEP' 'PASO 4/8 - Eliminando definiciones de servicios residuales...'
    $services = Get-Service -ErrorAction SilentlyContinue |
                Where-Object { $n = $_.Name; $svcPatterns | Where-Object { $n -like $_ } } |
                Select-Object -Unique
    foreach ($svc in $services) {
        if ($DryRun) {
            Emit 'INFO' "(simulado) Eliminaria servicio: $($svc.Name)"
        } elseif ($PSCmdlet.ShouldProcess("Servicio $($svc.Name)", 'Eliminar (sc delete)')) {
            try {
                & sc.exe delete $svc.Name | Out-Null
                Emit 'OK' "Servicio eliminado: $($svc.Name)"
                $removed++
            } catch { Emit 'WARN' "No se pudo eliminar servicio $($svc.Name)"; $failed++ }
        }
    }

    # ================================================================= 5. CARPETAS
    SetStep 5 'Eliminando carpetas y datos...'
    Emit 'STEP' 'PASO 5/8 - Eliminando carpetas y binarios...'
    $folders = @(
        "$env:ProgramFiles\Microsoft SQL Server",
        "${env:ProgramFiles(x86)}\Microsoft SQL Server",
        "$env:ProgramFiles\Microsoft SQL Server Management Studio*",
        "${env:ProgramFiles(x86)}\Microsoft SQL Server Management Studio*",
        "$env:ProgramFiles\Microsoft SQL Server Tools*",
        "${env:ProgramFiles(x86)}\Microsoft SQL Server Tools*",
        "$env:ProgramData\Microsoft\SQL Server",
        "$env:ProgramData\Microsoft\Microsoft SQL Server",
        "$env:ProgramData\Microsoft SQL Server",
        "$env:ProgramFiles\Microsoft SQL Server Compact Edition",
        "${env:ProgramFiles(x86)}\Microsoft SQL Server Compact Edition",
        "$env:APPDATA\Microsoft\SQL Server Management Studio",
        "$env:LOCALAPPDATA\Microsoft\SQL Server Management Studio",
        "$env:LOCALAPPDATA\Microsoft\Microsoft SQL Server*"
    )

    if ($KeepData) {
        $rescueDir = "$env:SystemDrive\SQLServer_DataBackup_{0:yyyyMMdd_HHmmss}" -f (Get-Date)
        $dataFiles = foreach ($pattern in $folders) {
            Get-Item -Path $pattern -ErrorAction SilentlyContinue | ForEach-Object {
                Get-ChildItem -LiteralPath $_.FullName -Recurse -Include '*.mdf','*.ndf','*.ldf','*.bak' -File -ErrorAction SilentlyContinue
            }
        }
        if ($dataFiles) {
            if ($DryRun) {
                Emit 'INFO' "(simulado) Rescataria $($dataFiles.Count) archivo(s) de datos a $rescueDir"
            } elseif ($PSCmdlet.ShouldProcess("$($dataFiles.Count) archivos de datos -> $rescueDir", 'Rescatar')) {
                New-Item -ItemType Directory -Path $rescueDir -Force | Out-Null
                foreach ($f in $dataFiles) {
                    try {
                        $dest = Join-Path $rescueDir $f.Name
                        $n = 1
                        while (Test-Path -LiteralPath $dest) {
                            $dest = Join-Path $rescueDir ("{0}_{1}" -f $n, $f.Name); $n++
                        }
                        Copy-Item -LiteralPath $f.FullName -Destination $dest -ErrorAction Stop
                        Emit 'OK' "Dato rescatado: $($f.FullName) -> $dest"
                    } catch { Emit 'WARN' "No se pudo rescatar: $($f.FullName)"; $failed++ }
                }
                Emit 'INFO' "Datos rescatados en: $rescueDir"
            }
        } else {
            Emit 'INFO' 'KeepData: no se encontraron archivos .mdf/.ndf/.ldf/.bak que rescatar.'
        }
    }

    foreach ($pattern in $folders) {
        Get-Item -Path $pattern -ErrorAction SilentlyContinue | ForEach-Object {
            $path = $_.FullName
            if ($DryRun) {
                Emit 'INFO' "(simulado) Eliminaria carpeta: $path"
                return
            }
            if (-not ($PSCmdlet.ShouldProcess($path, 'Eliminar carpeta'))) { return }
            try {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                Emit 'OK' "Carpeta eliminada: $path"
                $removed++
            } catch {
                try {
                    & takeown /F "$path" /R /D Y 2>&1 | Out-Null
                    & takeown /F "$path" /R /D S 2>&1 | Out-Null
                    & icacls "$path" /grant "*S-1-5-32-544:F" /T /C 2>&1 | Out-Null
                    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                    Emit 'OK' "Carpeta eliminada (tras takeown): $path"
                    $removed++
                } catch {
                    Emit 'ERROR' "No se pudo eliminar: $path ($($_.Exception.Message))"
                    $failed++
                }
            }
        }
    }

    # ================================================================= 6. REGISTRO
    SetStep 6 'Eliminando claves del registro...'
    Emit 'STEP' 'PASO 6/8 - Eliminando claves del registro...'
    $regKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SQL Server',
        'HKLM:\SOFTWARE\Microsoft\MSSQLServer',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\MSSQLServer',
        'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server Management Studio',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SQL Server Management Studio',
        'HKLM:\SOFTWARE\Microsoft\SQLNCLI*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\SQLNCLI*',
        'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server 20*',
        'HKLM:\SOFTWARE\Microsoft\SQLServer*',
        'HKLM:\SYSTEM\CurrentControlSet\Services\MSSQL*',
        'HKLM:\SYSTEM\CurrentControlSet\Services\SQLAgent*',
        'HKLM:\SYSTEM\CurrentControlSet\Services\SQLBrowser',
        'HKLM:\SYSTEM\CurrentControlSet\Services\SQLWriter',
        'HKLM:\SYSTEM\CurrentControlSet\Services\MSSQLServerOLAPService',
        'HKLM:\SYSTEM\CurrentControlSet\Services\ReportServer*',
        'HKCU:\SOFTWARE\Microsoft\SQL Server Management Studio',
        'HKCU:\SOFTWARE\Microsoft\Microsoft SQL Server'
    )
    foreach ($pattern in $regKeys) {
        Get-Item -Path $pattern -ErrorAction SilentlyContinue | ForEach-Object {
            $key = $_.PSPath
            $disp = $_.Name
            if ($DryRun) {
                Emit 'INFO' "(simulado) Eliminaria clave de registro: $disp"
                return
            }
            if (-not ($PSCmdlet.ShouldProcess($disp, 'Eliminar clave de registro'))) { return }
            try {
                Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction Stop
                Emit 'OK' "Clave eliminada: $disp"
                $removed++
            } catch {
                Emit 'WARN' "No se pudo eliminar clave: $disp ($($_.Exception.Message))"
                $failed++
            }
        }
    }

    # =========================================== 7. TEMPORALES, ACCESOS Y VARIABLES
    SetStep 7 'Limpiando temporales y accesos directos...'
    Emit 'STEP' 'PASO 7/8 - Limpiando temporales, accesos directos y variables PATH...'

    $tempPatterns = @(
        "$env:TEMP\SqlSetup*", "$env:TEMP\*SQL*log*", "$env:windir\Temp\SqlSetup*",
        "$env:SystemDrive\*SQLServer*.log"
    )
    foreach ($tp in $tempPatterns) {
        Get-Item -Path $tp -ErrorAction SilentlyContinue | ForEach-Object {
            if ($DryRun) { Emit 'INFO' "(simulado) Eliminaria temporal: $($_.FullName)"; return }
            try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                  Emit 'OK' "Temporal eliminado: $($_.FullName)"; $removed++ }
            catch { Emit 'WARN' "No se pudo eliminar temporal: $($_.FullName)"; $failed++ }
        }
    }

    $startMenus = @(
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft SQL Server*",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Microsoft SQL Server*"
    )
    foreach ($sm in $startMenus) {
        Get-Item -Path $sm -ErrorAction SilentlyContinue | ForEach-Object {
            if ($DryRun) { Emit 'INFO' "(simulado) Eliminaria accesos directos: $($_.FullName)"; return }
            try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                  Emit 'OK' "Accesos directos eliminados: $($_.FullName)"; $removed++ }
            catch { Emit 'WARN' "No se pudieron eliminar accesos: $($_.FullName)"; $failed++ }
        }
    }

    try {
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        if ($machinePath) {
            $parts = $machinePath -split ';' | Where-Object { $_ -and ($_ -notmatch 'Microsoft SQL Server') }
            $newPath = ($parts -join ';')
            if ($newPath -ne $machinePath) {
                if ($DryRun) {
                    Emit 'INFO' '(simulado) Limpiaria rutas de SQL Server del PATH del sistema.'
                } else {
                    [Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
                    Emit 'OK' 'PATH del sistema limpiado de rutas SQL Server.'
                }
            }
        }
    } catch { Emit 'WARN' "No se pudo limpiar el PATH: $($_.Exception.Message)" }

    # =============================================== 8. USUARIOS DE SERVICIO (opcional)
    SetStep 8 'Revisando cuentas de servicio...'
    Emit 'STEP' 'PASO 8/8 - Revisando cuentas de servicio locales de SQL...'
    $sqlLocalUsers = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like 'MSSQL*' -or $_.Name -like 'SQLServer*' -or $_.Name -like 'SQLAgent*'
    }
    foreach ($u in $sqlLocalUsers) {
        if ($DryRun) { Emit 'INFO' "(simulado) Eliminaria usuario local: $($u.Name)"; continue }
        if (-not ($PSCmdlet.ShouldProcess("Usuario local $($u.Name)", 'Eliminar'))) { continue }
        try { Remove-LocalUser -Name $u.Name -ErrorAction Stop
              Emit 'OK' "Usuario local eliminado: $($u.Name)"; $removed++ }
        catch { Emit 'WARN' "No se pudo eliminar usuario $($u.Name)"; $failed++ }
    }

    Emit 'STEP' 'Completado.'
    if ($SyncHash) {
        $SyncHash.Removed = $removed; $SyncHash.Skipped = $skipped; $SyncHash.Failed = $failed
        $SyncHash.Done = $true
    }
    [pscustomobject]@{ Removed = $removed; Skipped = $skipped; Failed = $failed; LogFile = $LogFile }
}

# ============================================================================
#  MODO -NoGui : flujo de consola clasico (para automatizacion / scripting)
# ============================================================================
function Start-CliFlow {
    Clear-Host
    $banner = @"
================================================================================

     SQL SERVER  ->  COMPLETE REMOVAL UTILITY
     Desinstalacion total: instancias, servicios, datos, registro

     Version 2.0    |    Desarrollado por Kisnner Obando

================================================================================
"@
    Write-Host $banner -ForegroundColor Cyan

    if (-not (Test-Admin)) {
        Write-Host "Este script DEBE ejecutarse como Administrador." -ForegroundColor Red
        Write-Host "Cierra esta ventana y abre PowerShell con 'Ejecutar como administrador'." -ForegroundColor Red
        exit 1
    }

    $logFile = New-DefaultLogPath
    $dryRun = [bool]$WhatIfPreference
    Write-Host " Registro de la operacion: $logFile" -ForegroundColor DarkGray
    Write-Host ""

    $mode = if ($dryRun) { 'SIMULACION (-WhatIf): no se borrara nada' } else { 'REAL: se eliminaran datos de forma permanente' }
    Write-Host "Modo: $mode" -ForegroundColor Cyan
    if ($KeepData) { Write-Host "Opcion -KeepData activa: los .mdf/.ndf/.ldf/.bak se copiaran a C:\SQLServer_DataBackup_<fecha> antes de borrar." -ForegroundColor Yellow }

    if (-not $dryRun -and -not $Force) {
        Write-Host ""
        Write-Host " ADVERTENCIA: se eliminara SQL Server y TODOS sus datos de este equipo." -ForegroundColor Yellow
        Write-Host " Esta accion NO se puede deshacer." -ForegroundColor Yellow
        $ans = Read-Host " Escribe SI (en mayusculas) para continuar"
        if ($ans -ne 'SI') { Write-Host "Operacion cancelada por el usuario." -ForegroundColor Yellow; exit 0 }
    }

    $result = Invoke-SqlRemoval -DryRun:$dryRun -KeepData:$KeepData -LogFile $logFile -Confirm:$false

    Write-Host ""
    Write-Host "================================================================================" -ForegroundColor Cyan
    Write-Host "  RESUMEN DE LA OPERACION" -ForegroundColor Cyan
    Write-Host "================================================================================" -ForegroundColor Cyan
    Write-Host "Elementos eliminados : $($result.Removed)" -ForegroundColor Green
    Write-Host "Elementos conservados: $($result.Skipped)" -ForegroundColor Gray
    Write-Host "Fallos / revision manual: $($result.Failed)" -ForegroundColor $(if ($result.Failed) { 'Yellow' } else { 'Green' })
    Write-Host ""
    if ($dryRun) {
        Write-Host "SIMULACION completada. No se elimino nada. Ejecuta sin -WhatIf para aplicar." -ForegroundColor Cyan
    } else {
        Write-Host "Limpieza completada. Se RECOMIENDA reiniciar el equipo antes de reinstalar." -ForegroundColor Cyan
        Write-Host " El sistema esta listo para una instalacion limpia de SQL Server." -ForegroundColor Green
    }
    Write-Host " Log completo: $logFile" -ForegroundColor DarkGray
    Write-Host ""
}

# ============================================================================
#  MODO GUI : asistente grafico (WPF) - modo por defecto
# ============================================================================
function Start-GuiWizard {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    if (-not (Test-Admin)) {
        $choice = [System.Windows.MessageBox]::Show(
            "Este asistente necesita privilegios de Administrador para poder eliminar SQL Server por completo." + "`n`n" + "¿Deseas reabrirlo como Administrador ahora?",
            'Se requieren privilegios de Administrador', 'YesNo', 'Warning')
        if ($choice -eq 'Yes') {
            try {
                $exe = (Get-Process -Id $PID).Path
                $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
                Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs | Out-Null
            } catch {
                [System.Windows.MessageBox]::Show("No se pudo reabrir como Administrador: $($_.Exception.Message)", 'Error', 'OK', 'Error') | Out-Null
            }
        }
        return
    }

    function ConvertTo-Brush([string]$Hex) { [System.Windows.Media.BrushConverter]::new().ConvertFromString($Hex) }

    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Desinstalador de SQL Server" Height="600" Width="820"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        FontFamily="Segoe UI" Background="#F3F3F3">
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="90"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="64"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="#1F2A38">
            <StackPanel VerticalAlignment="Center" Margin="28,0,28,0">
                <TextBlock Text="Desinstalador de SQL Server" FontSize="20" FontWeight="Bold" Foreground="White"/>
                <TextBlock Text="Eliminacion completa: instancias, servicios, datos y registro" FontSize="12" Foreground="#B7C4D6" Margin="0,4,0,0"/>
            </StackPanel>
        </Border>

        <Grid Grid.Row="1" Margin="28,20,28,10">

            <StackPanel x:Name="PageWelcome" Visibility="Visible">
                <TextBlock Text="Bienvenido al asistente de desinstalacion" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,12"/>
                <TextBlock TextWrapping="Wrap" FontSize="13" Foreground="#333" Margin="0,0,0,10" Text="Este asistente eliminara de forma completa SQL Server (todas las versiones), SQL Server Management Studio y todos sus componentes de este equipo:"/>
                <StackPanel Margin="8,0,0,0">
                    <TextBlock Text="•  Servicios e instancias de SQL Server" Margin="0,3,0,0"/>
                    <TextBlock Text="•  Programas instalados (SSMS, herramientas, ODBC, PolyBase...)" Margin="0,3,0,0"/>
                    <TextBlock Text="•  Carpetas, binarios y bases de datos" Margin="0,3,0,0"/>
                    <TextBlock Text="•  Claves del registro de Windows" Margin="0,3,0,0"/>
                    <TextBlock Text="•  Archivos temporales y accesos directos" Margin="0,3,0,0"/>
                </StackPanel>
                <TextBlock TextWrapping="Wrap" FontSize="13" Foreground="#333" Margin="0,16,0,0" Text="El equipo quedara listo para una instalacion limpia desde cero."/>
                <TextBlock Text="Desarrollado por Kisnner Obando" FontSize="11" Foreground="#888" Margin="0,24,0,0"/>
            </StackPanel>

            <DockPanel x:Name="PageTerms" Visibility="Collapsed">
                <TextBlock DockPanel.Dock="Top" Text="Terminos y condiciones" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,10"/>
                <CheckBox x:Name="ChkAccept" DockPanel.Dock="Bottom" Content="He leido y acepto los terminos y condiciones" Margin="0,10,0,0" FontSize="13"/>
                <Border BorderBrush="#CCCCCC" BorderThickness="1">
                    <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="10">
                        <TextBlock x:Name="TxtEula" TextWrapping="Wrap" FontSize="12" FontFamily="Consolas"/>
                    </ScrollViewer>
                </Border>
            </DockPanel>

            <StackPanel x:Name="PageScan" Visibility="Collapsed">
                <TextBlock Text="Elementos detectados en este equipo" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,14"/>
                <TextBlock x:Name="TxtScanResults" FontSize="13" TextWrapping="Wrap" Margin="0,0,0,24"/>
                <CheckBox x:Name="ChkDryRun" Content="Modo simulacion (no elimina nada, solo muestra que haria)" FontSize="13" Margin="0,0,0,12"/>
                <CheckBox x:Name="ChkKeepData" Content="Conservar archivos de datos (.mdf/.ndf/.ldf/.bak) antes de borrar" FontSize="13"/>
            </StackPanel>

            <StackPanel x:Name="PageConfirm" Visibility="Collapsed">
                <TextBlock Text="Listo para desinstalar" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,14"/>
                <TextBlock x:Name="TxtConfirmSummary" FontSize="13" TextWrapping="Wrap" Margin="0,0,0,16"/>
                <Border x:Name="BorderWarning" BorderThickness="1" Padding="14">
                    <TextBlock x:Name="TxtWarning" TextWrapping="Wrap" FontSize="13" FontWeight="SemiBold"/>
                </Border>
            </StackPanel>

            <StackPanel x:Name="PageProgress" Visibility="Collapsed">
                <TextBlock Text="Desinstalando..." FontSize="16" FontWeight="SemiBold" Margin="0,0,0,10"/>
                <TextBlock x:Name="TxtStepLabel" FontSize="13" Foreground="#555555" Margin="0,0,0,10"/>
                <ProgressBar x:Name="ProgBar" Height="18" Minimum="0" Maximum="100" Margin="0,0,0,14"/>
                <Border BorderBrush="#CCCCCC" BorderThickness="1" Height="260">
                    <ScrollViewer x:Name="LogScroll" VerticalScrollBarVisibility="Auto">
                        <TextBox x:Name="TxtLog" IsReadOnly="True" BorderThickness="0" FontFamily="Consolas" FontSize="11" TextWrapping="Wrap" Background="#111111" Foreground="#DDDDDD" Padding="8"/>
                    </ScrollViewer>
                </Border>
            </StackPanel>

            <StackPanel x:Name="PageSummary" Visibility="Collapsed">
                <TextBlock x:Name="TxtSummaryTitle" Text="Desinstalacion completada" FontSize="18" FontWeight="Bold" Margin="0,0,0,16"/>
                <TextBlock x:Name="TxtSummaryBody" FontSize="13" TextWrapping="Wrap" Margin="0,0,0,16"/>
                <TextBlock x:Name="TxtLogPath" FontSize="11" Foreground="#888888" TextWrapping="Wrap"/>
            </StackPanel>

        </Grid>

        <Border Grid.Row="2" Background="#EAEAEA" BorderBrush="#D0D0D0" BorderThickness="0,1,0,0">
            <Grid Margin="28,0,28,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Button x:Name="BtnRestart" Grid.Column="0" HorizontalAlignment="Left" Content="Reiniciar ahora" Width="140" Height="32" Visibility="Collapsed"/>
                <Button x:Name="BtnCancel" Grid.Column="1" Content="Cancelar" Width="100" Height="32" Margin="0,0,10,0"/>
                <Button x:Name="BtnBack" Grid.Column="2" Content="&lt; Atras" Width="100" Height="32" Margin="0,0,10,0"/>
                <Button x:Name="BtnNext" Grid.Column="3" Content="Siguiente &gt;" Width="150" Height="32"/>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $pageNames = @('Welcome', 'Terms', 'Scan', 'Confirm', 'Progress', 'Summary')
    $pages = @{}
    foreach ($p in $pageNames) { $pages[$p] = $window.FindName("Page$p") }

    $chkAccept   = $window.FindName('ChkAccept')
    $txtEula     = $window.FindName('TxtEula')
    $txtScan     = $window.FindName('TxtScanResults')
    $chkDryRun   = $window.FindName('ChkDryRun')
    $chkKeepData = $window.FindName('ChkKeepData')
    $txtConfirm  = $window.FindName('TxtConfirmSummary')
    $borderWarn  = $window.FindName('BorderWarning')
    $txtWarning  = $window.FindName('TxtWarning')
    $txtStepLbl  = $window.FindName('TxtStepLabel')
    $progBar     = $window.FindName('ProgBar')
    $txtLog      = $window.FindName('TxtLog')
    $txtSumTitle = $window.FindName('TxtSummaryTitle')
    $txtSumBody  = $window.FindName('TxtSummaryBody')
    $txtLogPath  = $window.FindName('TxtLogPath')
    $btnBack     = $window.FindName('BtnBack')
    $btnNext     = $window.FindName('BtnNext')
    $btnCancel   = $window.FindName('BtnCancel')
    $btnRestart  = $window.FindName('BtnRestart')

    $txtEula.Text = Get-EulaText

    $script:currentPage = 'Welcome'
    $script:removalRunning = $false
    $script:logFile = New-DefaultLogPath
    $script:scanSummary = $null
    $script:lastLogIndex = 0
    $script:syncHash = $null
    $script:ps = $null
    $script:rs = $null
    $script:handle = $null

    function Show-Page {
        param([string]$Name)
        foreach ($p in $pageNames) { $pages[$p].Visibility = if ($p -eq $Name) { 'Visible' } else { 'Collapsed' } }
        $script:currentPage = $Name
        $btnCancel.Visibility = 'Visible'
        $btnRestart.Visibility = 'Collapsed'
        switch ($Name) {
            'Welcome'  { $btnBack.IsEnabled = $false; $btnNext.IsEnabled = $true;  $btnNext.Content = 'Siguiente >' }
            'Terms'    { $btnBack.IsEnabled = $true;  $btnNext.IsEnabled = ($chkAccept.IsChecked -eq $true); $btnNext.Content = 'Siguiente >' }
            'Scan'     { $btnBack.IsEnabled = $true;  $btnNext.IsEnabled = $true;  $btnNext.Content = 'Siguiente >' }
            'Confirm'  { $btnBack.IsEnabled = $true;  $btnNext.IsEnabled = $true }
            'Progress' { $btnBack.IsEnabled = $false; $btnNext.IsEnabled = $false; $btnCancel.Visibility = 'Collapsed' }
            'Summary'  { $btnBack.IsEnabled = $false; $btnNext.IsEnabled = $true;  $btnNext.Content = 'Finalizar'; $btnCancel.Visibility = 'Collapsed' }
        }
    }

    function Update-ScanResults {
        $summary = Get-ScanSummary
        $script:scanSummary = $summary
        $total = $summary.Services + $summary.Products + $summary.Folders
        $txtScan.Text = "Servicios detectados: $($summary.Services)`nProgramas registrados: $($summary.Products)`nCarpetas encontradas: $($summary.Folders)"
        if ($total -eq 0) {
            $txtScan.Text += "`n`nNo se detecto una instalacion de SQL Server en este equipo. Aun puedes continuar para limpiar posibles restos (registro, temporales, etc.)."
        }
    }

    function Update-ConfirmSummary {
        $dry = ($chkDryRun.IsChecked -eq $true)
        $keep = ($chkKeepData.IsChecked -eq $true)
        $s = $script:scanSummary
        $extra = if ($keep) { "`nSe conservaran los archivos de datos (.mdf/.ndf/.ldf/.bak) en una carpeta de rescate antes de borrar." } else { '' }
        $txtConfirm.Text = "Se procesaran: $($s.Services) servicio(s), $($s.Products) programa(s), $($s.Folders) carpeta(s)." + $extra

        if ($dry) {
            $txtWarning.Text = 'MODO SIMULACION: no se eliminara nada realmente. Solo se generara un registro de lo que se haria.'
            $borderWarn.Background = ConvertTo-Brush '#EAF3FB'
            $borderWarn.BorderBrush = ConvertTo-Brush '#3D7EBF'
            $txtWarning.Foreground = ConvertTo-Brush '#1B4F72'
            $btnNext.Content = 'Simular'
        } else {
            $txtWarning.Text = 'ADVERTENCIA: esta accion eliminara SQL Server y TODOS sus datos de este equipo de forma PERMANENTE. No se puede deshacer.'
            $borderWarn.Background = ConvertTo-Brush '#FDECEA'
            $borderWarn.BorderBrush = ConvertTo-Brush '#C0392B'
            $txtWarning.Foreground = ConvertTo-Brush '#7A1E14'
            $btnNext.Content = 'Desinstalar ahora'
        }
    }

    function Start-Removal {
        $script:removalRunning = $true
        $script:lastLogIndex = 0
        $dryRunFlag = ($chkDryRun.IsChecked -eq $true)
        $keepDataFlag = ($chkKeepData.IsChecked -eq $true)

        $script:syncHash = [hashtable]::Synchronized(@{
            Log      = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
            Step     = 0
            Total    = 8
            StepLabel = ''
            Removed  = 0
            Skipped  = 0
            Failed   = 0
            Done     = $false
        })

        Show-Page 'Progress'
        $txtLog.Text = ''
        $progBar.Value = 0

        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('syncHash', $script:syncHash)
        $rs.SessionStateProxy.SetVariable('dryRunFlag', $dryRunFlag)
        $rs.SessionStateProxy.SetVariable('keepDataFlag', $keepDataFlag)
        $rs.SessionStateProxy.SetVariable('logFilePath', $script:logFile)

        $engineSrc = 'function Invoke-SqlRemoval { ' + ${function:Invoke-SqlRemoval}.ToString() + ' }'
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($engineSrc)
        [void]$ps.AddScript('Invoke-SqlRemoval -DryRun $dryRunFlag -KeepData $keepDataFlag -LogFile $logFilePath -SyncHash $syncHash -Confirm:$false')

        $script:ps = $ps
        $script:rs = $rs
        $script:handle = $ps.BeginInvoke()

        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $script:removalTimer = $timer
        $timer.Interval = [TimeSpan]::FromMilliseconds(200)
        $timer.Add_Tick({
            $sh = $script:syncHash
            if (-not $sh) { return }
            while ($script:lastLogIndex -lt $sh.Log.Count) {
                $entry = $sh.Log[$script:lastLogIndex]
                $txtLog.AppendText("[$($entry.Level)] $($entry.Message)`r`n")
                $script:lastLogIndex++
            }
            $txtLog.ScrollToEnd()
            $progBar.Value = if ($sh.Total -gt 0) { [double]$sh.Step / [double]$sh.Total * 100 } else { 0 }
            $txtStepLbl.Text = $sh.StepLabel

            if ($sh.Done) {
                $script:removalTimer.Stop()
                try { [void]$script:ps.EndInvoke($script:handle) } catch {}
                try { $script:ps.Dispose() } catch {}
                try { $script:rs.Close(); $script:rs.Dispose() } catch {}
                $script:removalRunning = $false

                $wasDry = ($chkDryRun.IsChecked -eq $true)
                $txtSumTitle.Text = if ($sh.Failed -gt 0) { 'Completado con avisos' } elseif ($wasDry) { 'Simulacion completada' } else { 'Desinstalacion completada' }
                $body = "Elementos eliminados: $($sh.Removed)`nElementos conservados: $($sh.Skipped)`nFallos (revision manual, ver log): $($sh.Failed)"
                if ($wasDry) { $body += "`n`nNo se elimino nada realmente (modo simulacion)." }
                elseif ($sh.Failed -eq 0) { $body += "`n`nEl sistema esta listo para una instalacion limpia. Se recomienda reiniciar el equipo." }
                $txtSumBody.Text = $body
                $txtLogPath.Text = "Log completo: $($script:logFile)"

                if (-not $wasDry) { $btnRestart.Visibility = 'Visible' }
                Show-Page 'Summary'
            }
        })
        $timer.Start()
    }

    $btnNext.Add_Click({
        switch ($script:currentPage) {
            'Welcome'  { Show-Page 'Terms' }
            'Terms'    { Show-Page 'Scan'; Update-ScanResults }
            'Scan'     { Show-Page 'Confirm'; Update-ConfirmSummary }
            'Confirm'  { Start-Removal }
            'Summary'  { $window.Close() }
        }
    })
    $btnBack.Add_Click({
        switch ($script:currentPage) {
            'Terms'   { Show-Page 'Welcome' }
            'Scan'    { Show-Page 'Terms' }
            'Confirm' { Show-Page 'Scan' }
        }
    })
    $btnCancel.Add_Click({ $window.Close() })
    $btnRestart.Add_Click({
        $confirm = [System.Windows.MessageBox]::Show('¿Deseas reiniciar el equipo ahora?', 'Reiniciar equipo', 'YesNo', 'Question')
        if ($confirm -eq 'Yes') { Restart-Computer -Force }
    })
    $chkAccept.Add_Checked({ if ($script:currentPage -eq 'Terms') { $btnNext.IsEnabled = $true } })
    $chkAccept.Add_Unchecked({ if ($script:currentPage -eq 'Terms') { $btnNext.IsEnabled = $false } })

    $window.Add_Closing({
        # Nota: en un handler agregado via Add_Closing, los argumentos del evento
        # (CancelEventArgs) llegan en $EventArgs, NO en $_ (esa es la variable de
        # pipeline y aqui estaria vacia).
        if ($script:removalRunning) {
            $r = [System.Windows.MessageBox]::Show('La desinstalacion sigue en curso. Si cierras ahora, el proceso en segundo plano puede quedar incompleto. ¿Cerrar de todas formas?', 'Operacion en curso', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { $EventArgs.Cancel = $true }
        }
    })

    Show-Page 'Welcome'
    [void]$window.ShowDialog()
}

# ============================================================================
#  DESPACHO PRINCIPAL
# ============================================================================
try {
    if ($NoGui) {
        Start-CliFlow
    } else {
        Start-GuiWizard
    }
} catch {
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
        [System.Windows.MessageBox]::Show("Error inesperado: $($_.Exception.Message)", 'Error', 'OK', 'Error') | Out-Null
    } catch {}
    Write-Host "Error inesperado: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
