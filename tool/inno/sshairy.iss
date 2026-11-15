; Built by tool/package_windows.ps1. Values arrive through the environment so paths with
; spaces never pass through /D defines.
#define AppVersion GetEnv("SSHAIRY_VERSION")
#define PayloadDir GetEnv("SSHAIRY_PAYLOAD")
#define OutputDir GetEnv("SSHAIRY_OUTPUT")
#define OutputName GetEnv("SSHAIRY_OUTPUT_NAME")
#define TargetArch GetEnv("SSHAIRY_ARCH")

[Setup]
AppId={{8C0D5E2A-2F4B-4E77-9B5C-3A6D1F9E4B21}
AppName=sshairy
AppVersion={#AppVersion}
AppPublisher=sshairy
DefaultDirName={localappdata}\Programs\sshairy
DefaultGroupName=sshairy
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename={#OutputName}
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\sshairy.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
#if TargetArch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\sshairy"; Filename: "{app}\sshairy.exe"
Name: "{autodesktop}\sshairy"; Filename: "{app}\sshairy.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\sshairy.exe"; Description: "{cm:LaunchProgram,sshairy}"; Flags: nowait postinstall skipifsilent
