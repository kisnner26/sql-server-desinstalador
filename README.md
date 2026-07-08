<div align="center">

# 🗑️ SQL Server Complete Removal Utility

**Desinstalador completo de SQL Server (todas las versiones) y SSMS, con asistente gráfico previo — para Windows y Linux.**

[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux-blue)](#)
[![PowerShell](https://img.shields.io/badge/Windows-PowerShell%205.1%2B-5391FE?logo=powershell&logoColor=white)](#-windows)
[![Bash](https://img.shields.io/badge/Linux-bash-4EAA25?logo=gnubash&logoColor=white)](#-linux)
[![Maintainer](https://img.shields.io/badge/desarrollado%20por-Kisnner%20Obando-black)](#autor)

</div>

---

> ⚠️ **Aviso de autoría:** esta herramienta tiene un aspecto profesional pero **no es software oficial de Microsoft** ni está firmada por Microsoft. Es una utilidad independiente desarrollada por **Kisnner Obando**. "SQL Server" y "SQL Server Management Studio" son marcas registradas de Microsoft Corporation, mencionadas aquí solo con fines descriptivos. Esta misma aclaración aparece en la pantalla de términos y condiciones del asistente. Úsala solo en equipos de tu propiedad o que administras.

## Índice

- [¿Qué es esto?](#qué-es-esto)
- [Antes de empezar](#️-antes-de-empezar)
- [Capturas de pantalla](#-capturas-de-pantalla)
- [Windows](#-windows)
- [Linux](#-linux)
- [Registro (log)](#-registro-log)
- [Después de desinstalar](#-después-de-desinstalar)
- [Solución de problemas](#-solución-de-problemas)
- [Autor](#autor)

---

## ¿Qué es esto?

Un desinstalador **agresivo y minucioso** de SQL Server (todas las versiones) y SQL Server Management Studio, pensado para dejar el equipo **100% limpio y listo para una instalación desde cero** — sin residuos de instancias, servicios, binarios, datos, temporales ni claves de registro.

A diferencia de un `.ps1`/`.sh` de línea de comandos a secas, incluye un **asistente previo a la acción** (bienvenida → términos y condiciones → detección → confirmación → progreso en vivo → resumen), con el mismo formato de pantallas que un instalador convencional:

- 🪟 **Windows:** asistente gráfico nativo (WPF vía PowerShell, sin dependencias externas que instalar).
- 🐧 **Linux:** asistente en ventanas (`zenity`) si hay escritorio, o en modo texto (`whiptail`/`dialog`) si es un servidor por SSH — se detecta automáticamente.
- Ambos también ofrecen un **modo automatización sin interfaz**, para scripting o CI.

---

## ⚠️ Antes de empezar

- La operación es **destructiva e irreversible**. Elimina las bases de datos y todos los datos de SQL Server.
- **Haz una copia de seguridad** de tus bases (`.bak`, `.mdf`, `.ldf`) si contienen algo que necesites.
- El propio asistente incluye un modo **simulación** en la pantalla de detección — recomendado la primera vez.
- Reinicia el equipo al terminar, antes de reinstalar (el asistente lo ofrece directamente).

---

## 📸 Capturas de pantalla

*Pendientes.* Este repositorio se publicó sin capturas reales porque se desarrolló sin acceso a un entorno Windows ni a un escritorio Linux para ejecutarlo. Si lo pruebas, ¡son bienvenidas las capturas por PR o issue! Mientras tanto, el flujo completo de pantallas está descrito paso a paso en las secciones [Windows](#-windows) y [Linux](#-linux) de abajo.

---

## 🪟 Windows

### Opción recomendada: asistente gráfico (doble clic)

Haz doble clic en **[`Ejecutar-Desinstalador.cmd`](Ejecutar-Desinstalador.cmd)**. Se abrirá una ventana de Windows pidiendo permiso de Administrador (UAC) y a continuación el asistente:

1. **Bienvenida** — resumen de qué hace.
2. **Términos y condiciones** — debes marcar la casilla de aceptación para continuar.
3. **Detectado** — cuenta servicios, programas y carpetas encontrados; aquí eliges **"Modo simulación"** y/o **"Conservar archivos de datos"**.
4. **Confirmación** — resumen final antes de actuar.
5. **Progreso** — barra de progreso y registro en vivo de cada paso.
6. **Resumen** — elementos eliminados/conservados/con fallos, ruta del log, y botón para reiniciar el equipo.

Si prefieres no usar el `.cmd`, también puedes ejecutar directamente:
```powershell
.\Uninstall-SqlServer.ps1
```
No hace falta abrir PowerShell como Administrador a mano — si detecta que no tiene privilegios elevados, el propio asistente pregunta si quiere reabrirse como Administrador.

### Modo automatización (sin interfaz gráfica)

Para scripting, tareas programadas o CI, usa `-NoGui` (requiere PowerShell ya elevado como Administrador):

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass   # si hace falta

.\Uninstall-SqlServer.ps1 -NoGui -WhatIf         # SIMULACIÓN — no borra nada (recomendado primero)
.\Uninstall-SqlServer.ps1 -NoGui                 # ejecución real, pide confirmación escribiendo "SI"
.\Uninstall-SqlServer.ps1 -NoGui -Force          # sin preguntar (peligroso)
.\Uninstall-SqlServer.ps1 -NoGui -KeepData       # rescata .mdf/.ndf/.ldf/.bak a C:\SQLServer_DataBackup_<fecha> antes de borrar
```

### Qué elimina en Windows
1. Procesos: `sqlservr`, `sqlwriter`, `sqlbrowser`, `SQLAGENT`, `msmdsrv`, `Ssms`, etc.
2. Servicios: `MSSQL*`, `SQLAgent*`, `SQLBrowser`, `SQLWriter`, `MSSQLServerOLAPService`, `ReportServer*`, telemetría, etc. (detiene, deshabilita y borra).
3. Desinstalación oficial vía MSI / `setup.exe /Action=Uninstall` de cada producto SQL y SSMS registrado.
4. Carpetas: `Microsoft SQL Server`, `SQL Server Management Studio`, `ProgramData\Microsoft\SQL Server`, herramientas, etc. (con `takeown`/`icacls` si hay permisos bloqueados).
5. Restos por-usuario de SSMS: claves `HKCU` y carpetas de AppData (config, caché, historial de conexiones). **Se conserva** `Documentos\SQL Server Management Studio` porque contiene scripts `.sql` del usuario.
6. Registro: `HKLM\SOFTWARE\Microsoft\Microsoft SQL Server`, `Wow6432Node`, `SYSTEM\...\Services\MSSQL*`, SSMS, Native Client, etc.
7. Temporales de instaladores, accesos directos del menú inicio y rutas de SQL en el `PATH` del sistema.
8. Cuentas de servicio locales `MSSQL*` / `SQLAgent*`.

---

## 🐧 Linux

Requiere ejecutarse como **root** (`sudo`). Compatible con `apt`, `dnf`, `yum` y `zypper`.

```bash
chmod +x uninstall-sqlserver.sh
sudo ./uninstall-sqlserver.sh
```

El script **detecta automáticamente** qué interfaz usar:

| Entorno detectado | Interfaz que se usa |
|---|---|
| Escritorio gráfico (GNOME/KDE/X11/Wayland) + `zenity` instalado | **Asistente en ventanas** (bienvenida, términos con casilla de aceptación, detección + opciones, confirmación, barra de progreso, resumen) |
| Servidor por SSH sin escritorio, con `whiptail` o `dialog` | **Asistente en modo texto** (mismas pantallas, con menús de teclado) — el caso más común en servidores Linux con SQL Server |
| Ninguno de los anteriores | Flujo de texto plano clásico (confirmación escribiendo `SI`) |

### Modo automatización (sin interfaz)

Para scripting o CI, fuerza el flujo de texto plano con `--cli`:

```bash
sudo ./uninstall-sqlserver.sh --cli --dry-run      # SIMULACIÓN — no borra nada (recomendado primero)
sudo ./uninstall-sqlserver.sh --cli                # ejecución real, pide confirmación escribiendo "SI"
sudo ./uninstall-sqlserver.sh --cli --force        # sin preguntar (automatización)
sudo ./uninstall-sqlserver.sh --cli --keep-data    # rescata .mdf/.ndf/.ldf/.bak antes de borrar
```

### Qué elimina en Linux
1. Servicio `mssql-server` (y agente/launchpad): detiene, deshabilita y mata procesos residuales.
2. Paquetes: `mssql-server`, `mssql-tools`, `mssql-tools18`, `msodbcsql17/18`, `mssql-server-fts`, `polybase`, `mssql-cli`, etc. (purga + `autoremove`).
3. Repositorios de Microsoft (`sources.list.d`, `yum.repos.d`, `zypp/repos.d`) y llaves GPG. Protecciones para no romper nada más: la llave GPG y `msprod.list` **se conservan** si detecta otros productos de Microsoft instalados (VS Code, Edge, .NET, PowerShell), y `unixodbc` no se toca por ser una librería compartida con otros programas.
4. Directorios: `/var/opt/mssql`, `/opt/mssql`, `/opt/mssql-tools*`, `/opt/microsoft/*`, `/var/log/mssql`, `/etc/mssql-conf`.
5. Temporales en `/tmp` y `/var/tmp`.
6. Usuario y grupo del sistema `mssql`.
7. Referencias a `mssql-tools` en el `PATH` (`/etc/profile.d`, `.bashrc`, `.profile`) — deja respaldo `.sqlbak`.

---

## 📄 Registro (log)

Cada ejecución guarda un log detallado, tanto en modo asistente como en modo automatización:
- **Windows:** `%TEMP%\SQLServer_Removal_<fecha>.log`
- **Linux:** `/tmp/sqlserver_removal_<fecha>.log`

En modo asistente (gráfico o texto), la ruta del log se muestra en la pantalla de resumen final.

---

## ✅ Después de desinstalar

1. **Reinicia** el equipo (el asistente lo ofrece directamente en la pantalla final).
2. (Windows) Verifica en *Programas y características* que no quede ninguna entrada de SQL Server / SSMS.
3. (Linux) Verifica con `systemctl status mssql-server` (debe decir "not found") y `ls /var/opt/mssql` (no debe existir).
4. Ya puedes instalar SQL Server de nuevo desde cero.

---

## ❓ Solución de problemas

| Problema | Solución |
|---|---|
| "No se puede cargar el script" (Windows) | Ejecuta `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`, o usa `Ejecutar-Desinstalador.cmd` |
| El `.ps1` se abre en el Bloc de notas al hacer doble clic | Windows no asocia `.ps1` a PowerShell por seguridad — usa `Ejecutar-Desinstalador.cmd` en su lugar, o clic derecho > "Ejecutar con PowerShell" |
| En Linux no aparece ninguna ventana gráfica | Es normal en un servidor por SSH sin escritorio — se usará automáticamente el asistente en modo texto (`whiptail`/`dialog`), o instala `zenity` si tienes escritorio y quieres ventanas reales |
| Una carpeta no se elimina | Reinicia y vuelve a ejecutar; algún proceso la tenía bloqueada |
| Un paquete falla al purgar (Linux) | Revisa el log; ejecuta de nuevo tras `apt-get -f install` |
| Quiero conservar mis bases de datos | Marca "Conservar archivos de datos" en el asistente, o usa `-KeepData` / `--keep-data`: copia los archivos a una carpeta de rescate (`C:\SQLServer_DataBackup_<fecha>` / `/var/backups/sqlserver_data_<fecha>`) antes de borrar |

---

## Autor

Desarrollado por **Kisnner Obando**.

Esta herramienta es un proyecto independiente, sin afiliación ni respaldo de Microsoft Corporation. Se distribuye "tal cual", sin garantía de ningún tipo — revisa el modo simulación antes de usarla sobre un sistema con datos importantes.
