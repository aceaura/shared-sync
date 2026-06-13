; installer.iss — Inno Setup 脚本,把 Flutter Windows 构建产物打包成安装器。
; 由 GitHub Actions(windows runner)编译:
;   ISCC /DMyAppVersion=1.0.0 installer\windows\installer.iss
; 输出:installer\windows\Output\shared-sync-windows-<版本>-setup.exe

#define MyAppName "Shared Sync"
#define MyAppExeName "shared_sync_app.exe"
#define MyAppPublisher "aceaura"
#define MyAppURL "https://github.com/aceaura/shared-sync"
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

[Setup]
; AppId 固定不变,保证升级覆盖安装识别为同一应用。
AppId={{8F2A6C14-3B7D-4E59-9A1C-6D5E2F0B7A33}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
DefaultDirName={autopf}\SharedSync
DefaultGroupName=Shared Sync
DisableProgramGroupPage=yes
OutputDir=Output
OutputBaseFilename=shared-sync-windows-{#MyAppVersion}-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; 打包整个 Release 目录(exe + DLL + data/)。路径相对本 .iss 文件。
Source: "..\..\client\app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
