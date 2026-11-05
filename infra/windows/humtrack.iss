; Installer candidate only. Public distribution requires the release checklist.
#ifndef PayloadDir
  #error PayloadDir is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef AppBuild
  #error AppBuild is required
#endif
#ifndef AppIcon
  #error AppIcon is required
#endif
#ifndef ProtocolScheme
  #define ProtocolScheme "humtrack"
#endif
#ifndef InstallerId
  #define InstallerId "C753F77C-4225-47EB-93EE-A60843858DCF"
#endif

[Setup]
AppId={{{#InstallerId}}
AppName=HumTrack
AppVersion={#AppVersion}
AppPublisher=HumTrack
AppPublisherURL=https://hum-track.com
AppSupportURL=mailto:humtrack@gmail.com
VersionInfoVersion={#AppVersion}.{#AppBuild}
DefaultDirName={localappdata}\Programs\HumTrack
DefaultGroupName=HumTrack
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
OutputDir={#OutputDir}
OutputBaseFilename=HumTrack-{#AppVersion}-{#AppBuild}-windows-x64-setup
SetupIconFile={#AppIcon}
UninstallDisplayIcon={app}\HumTrack.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes
CloseApplications=no
RestartApplications=no
ChangesAssociations=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
#ifndef QAInstaller
Name: "{autoprograms}\HumTrack"; Filename: "{app}\HumTrack.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\HumTrack"; Filename: "{app}\HumTrack.exe"; WorkingDir: "{app}"; Tasks: desktopicon
#endif

[Registry]
Root: HKCU; Subkey: "Software\Classes\{#ProtocolScheme}"; ValueType: string; ValueName: ""; ValueData: "URL:HumTrack"
Root: HKCU; Subkey: "Software\Classes\{#ProtocolScheme}"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\{#ProtocolScheme}\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\HumTrack.exe,0"
Root: HKCU; Subkey: "Software\Classes\{#ProtocolScheme}\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\HumTrack.exe"" ""%1"""

[Code]
function InitializeSetup(): Boolean;
begin
  Result := FindWindowByWindowName('HumTrack') = 0;
  if not Result then
    SuppressibleMsgBox('Please save your work and close HumTrack before installing. / 작업을 저장하고 HumTrack을 종료한 뒤 설치해 주세요.', mbInformation, MB_OK, IDOK);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var Command: String;
begin
  if CurUninstallStep = usUninstall then
  begin
    { A newer or different application may have taken the scheme since install. }
    if RegQueryStringValue(HKCU, 'Software\Classes\{#ProtocolScheme}\shell\open\command', '', Command) then
      if CompareText(Command, ExpandConstant('"{app}\HumTrack.exe" "%1"')) = 0 then
        RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Classes\{#ProtocolScheme}');
  end;
  { No Documents, song library, recordings, or resource-cache deletion. }
end;
