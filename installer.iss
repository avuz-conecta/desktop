; Avuz Conecta Installer Script for Inno Setup
; Build with: "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer.iss

#define MyAppName "Avuz Conecta"
#define MyAppVersion "4.0.9"
#define MyAppPublisher "Avuz"
#define MyAppURL "https://avuz.app"
#define MyAppExeName "avuzconecta.exe"

[Setup]
AppId={{A7B8C9D0-E1F2-4A5B-4C5D-6E7F8091A2B3}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
OutputDir=.
OutputBaseFilename=AvuzConecta-{#MyAppVersion}-setup
SetupIconFile=admin\win\nsi\installer.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
CloseApplications=yes
CloseApplicationsFilter=*.exe

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"
Name: "portuguese"; MessagesFile: "compiler:Languages\Portuguese.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
; Portuguese (Brazil)
brazilianportuguese.CleanInstallGroup=Instalação Limpa
brazilianportuguese.CleanInstallDesc=Remover configurações antigas e dados em cache (começar do zero)
; Portuguese (Portugal)
portuguese.CleanInstallGroup=Instalação Limpa
portuguese.CleanInstallDesc=Remover configurações antigas e dados em cache (começar do zero)
; Spanish
spanish.CleanInstallGroup=Instalación Limpia
spanish.CleanInstallDesc=Eliminar configuraciones antiguas y datos en caché (comenzar de cero)
; English
english.CleanInstallGroup=Clean Installation
english.CleanInstallDesc=Remove old configuration and cached data (fresh start)

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "cleandata"; Description: "{cm:CleanInstallDesc}"; GroupDescription: "{cm:CleanInstallGroup}"; Flags: unchecked

[Files]
Source: "build-release\bin\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Registry]
Root: HKLM; Subkey: "Software\{#MyAppPublisher}\{#MyAppName}"; ValueType: string; ValueName: "InstallDir"; ValueData: "{app}"; Flags: uninsdeletekey

[InstallDelete]
; Clean old data if user selected the option
; Avuz folders
Type: filesandordirs; Name: "{userappdata}\Avuz"; Tasks: cleandata
Type: filesandordirs; Name: "{localappdata}\Avuz"; Tasks: cleandata
; Nextcloud legacy folders
Type: filesandordirs; Name: "{userappdata}\Nextcloud"; Tasks: cleandata
Type: filesandordirs; Name: "{localappdata}\Nextcloud"; Tasks: cleandata
; Alternative naming (no space)
Type: filesandordirs; Name: "{userappdata}\AvuzConecta"; Tasks: cleandata
Type: filesandordirs; Name: "{localappdata}\AvuzConecta"; Tasks: cleandata

[INI]
; QSettings with IniFormat writes to [General] section by default
Filename: "{userappdata}\Avuz\Avuz Conecta\avuzconecta.cfg"; Section: "General"; Key: "language"; String: "pt_BR"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
Type: filesandordirs; Name: "{userappdata}\Avuz\Avuz Conecta"

[Code]
// Kill running processes before cleanup
procedure KillRunningProcesses();
var
  ResultCode: Integer;
begin
  Exec('taskkill.exe', '/F /IM avuzconecta.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('taskkill.exe', '/F /IM AvuzConecta.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('taskkill.exe', '/F /IM nextcloud.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

function ProcessRunning(const ExeName: String): Boolean;
var
  ResultCode: Integer;
begin
  Result := Exec('cmd.exe',
    '/C tasklist /FI "IMAGENAME eq ' + ExeName + '" /NH | findstr /I "' + ExeName + '" >nul',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
end;

procedure CloseAvuzProcesses();
var
  ResultCode, Waited: Integer;
begin
  // Graceful WM_CLOSE (no /F). Tray app may ignore; force fallback below.
  Exec('taskkill.exe', '/IM avuzconecta.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('taskkill.exe', '/IM avuzconectadev.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  // Poll up to 10 s for graceful exit.
  Waited := 0;
  while (Waited < 10000) and (ProcessRunning('avuzconecta.exe') or ProcessRunning('avuzconectadev.exe')) do
  begin
    Sleep(500);
    Waited := Waited + 500;
  end;

  // Force fallback for whatever is still alive.
  if ProcessRunning('avuzconecta.exe') then
    Exec('taskkill.exe', '/F /IM avuzconecta.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if ProcessRunning('avuzconectadev.exe') then
    Exec('taskkill.exe', '/F /IM avuzconectadev.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  // Settle so the OS releases file handles before file removal.
  Sleep(1000);
end;

function InitializeUninstall(): Boolean;
begin
  CloseAvuzProcesses();
  Result := True;
end;

procedure RemoveNavigationPaneEntries();
const
  NavNameSpaceKey = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace';
  HideDesktopIconsKey = 'Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel';
var
  Clsids: TArrayOfString;
  I, ResultCode: Integer;
  AppName, Clsid: String;
begin
  if not RegGetSubkeyNames(HKEY_CURRENT_USER, NavNameSpaceKey, Clsids) then
    exit;
  for I := 0 to GetArrayLength(Clsids) - 1 do
  begin
    Clsid := Clsids[I];
    if RegQueryStringValue(HKEY_CURRENT_USER, NavNameSpaceKey + '\' + Clsid, 'ApplicationName', AppName) then
    begin
      if (AppName = 'Avuz Conecta') or (AppName = 'Avuz ConectaDev') then
      begin
        // Visible pin + desktop-hide flag (not WOW6432 redirected).
        RegDeleteKeyIncludingSubkeys(HKEY_CURRENT_USER, NavNameSpaceKey + '\' + Clsid);
        RegDeleteValue(HKEY_CURRENT_USER, HideDesktopIconsKey, Clsid);
        // Backing CLSID in both registry views (x64 client wrote native + Wow6432Node).
        Exec('reg.exe', 'delete "HKCU\Software\Classes\CLSID\' + Clsid + '" /reg:64 /f', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
        Exec('reg.exe', 'delete "HKCU\Software\Classes\CLSID\' + Clsid + '" /reg:32 /f', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      end;
    end;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RemoveNavigationPaneEntries();
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if IsTaskSelected('cleandata') then
  begin
    KillRunningProcesses();
    // Give processes time to terminate
    Sleep(1000);
  end;
end;
