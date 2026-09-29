; RKAVIC Team Manager Windows installer. Compile after flutter build windows --release.
#ifndef AppVersion
  #define AppVersion "0.5.0"
#endif

[Setup]
AppId=nl.rkavic.manager.windows
AppName=RKAVIC Team Manager
AppVersion={#AppVersion}
AppPublisher=RKAVIC
DefaultDirName={localappdata}\Programs\RKAVIC Team Manager
DefaultGroupName=RKAVIC Team Manager
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\flutter_app\build\installer
OutputBaseFilename=RKAVIC-Team-Manager-Windows-v{#AppVersion}-Setup
SetupIconFile=..\flutter_app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\rkavic_manager.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "..\flutter_app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\RKAVIC Team Manager"; Filename: "{app}\rkavic_manager.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\RKAVIC Team Manager"; Filename: "{app}\rkavic_manager.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\rkavic_manager.exe"; Description: "Launch RKAVIC Team Manager"; Flags: nowait postinstall skipifsilent
