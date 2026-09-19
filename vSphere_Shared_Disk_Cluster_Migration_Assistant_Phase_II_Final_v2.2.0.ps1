<#
.SYNOPSIS
  vSphere Shared-Disk Cluster Migration Assistant - Phase II
.DESCRIPTION
  Destination Reconstruction and Validation utility. Imports and verifies the Phase I
  manifest, connects independently to the destination vCenter, maps migrated shared
  VMDKs from the destination Primary VM, reattaches those existing VMDKs to the
  destination Secondary VM at the original SCSI nodes, explicitly restores Multi-writer
  and independent-persistent settings, and validates the final powered-off topology.

  This utility never powers on or migrates a VM and never deletes or creates a VMDK.
.NOTES
  Version: 2.2.0-PhaseII-Final
  Requires: Windows, PowerShell 7+, STA, VCF.PowerCLI
#>
[CmdletBinding()]
param([switch]$NoRelaunch)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

if ($PSVersionTable.PSVersion.Major -lt 7 -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    if (-not $NoRelaunch) {
        $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
        if (-not $pwsh) { $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source }
        if (-not $pwsh) { throw 'PowerShell 7 or later is required.' }
        & $pwsh -NoProfile -ExecutionPolicy Bypass -STA -File $PSCommandPath -NoRelaunch
        exit $LASTEXITCODE
    }
}
if (-not $IsWindows) { throw 'This WPF application requires Windows.' }
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml,System.Windows.Forms
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:AppName = 'vSphere Shared-Disk Cluster Migration Assistant'
$script:Version = '2.2.0-PhaseII-Final'
$script:VIServer = $null
$script:VCenterIdentity = $null
$script:Manifest = $null
$script:ManifestPath = $null
$script:ManifestHash = $null
$script:Destination = $null
$script:Mappings = @()
$script:Validation = $null
$script:ReconstructionCompleted = $false
$script:PrimaryPreparationCompleted = $false
$script:OutputBase = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$script:RunDir = $null
$script:DebugDir = $null
$script:LogFile = $null
$script:TranscriptFile = $null
$script:TranscriptStarted = $false
$script:DebugSequence = 0

function DoEvents { try { [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background) } catch {} }
function Test-HasModule { param([string]$Name) [bool](Get-Module -ListAvailable -Name $Name) }
function Protect-DiagnosticText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $safe = $Text -replace '(?i)(password|passwd|pwd|token|authorization)\s*[:=]\s*[^;\r\n]+','$1=********'
    if ($script:txtPassword) {
        $secret = $script:txtPassword.Password
        if (-not [string]::IsNullOrWhiteSpace($secret)) { $safe = $safe -replace [regex]::Escape($secret),'********' }
    }
    $safe
}
function Initialize-RunFolder {
    param([string]$BasePath)
    $candidate=[Environment]::ExpandEnvironmentVariables($BasePath.Trim())
    if(-not$candidate){throw 'Select an output folder.'}
    if(-not(Test-Path -LiteralPath $candidate)){New-Item -ItemType Directory -Path $candidate -Force|Out-Null}
    $candidate=(Resolve-Path -LiteralPath $candidate).Path
    $test=Join-Path $candidate ('.write-test-'+[guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($test,'test');Remove-Item -LiteralPath $test -Force
    $script:OutputBase=$candidate
    $script:RunDir=Join-Path $candidate ('vSphere-SharedDisk-PhaseII-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $script:RunDir -Force|Out-Null
    $script:DebugDir=Join-Path $script:RunDir 'Debug-Artifacts';New-Item -ItemType Directory -Path $script:DebugDir -Force|Out-Null
    $script:LogFile=Join-Path $script:RunDir ('PhaseII-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log')
    $script:TranscriptFile=Join-Path $script:RunDir ('PhaseII-Transcript-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log')
    if($script:txtOutput){$script:txtOutput.Text=$script:OutputBase}
}
function Write-Log {
    param([string]$Message,[ValidateSet('INFO','PASS','WARN','ERROR')][string]$Level='INFO')
    $line="$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') [$Level] $(Protect-DiagnosticText $Message)"
    if($script:LogFile){Add-Content -LiteralPath $script:LogFile -Value $line -Encoding utf8}
    if($script:txtLog){$script:txtLog.AppendText($line+[Environment]::NewLine);$script:txtLog.ScrollToEnd();DoEvents}
}
function Start-AppTranscript { if(-not$script:TranscriptStarted){try{Start-Transcript -LiteralPath $script:TranscriptFile -IncludeInvocationHeader -Force|Out-Null;$script:TranscriptStarted=$true}catch{Write-Log "Transcript could not start: $($_.Exception.Message)" WARN}} }
function Stop-AppTranscript { if($script:TranscriptStarted){try{Stop-Transcript|Out-Null}catch{};$script:TranscriptStarted=$false} }
function Save-DebugArtifact {
    param([string]$Category,[string]$Operation,$Data)
    $script:DebugSequence++
    $name='{0:d4}-{1}-{2}-{3}.json' -f $script:DebugSequence,(Get-Date -Format 'yyyyMMdd-HHmmss-fff'),($Category-replace'[^A-Za-z0-9_-]','_'),($Operation-replace'[^A-Za-z0-9_-]','_')
    $path=Join-Path $script:DebugDir $name;$Data|ConvertTo-Json -Depth 60|Set-Content -LiteralPath $path -Encoding utf8BOM;$path
}
function Write-ExceptionDiagnostic {
    param($ErrorRecord,[string]$Context)
    $d=[ordered]@{CapturedAt=(Get-Date).ToString('o');Context=$Context;Message=$ErrorRecord.Exception.Message;Type=$ErrorRecord.Exception.GetType().FullName;Line=$ErrorRecord.InvocationInfo.ScriptLineNumber;Position=$ErrorRecord.InvocationInfo.PositionMessage;Stack=$ErrorRecord.ScriptStackTrace}
    $path=Save-DebugArtifact 'EXCEPTION' $Context $d;Write-Log "${Context}: $($ErrorRecord.Exception.Message); Diagnostic=$path" ERROR
}
function Show-Notice { param([string]$Heading,[string]$Message,[ValidateSet('Information','Warning','Error')][string]$Kind='Information') [Windows.MessageBox]::Show($Message,$Heading,'OK',$Kind)|Out-Null }
function Wait-Tcp {
    param([string]$HostName,[int]$Port=443,[int]$Seconds=10)
    $end=(Get-Date).AddSeconds($Seconds)
    while((Get-Date)-lt$end){try{$c=[Net.Sockets.TcpClient]::new();$a=$c.BeginConnect($HostName,$Port,$null,$null);if($a.AsyncWaitHandle.WaitOne(1000)){$c.EndConnect($a);$c.Close();return $true};$c.Close()}catch{}}
    $false
}
function Ensure-PowerCLI {
    if(Test-HasModule 'VCF.PowerCLI'){Import-Module VCF.PowerCLI -ErrorAction Stop|Out-Null;return}
    throw 'VCF.PowerCLI is required. Install the module before running Phase II.'
}
function Get-VCenterIdentity {
    $si=Get-View -Server $script:VIServer -Id 'ServiceInstance-ServiceInstance' -ErrorAction Stop
    $user='';try{$sm=Get-View -Server $script:VIServer -Id $si.Content.SessionManager -Property CurrentSession -ErrorAction Stop;if($sm.CurrentSession){$user=[string]$sm.CurrentSession.UserName}}catch{try{$user=[string]$script:VIServer.User}catch{}}
    [pscustomobject][ordered]@{Name=[string]$script:VIServer.Name;InstanceUuid=[string]$si.Content.About.InstanceUuid;FullName=[string]$si.Content.About.FullName;Version=[string]$si.Content.About.Version;Build=[string]$si.Content.About.Build;ConnectedUser=$user;ConnectedAt=(Get-Date).ToString('o')}
}
function Connect-DestinationVCenter {
    Ensure-PowerCLI
    try{Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false|Out-Null}catch{}
    $server=$script:txtVCenter.Text.Trim();$user=$script:txtUsername.Text.Trim();$password=$script:txtPassword.Password
    if(-not$server -or -not$user -or -not$password){throw 'Destination vCenter, username, and password are required.'}
    if(-not(Wait-Tcp $server 443 10)){throw "TCP 443 is not reachable on $server."}
    if($script:VIServer){Disconnect-VIServer -Server $script:VIServer -Force -Confirm:$false -ErrorAction SilentlyContinue|Out-Null}
    $cred=[pscredential]::new($user,(ConvertTo-SecureString $password -AsPlainText -Force))
    $new=$null
    try{$new=Connect-VIServer -Server $server -Credential $cred -Force -ErrorAction Stop;$script:VIServer=$new;$script:VCenterIdentity=Get-VCenterIdentity}
    catch{if($new){Disconnect-VIServer -Server $new -Force -Confirm:$false -ErrorAction SilentlyContinue|Out-Null};$script:VIServer=$null;$script:VCenterIdentity=$null;throw}
    $script:lblConnection.Text="Connected: $($script:VCenterIdentity.Name)";$script:lblConnection.Foreground='LightGreen'
    Write-Log "Connected to destination vCenter '$($script:VCenterIdentity.Name)' version $($script:VCenterIdentity.Version) build $($script:VCenterIdentity.Build)." PASS
    Update-UiState
}
function Disconnect-DestinationVCenter {if($script:VIServer){Disconnect-VIServer -Server $script:VIServer -Force -Confirm:$false -ErrorAction SilentlyContinue|Out-Null};$script:VIServer=$null;$script:VCenterIdentity=$null;$script:Destination=$null;$script:Mappings=@();$script:Validation=$null;$script:lblConnection.Text='Not connected';$script:lblConnection.Foreground='#76C7D8';Update-UiState}
function Resolve-ExactVm {
    param([string]$Name,[string]$Role)
    $m=@(Get-VM -Server $script:VIServer -Name $Name -ErrorAction SilentlyContinue)
    if($m.Count-ne1){throw "$Role VM '$Name' resolved to $($m.Count) destination objects; exactly one is required."};$m[0]
}
function ConvertTo-CanonicalVmdkPath {param([string]$Path)if([string]::IsNullOrWhiteSpace($Path)){return ''};(($Path.Trim()-replace'\\','/')-replace'/+','/').ToLowerInvariant()}
function Get-NormalizedSharing {param($Value)if(([string]$Value)-match'sharingMultiWriter'){'Multi-writer'}else{'No sharing'}}
function Get-DestinationVmInventory {
    param($VM,[string]$Role)
    $view=Get-View -Server $script:VIServer -Id $VM.Id -Property Name,Config,Runtime -ErrorAction Stop
    $devices=@($view.Config.Hardware.Device);$controllers=@($devices|Where-Object{$_ -is [VMware.Vim.VirtualSCSIController]});$controllerMap=@{};foreach($c in $controllers){$controllerMap[[int]$c.Key]=$c}
    $disks=[Collections.Generic.List[object]]::new()
    foreach($d in @($devices|Where-Object{$_ -is [VMware.Vim.VirtualDisk]})){$c=$controllerMap[[int]$d.ControllerKey];$b=$d.Backing;$disks.Add([pscustomobject][ordered]@{Role=$Role;VMName=$VM.Name;DeviceLabel=[string]$d.DeviceInfo.Label;DeviceKey=[int]$d.Key;ControllerKey=[int]$d.ControllerKey;ControllerBus=if($c){[int]$c.BusNumber}else{-1};UnitNumber=[int]$d.UnitNumber;ScsiNode=if($c){('SCSI {0}:{1}' -f $c.BusNumber, $d.UnitNumber)}else{'Unresolved'};CapacityBytes=[int64]$d.CapacityInBytes;CapacityGB=[math]::Round($d.CapacityInBytes/1GB,2);Path=[string]$b.FileName;CanonicalPath=(ConvertTo-CanonicalVmdkPath ([string]$b.FileName));BaseName=[IO.Path]::GetFileName([string]$b.FileName);Uuid=try{[string]$b.Uuid}catch{''};ContentId=try{[string]$b.ContentId}catch{''};DiskMode=try{[string]$b.DiskMode}catch{''};Sharing=(Get-NormalizedSharing $b.Sharing);SharingRaw=[string]$b.Sharing;BackingType=$b.GetType().Name;ThinProvisioned=try{[bool]$b.ThinProvisioned}catch{$null};EagerlyScrubbed=try{[bool]$b.EagerlyScrub}catch{$null}})}
    $controllerRows=@($controllers|ForEach-Object{[pscustomobject][ordered]@{Role=$Role;VMName=$VM.Name;Label=[string]$_.DeviceInfo.Label;Key=[int]$_.Key;BusNumber=[int]$_.BusNumber;Type=$_.GetType().Name;BusSharing=[string]$_.SharedBus}})
    [pscustomobject]@{VM=[pscustomobject][ordered]@{Role=$Role;VMName=$VM.Name;VMId=$VM.Id;MoRef=$view.MoRef.Value;InstanceUuid=[string]$view.Config.InstanceUuid;ConfigUuid=[string]$view.Config.Uuid;PowerState=[string]$view.Runtime.PowerState;ConnectionState=[string]$view.Runtime.ConnectionState;ChangeVersion=[string]$view.Config.ChangeVersion;DiskCount=$disks.Count;ControllerCount=$controllerRows.Count};View=$view;Controllers=$controllerRows;Disks=@($disks)}
}
function Find-ChecksumFile {
    param([string]$ManifestPath)
    $dir=Split-Path -Parent $ManifestPath;$candidates=@((Join-Path $dir 'SharedDiskMigrationManifest.sha256'),(Join-Path $dir 'SharedDiskMigrationManifest.sha256.txt'))
    $found=@($candidates|Where-Object{Test-Path -LiteralPath $_})
    if($found.Count-ne1){throw "Exactly one companion checksum file is required. Found $($found.Count)."};$found[0]
}
function Import-PhaseIManifest {
    $d=[Microsoft.Win32.OpenFileDialog]::new();$d.Filter='Phase I manifest (SharedDiskMigrationManifest.json)|SharedDiskMigrationManifest.json|JSON files (*.json)|*.json';if(-not$d.ShowDialog()){return}
    $path=$d.FileName;$checksum=Find-ChecksumFile $path;$expected=((Get-Content -LiteralPath $checksum -Raw).Trim()-split'\s+')[0].ToLowerInvariant();$actual=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if($expected-ne$actual){throw "Manifest checksum mismatch. Expected='$expected'; Actual='$actual'."}
    $m=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -Depth 70 -DateKind String
    if([string]$m.SchemaVersion-ne'1.0'){throw "Unsupported manifest schema '$($m.SchemaVersion)'."}
    if([string]$m.Validation.Status-ne'Pass'){throw "Phase I source validation status is '$($m.Validation.Status)', not Pass."}
    $phase1Dir=Split-Path -Parent $path;$post=Join-Path $phase1Dir 'PostChange-Validation.json';$applied=Join-Path $phase1Dir 'AppliedChanges.json'
    if(Test-Path -LiteralPath $post){$p=Get-Content -LiteralPath $post -Raw|ConvertFrom-Json -Depth 20 -DateKind String;if([string]$p.Status-ne'Pass'){throw "Phase I post-change status is '$($p.Status)', not Pass."}}
    if(-not(Test-Path -LiteralPath $applied)){throw 'AppliedChanges.json is missing from the Phase I evidence folder.'}
    $script:Manifest=$m;$script:ManifestPath=$path;$script:ManifestHash=$actual
    $script:txtPrimary.Text=[string]$m.ClusterPair.PrimaryVM.VMName;$script:txtSecondary.Text=[string]$m.ClusterPair.SecondaryVM.VMName
    $script:lblManifest.Text="Verified: $actual";$script:lblManifest.Foreground='LightGreen'
    Write-Log "Phase I manifest imported and verified. ManifestId=$($m.ManifestId); SHA256=$actual" PASS;Update-UiState
}
function Get-OriginalSharedRecords {
    @($script:Manifest.Disks|Where-Object{[string]$_.Role-eq'Primary'-and[bool]$_.OriginallyMultiWriter})
}
function Discover-DestinationPair {
    if(-not$script:VIServer){throw 'Connect to the destination vCenter first.'};if(-not$script:Manifest){throw 'Import the Phase I manifest first.'}
    $pvm=Resolve-ExactVm $script:txtPrimary.Text.Trim() 'Primary';$svm=Resolve-ExactVm $script:txtSecondary.Text.Trim() 'Secondary'
    if($pvm.Id-eq$svm.Id){throw 'Primary and Secondary resolve to the same destination VM.'}
    $p=Get-DestinationVmInventory $pvm Primary;$s=Get-DestinationVmInventory $svm Secondary
    $script:Destination=[pscustomobject]@{Primary=$p;Secondary=$s;VMs=@($p.VM,$s.VM);Disks=@($p.Disks)+@($s.Disks);Controllers=@($p.Controllers)+@($s.Controllers)}
    $script:gridVMs.ItemsSource=@($script:Destination.VMs);$script:gridDisks.ItemsSource=@($script:Destination.Disks)
    New-DestinationMappings
    Write-Log "Destination discovery completed. Primary disks=$($p.Disks.Count); Secondary disks=$($s.Disks.Count); mappings=$($script:Mappings.Count)." PASS;Update-UiState
}
function New-DestinationMappings {
    $list=[Collections.Generic.List[object]]::new();$originals=Get-OriginalSharedRecords
    foreach($o in $originals){
        $base=[IO.Path]::GetFileName([string]$o.BackingFileName)
        $uuid=@($script:Destination.Primary.Disks|Where-Object{$_.Uuid-and[string]$_.Uuid-eq[string]$o.Uuid-and$_.CapacityBytes-eq[int64]$o.CapacityBytes})
        $name=@($script:Destination.Primary.Disks|Where-Object{$_.BaseName-eq$base-and$_.CapacityBytes-eq[int64]$o.CapacityBytes})
        $match=$null;$status='Unmatched';$method='None'
        if($uuid.Count-eq1){$match=$uuid[0];$status='Mapped';$method='UUID+Capacity'}elseif($uuid.Count-gt1){$status='Ambiguous UUID'}elseif($name.Count-eq1){$match=$name[0];$status='Mapped';$method='BaseName+Capacity'}elseif($name.Count-gt1){$status='Ambiguous Name'}
        $targetBus = [int]$o.ControllerBusNumber
        $targetUnit = [int]$o.UnitNumber
        $controller = @(
            $script:Destination.Secondary.Controllers | Where-Object {
                [int]$_.BusNumber -eq [int]$targetBus
            }
        )
        $occupied = @(
            $script:Destination.Secondary.Disks | Where-Object {
                [int]$_.ControllerBus -eq [int]$targetBus -and
                [int]$_.UnitNumber -eq [int]$targetUnit
            }
        )
        $list.Add([pscustomobject][ordered]@{OriginalDevice=[string]$o.DeviceLabel;OriginalPath=[string]$o.BackingFileName;OriginalUuid=[string]$o.Uuid;CapacityGB=[double]$o.CapacityGB;TargetScsiNode=('SCSI {0}:{1}' -f $targetBus, $targetUnit);TargetBus=$targetBus;TargetUnit=$targetUnit;DestinationPrimaryDevice=if($match){$match.DeviceLabel}else{''};DestinationPath=if($match){$match.Path}else{''};DestinationUuid=if($match){$match.Uuid}else{''};CurrentSharing=if($match){$match.Sharing}else{''};CurrentDiskMode=if($match){$match.DiskMode}else{''};MappingMethod=$method;MappingStatus=$status;ControllerAvailable=($controller.Count-eq1);TargetNodeAvailable=($occupied.Count-eq0);PrimaryPreparationRequired=([bool]$match -and $match.Sharing -ne 'Multi-writer');Ready=([bool]$match -and $controller.Count -eq 1 -and $occupied.Count -eq 0);PrimaryDeviceKey=if($match){$match.DeviceKey}else{$null};SecondaryControllerKey=if($controller.Count-eq1){$controller[0].Key}else{$null}})
    }
    $script:Mappings=@($list);$script:gridMappings.ItemsSource=$script:Mappings
}
function Test-DestinationReadiness {
    if (-not $script:Destination) { throw 'Discover the destination VM pair first.' }

    $findings = [Collections.Generic.List[object]]::new()
    $primary = $script:Destination.Primary
    $secondary = $script:Destination.Secondary

    if ($primary.VM.PowerState -ne 'poweredOff') {
        $findings.Add([pscustomobject]@{ Severity='BLOCK'; Category='Power'; Object=$primary.VM.VMName; Message='Primary VM must be powered off.' })
    }
    if ($secondary.VM.PowerState -ne 'poweredOff') {
        $findings.Add([pscustomobject]@{ Severity='BLOCK'; Category='Power'; Object=$secondary.VM.VMName; Message='Secondary VM must be powered off.' })
    }

    foreach ($map in $script:Mappings) {
        if ($map.MappingStatus -ne 'Mapped') {
            $findings.Add([pscustomobject]@{ Severity='BLOCK'; Category='Mapping'; Object=$map.OriginalDevice; Message=$map.MappingStatus })
        }
        if (-not $map.ControllerAvailable) {
            $findings.Add([pscustomobject]@{ Severity='BLOCK'; Category='Controller'; Object=$map.TargetScsiNode; Message='Exactly one destination Secondary controller with the original bus number is required.' })
        }
        if (-not $map.TargetNodeAvailable) {
            $findings.Add([pscustomobject]@{ Severity='BLOCK'; Category='SCSI'; Object=$map.TargetScsiNode; Message='Target SCSI node is occupied.' })
        }
        if ($map.MappingStatus -eq 'Mapped' -and $map.CurrentSharing -ne 'Multi-writer') {
            $findings.Add([pscustomobject]@{
                Severity='PREP'
                Category='Sharing'
                Object=$map.OriginalDevice
                Message='Cross-vCenter migration did not preserve Multi-writer. Destination Primary preparation is required.'
            })
        }
    }

    $originalPrivate = @($script:Manifest.Disks | Where-Object {
        [string]$_.Role -eq 'Secondary' -and -not [bool]$_.OriginallyMultiWriter
    })
    foreach ($original in $originalPrivate) {
        $match = @($secondary.Disks | Where-Object {
            $_.ControllerBus -eq [int]$original.ControllerBusNumber -and
            $_.UnitNumber -eq [int]$original.UnitNumber -and
            $_.CapacityBytes -eq [int64]$original.CapacityBytes
        })
        if ($match.Count -ne 1) {
            $findings.Add([pscustomobject]@{ Severity='BLOCK'; Category='PrivateDisk'; Object=$original.DeviceLabel; Message='Destination Secondary private disk does not match the original SCSI node and capacity.' })
        }
    }

    $blockingCount = @($findings | Where-Object { $_.Severity -eq 'BLOCK' }).Count
    $preparationCount = @($findings | Where-Object { $_.Severity -eq 'PREP' }).Count
    $status = if ($blockingCount -gt 0) { 'Blocked' } elseif ($preparationCount -gt 0) { 'PreparationRequired' } else { 'Pass' }

    $script:Validation = [pscustomobject][ordered]@{
        ValidatedAt=(Get-Date).ToString('o')
        Status=$status
        BlockingCount=$blockingCount
        PreparationCount=$preparationCount
        Findings=@($findings)
    }
    $script:gridFindings.ItemsSource = @($findings)
    $script:lblValidation.Text = if ($status -eq 'Blocked') { "Blocked ($blockingCount)" } elseif ($status -eq 'PreparationRequired') { "Primary preparation required ($preparationCount)" } else { 'Pass' }
    $script:lblValidation.Foreground = if ($status -eq 'Blocked') { 'Tomato' } elseif ($status -eq 'PreparationRequired') { '#F2C94C' } else { 'LightGreen' }
    $script:Validation | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $script:RunDir 'Destination-PreReconstruction-Validation.json') -Encoding utf8BOM

    if ($status -eq 'Blocked') { Write-Log "Destination readiness blocked by $blockingCount finding(s)." ERROR }
    elseif ($status -eq 'PreparationRequired') { Write-Log "Destination Primary preparation required for $preparationCount manifest-identified shared disk(s)." WARN }
    else { Write-Log 'Destination readiness validation passed.' PASS }
    Update-UiState
    return ($blockingCount -eq 0)
}

function Get-PrimaryPreparationTargets {
    @($script:Mappings | Where-Object {
        $_.MappingStatus -eq 'Mapped' -and $_.CurrentSharing -ne 'Multi-writer'
    })
}

function Show-PrimaryPreparationConfirmation {
    param($Targets)
    $primaryName = $script:Destination.Primary.VM.VMName
    $required = "RESTORE MULTI-WRITER ON $primaryName"
    $details = @($Targets | ForEach-Object {
        "$($_.DestinationPrimaryDevice) | $($_.DestinationPath) | $($_.TargetScsiNode) | Set sharingMultiWriter"
    }) -join [Environment]::NewLine
    $message = "Cross-vCenter migration removed Multi-writer from $($Targets.Count) disk(s).`n`n$details`n`nType exactly:`n$required"
    $inputWindow = New-Object System.Windows.Window
    $inputWindow.Title = 'Confirm Destination Primary Preparation'
    $inputWindow.Width = 820
    $inputWindow.Height = 430
    $inputWindow.WindowStartupLocation = 'CenterOwner'
    $inputWindow.Owner = $script:Window
    $inputWindow.Background = '#071015'
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = 18
    $text = New-Object System.Windows.Controls.TextBlock
    $text.Text = $message
    $text.TextWrapping = 'Wrap'
    $text.Foreground = '#E6E6E6'
    $text.Margin = '0,0,0,12'
    $entry = New-Object System.Windows.Controls.TextBox
    $entry.Background = '#071015'; $entry.Foreground = '#FFFFFF'; $entry.BorderBrush = '#F2C94C'; $entry.Margin='0,0,0,12'
    $buttons = New-Object System.Windows.Controls.StackPanel
    $buttons.Orientation = 'Horizontal'; $buttons.HorizontalAlignment = 'Right'
    $cancel = New-Object System.Windows.Controls.Button; $cancel.Content='Cancel'; $cancel.Width=100; $cancel.Margin=4
    $execute = New-Object System.Windows.Controls.Button; $execute.Content='Prepare Primary'; $execute.Width=145; $execute.Margin=4; $execute.IsEnabled=$false
    $entry.Add_TextChanged({ $execute.IsEnabled = [string]::Equals($entry.Text.Trim(),$required,[StringComparison]::OrdinalIgnoreCase) })
    $cancel.Add_Click({ $inputWindow.DialogResult=$false; $inputWindow.Close() })
    $execute.Add_Click({ $inputWindow.DialogResult=$true; $inputWindow.Close() })
    $buttons.Children.Add($cancel) | Out-Null; $buttons.Children.Add($execute) | Out-Null
    $panel.Children.Add($text) | Out-Null; $panel.Children.Add($entry) | Out-Null; $panel.Children.Add($buttons) | Out-Null
    $inputWindow.Content = $panel
    [bool]$inputWindow.ShowDialog()
}

function Invoke-DestinationPrimaryPreparation {
    if (-not $script:Destination) { throw 'Discover the destination VM pair first.' }
    $null = Test-DestinationReadiness
    if ($script:Validation.Status -eq 'Blocked') { throw 'Destination readiness has blocking findings. Primary preparation cannot proceed.' }

    $targets = @(Get-PrimaryPreparationTargets)
    if ($targets.Count -eq 0) {
        Write-Log 'Destination Primary shared disks already report Multi-writer. No preparation change is required.' PASS
        $script:PrimaryPreparationCompleted = $true
        Update-UiState
        return
    }
    if (-not (Show-PrimaryPreparationConfirmation -Targets $targets)) { Write-Log 'Destination Primary preparation canceled by the operator.' WARN; return }

    Discover-DestinationPair
    $null = Test-DestinationReadiness
    if ($script:Validation.Status -eq 'Blocked') { throw 'Destination readiness changed before Primary preparation.' }
    $targets = @(Get-PrimaryPreparationTargets)

    $primaryVm = Resolve-ExactVm $script:Destination.Primary.VM.VMName 'Primary'
    $primaryView = Get-View -Server $script:VIServer -Id $primaryVm.Id -Property Config.Hardware.Device,Config.ChangeVersion,Runtime.PowerState -ErrorAction Stop
    if ([string]$primaryView.Runtime.PowerState -ne 'poweredOff') { throw 'Destination Primary VM is not powered off.' }
    if ($script:Destination.Secondary.VM.PowerState -ne 'poweredOff') { throw 'Destination Secondary VM is not powered off.' }

    $spec = [VMware.Vim.VirtualMachineConfigSpec]::new()
    $spec.ChangeVersion = [string]$primaryView.Config.ChangeVersion
    $deviceChanges = [Collections.Generic.List[VMware.Vim.VirtualDeviceConfigSpec]]::new()
    $auditDisks = [Collections.Generic.List[object]]::new()

    foreach ($target in $targets) {
        $live = @($primaryView.Config.Hardware.Device | Where-Object {
            $_ -is [VMware.Vim.VirtualDisk] -and [int]$_.Key -eq [int]$target.PrimaryDeviceKey
        })
        if ($live.Count -ne 1) { throw "Primary device key '$($target.PrimaryDeviceKey)' resolved to $($live.Count) devices." }
        $disk = $live[0]
        if ((ConvertTo-CanonicalVmdkPath ([string]$disk.Backing.FileName)) -ne (ConvertTo-CanonicalVmdkPath ([string]$target.DestinationPath))) { throw "Primary backing changed for '$($target.OriginalDevice)'." }
        $disk.Backing.Sharing = 'sharingMultiWriter'
        $change = [VMware.Vim.VirtualDeviceConfigSpec]::new()
        $change.Operation = [VMware.Vim.VirtualDeviceConfigSpecOperation]::edit
        $change.Device = $disk
        if ($null -ne $change.FileOperation) { throw 'Safety violation: Primary preparation contains FileOperation.' }
        $deviceChanges.Add($change)
        $auditDisks.Add([pscustomobject][ordered]@{ DeviceKey=$disk.Key; DeviceLabel=$disk.DeviceInfo.Label; Path=$disk.Backing.FileName; ScsiNode=$target.TargetScsiNode; Operation='Set sharingMultiWriter'; FileOperation='None' })
    }
    $spec.DeviceChange = [VMware.Vim.VirtualDeviceConfigSpec[]]$deviceChanges.ToArray()
    $request = Save-DebugArtifact 'PRIMARY-PREPARATION' 'REQUEST' ([ordered]@{ CapturedAt=(Get-Date).ToString('o'); TargetVM=$primaryVm.Name; ChangeVersion=$spec.ChangeVersion; Disks=@($auditDisks) })
    Write-Log "Submitting destination Primary preparation for $($deviceChanges.Count) manifest-identified shared disk(s). Request=$request" WARN

    $taskRef = $primaryView.ReconfigVM_Task($spec)
    $task = Get-View -Server $script:VIServer -Id $taskRef -ErrorAction Stop
    while ($task.Info.State -in @('queued','running')) { Start-Sleep -Seconds 1; $task.UpdateViewData('Info.State','Info.Error') }
    if ($task.Info.State -ne 'success') { $message = if ($task.Info.Error) { $task.Info.Error.LocalizedMessage } else { "Task state $($task.Info.State)" }; throw "Destination Primary preparation failed: $message" }

    Discover-DestinationPair
    $remaining = @(Get-PrimaryPreparationTargets)
    if ($remaining.Count -gt 0) { throw "Primary preparation task completed, but $($remaining.Count) mapped disk(s) still do not report Multi-writer." }
    $script:PrimaryPreparationCompleted = $true
    [ordered]@{ AppliedAt=(Get-Date).ToString('o'); TaskId=[string]$taskRef.Value; TargetVM=$primaryVm.Name; FileOperation='None'; Disks=@($auditDisks) } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $script:RunDir 'Destination-Primary-Preparation-Applied.json') -Encoding utf8BOM
    $null = Test-DestinationReadiness
    Write-Log 'Destination Primary preparation passed. Multi-writer restored only to Phase I manifest-identified shared disks.' PASS
    Update-UiState
}

function Show-ReconstructionConfirmation {
    $secondary=$script:Destination.Secondary.VM.VMName;$required="ATTACH SHARED DISKS TO $secondary";$detail=@($script:Mappings|ForEach-Object{"$($_.DestinationPath) -> $secondary $($_.TargetScsiNode) | Multi-writer | independent_persistent"})-join[Environment]::NewLine
    $x=@"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Confirm Destination Reconstruction" Height="430" Width="800" WindowStartupLocation="CenterOwner" Background="#071015" Foreground="#E6E6E6" ShowInTaskbar="False"><Grid Margin="16"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><TextBlock Text="Attach existing destination shared VMDKs to the powered-off Secondary VM. No VMDK will be created or deleted." FontSize="16" Foreground="#F2C94C" TextWrapping="Wrap"/><TextBox x:Name="details" Grid.Row="1" TextWrapping="NoWrap" IsReadOnly="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Background="#0D1B22" Foreground="#FFFFFF" Margin="0,12"/><StackPanel Grid.Row="2"><TextBlock x:Name="instruction"/><TextBox x:Name="phrase" Background="#071015" Foreground="#FFFFFF" BorderBrush="#F2C94C" Margin="0,6"/></StackPanel><StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="cancel" Content="Cancel" Width="100" Margin="4"/><Button x:Name="execute" Content="Execute Reconstruction" Width="175" Margin="4" IsEnabled="False"/></StackPanel></Grid></Window>
"@
    $w=[Windows.Markup.XamlReader]::Parse($x);$w.Owner=$script:Window;$w.FindName('details').Text=$detail;$w.FindName('instruction').Text="Type exactly: $required";$p=$w.FindName('phrase');$e=$w.FindName('execute');$p.Add_TextChanged({$e.IsEnabled=[string]::Equals($p.Text.Trim(),$required,[StringComparison]::OrdinalIgnoreCase)});$e.Add_Click({$w.DialogResult=$true;$w.Close()});$w.FindName('cancel').Add_Click({$w.DialogResult=$false;$w.Close()});[bool]$w.ShowDialog()
}
function Invoke-DestinationReconstruction {
    if(-not$script:Validation-or$script:Validation.Status-ne'Pass'){throw 'Destination readiness validation must pass.'}
    Discover-DestinationPair;$null=Test-DestinationReadiness
    if($script:Validation.Status-ne'Pass'){throw 'Live destination readiness changed before execution.'}
    if(-not(Show-ReconstructionConfirmation)){Write-Log 'Destination reconstruction canceled by the operator.' WARN;return}
    Discover-DestinationPair;$null=Test-DestinationReadiness;if($script:Validation.Status-ne'Pass'){throw 'Live destination readiness changed after confirmation.'}
    $secondaryVm=Resolve-ExactVm $script:Destination.Secondary.VM.VMName 'Secondary';$view=Get-View -Server $script:VIServer -Id $secondaryVm.Id -Property Config.Hardware.Device,Config.ChangeVersion,Runtime.PowerState -ErrorAction Stop
    if([string]$view.Runtime.PowerState-ne'poweredOff'){throw 'Secondary VM is not powered off.'}
    $spec=[VMware.Vim.VirtualMachineConfigSpec]::new();$spec.ChangeVersion=[string]$view.Config.ChangeVersion;$changes=[Collections.Generic.List[VMware.Vim.VirtualDeviceConfigSpec]]::new()
    $temporaryDeviceKey = -100
    foreach ($map in $script:Mappings) {
        $primaryDisk = @($script:Destination.Primary.View.Config.Hardware.Device | Where-Object {
            $_ -is [VMware.Vim.VirtualDisk] -and
            [int]$_.Key -eq [int]$map.PrimaryDeviceKey
        })
        if ($primaryDisk.Count -ne 1) {
            throw "Primary mapping for '$($map.OriginalDevice)' changed."
        }

        $original = $primaryDisk[0]
        $disk = [VMware.Vim.VirtualDisk]::new()
        $disk.Key = $temporaryDeviceKey
        $temporaryDeviceKey--
        $disk.ControllerKey = [int]$map.SecondaryControllerKey
        $disk.UnitNumber = [int]$map.TargetUnit
        $disk.CapacityInKB = [long]$original.CapacityInKB
        try { $disk.CapacityInBytes = [long]$original.CapacityInBytes } catch {}

        $backing = [VMware.Vim.VirtualDiskFlatVer2BackingInfo]::new()
        $backing.FileName = [string]$map.DestinationPath
        $backing.DiskMode = 'independent_persistent'
        $backing.Sharing = 'sharingMultiWriter'
        $disk.Backing = $backing

        $deviceChange = [VMware.Vim.VirtualDeviceConfigSpec]::new()
        $deviceChange.Operation = [VMware.Vim.VirtualDeviceConfigSpecOperation]::add
        $deviceChange.Device = $disk
        if ($null -ne $deviceChange.FileOperation) {
            throw 'Safety violation: FileOperation is populated.'
        }
        $changes.Add($deviceChange)
    }
    $spec.DeviceChange=[VMware.Vim.VirtualDeviceConfigSpec[]]$changes.ToArray();$audit=[ordered]@{CapturedAt=(Get-Date).ToString('o');DestinationVCenter=$script:VCenterIdentity;TargetVM=$secondaryVm.Name;ChangeVersion=$spec.ChangeVersion;Operation='Add existing virtual disks';FileOperation='None';Mappings=$script:Mappings};$request=Save-DebugArtifact 'RECONSTRUCTION' 'REQUEST' $audit;Write-Log "Submitting destination reconstruction task for $($changes.Count) existing shared VMDK(s). Request=$request" WARN
    $taskRef=$view.ReconfigVM_Task($spec);$task=Get-View -Server $script:VIServer -Id $taskRef -ErrorAction Stop;while($task.Info.State-in@('queued','running')){Start-Sleep 1;$task.UpdateViewData('Info.State','Info.Error')};if($task.Info.State-ne'success'){$m=if($task.Info.Error){$task.Info.Error.LocalizedMessage}else{"Task state $($task.Info.State)"};throw "Destination reconstruction failed: $m"}
    $script:ReconstructionCompleted=$true;[ordered]@{AppliedAt=(Get-Date).ToString('o');TaskId=[string]$taskRef.Value;TargetVM=$secondaryVm.Name;FileOperation='None';Mappings=$script:Mappings}|ConvertTo-Json -Depth 30|Set-Content -LiteralPath (Join-Path $script:RunDir 'Destination-Reconstruction-Applied.json') -Encoding utf8BOM;Write-Log 'Destination reconstruction task completed. Existing VMDKs attached; VMDKs created=0; VMDKs deleted=0.' PASS;$null=Test-FinalDestinationConfiguration;Update-UiState
}
function Test-FinalDestinationConfiguration {
    Discover-DestinationPair
    $findings = [Collections.Generic.List[object]]::new()
    $finalMappings = [Collections.Generic.List[object]]::new()
    $primary = $script:Destination.Primary
    $secondary = $script:Destination.Secondary

    if ($primary.VM.PowerState -ne 'poweredOff' -or $secondary.VM.PowerState -ne 'poweredOff') {
        $findings.Add([pscustomobject]@{ Severity='BLOCK'; Category='Power'; Object='VM Pair'; Message='Both VMs must remain powered off.' })
    }

    foreach ($original in Get-OriginalSharedRecords) {
        $baseName = [IO.Path]::GetFileName([string]$original.BackingFileName)
        $expectedNode = 'SCSI {0}:{1}' -f ([int]$original.ControllerBusNumber), ([int]$original.UnitNumber)
        $primaryMatches = @($primary.Disks | Where-Object {
            $_.BaseName -eq $baseName -and $_.CapacityBytes -eq [int64]$original.CapacityBytes
        })
        $secondaryMatches = @($secondary.Disks | Where-Object {
            $_.BaseName -eq $baseName -and $_.CapacityBytes -eq [int64]$original.CapacityBytes
        })

        $backingMatch = $false
        $primarySharingCompliant = $false
        $secondarySharingCompliant = $false
        $secondaryDiskModeCompliant = $false
        $secondaryScsiNodeCompliant = $false
        $targetNodeOccupiedByExpectedDisk = $false
        $primaryPath = ''
        $secondaryPath = ''
        $primaryUuid = ''
        $secondaryUuid = ''

        if ($primaryMatches.Count -ne 1 -or $secondaryMatches.Count -ne 1) {
            $findings.Add([pscustomobject]@{
                Severity='BLOCK'; Category='Backing'; Object=$baseName
                Message="Expected exactly one Primary and one Secondary match. Primary=$($primaryMatches.Count); Secondary=$($secondaryMatches.Count)."
            })
        }
        else {
            $primaryDisk = $primaryMatches[0]
            $secondaryDisk = $secondaryMatches[0]
            $primaryPath = [string]$primaryDisk.Path
            $secondaryPath = [string]$secondaryDisk.Path
            $primaryUuid = [string]$primaryDisk.Uuid
            $secondaryUuid = [string]$secondaryDisk.Uuid
            $backingMatch = ($primaryDisk.CanonicalPath -eq $secondaryDisk.CanonicalPath)
            $primarySharingCompliant = ($primaryDisk.Sharing -eq 'Multi-writer')
            $secondarySharingCompliant = ($secondaryDisk.Sharing -eq 'Multi-writer')
            $secondaryDiskModeCompliant = ($secondaryDisk.DiskMode -eq 'independent_persistent')
            $secondaryScsiNodeCompliant = ($secondaryDisk.ScsiNode -eq $expectedNode)
            $targetNodeOccupiedByExpectedDisk = $secondaryScsiNodeCompliant

            if (-not $backingMatch) {
                $findings.Add([pscustomobject]@{ Severity='BLOCK'; Category='Backing'; Object=$baseName; Message='Primary and Secondary canonical destination paths differ.' })
            }
            if (-not $primarySharingCompliant -or -not $secondarySharingCompliant) {
                $findings.Add([pscustomobject]@{ Severity='BLOCK'; Category='Sharing'; Object=$baseName; Message='Both Primary and Secondary devices must report Multi-writer.' })
            }
            if (-not $secondaryDiskModeCompliant) {
                $findings.Add([pscustomobject]@{ Severity='BLOCK'; Category='DiskMode'; Object=$baseName; Message="Secondary disk mode is '$($secondaryDisk.DiskMode)', not independent_persistent." })
            }
            if (-not $secondaryScsiNodeCompliant) {
                $findings.Add([pscustomobject]@{ Severity='BLOCK'; Category='SCSI'; Object=$baseName; Message="Expected $expectedNode; found $($secondaryDisk.ScsiNode)." })
            }
        }

        $finalStateCompliant = (
            $primaryMatches.Count -eq 1 -and
            $secondaryMatches.Count -eq 1 -and
            $backingMatch -and
            $primarySharingCompliant -and
            $secondarySharingCompliant -and
            $secondaryDiskModeCompliant -and
            $secondaryScsiNodeCompliant
        )

        $finalMappings.Add([pscustomobject][ordered]@{
            OriginalDevice=[string]$original.DeviceLabel
            OriginalUuid=[string]$original.Uuid
            CapacityGB=[double]$original.CapacityGB
            ExpectedScsiNode=$expectedNode
            PrimaryDestinationPath=$primaryPath
            SecondaryDestinationPath=$secondaryPath
            PrimaryDestinationUuid=$primaryUuid
            SecondaryDestinationUuid=$secondaryUuid
            BackingMatch=if($backingMatch){'Exact'}else{'Mismatch'}
            PrimarySharing=if($primaryMatches.Count -eq 1){[string]$primaryMatches[0].Sharing}else{''}
            SecondarySharing=if($secondaryMatches.Count -eq 1){[string]$secondaryMatches[0].Sharing}else{''}
            SecondaryDiskMode=if($secondaryMatches.Count -eq 1){[string]$secondaryMatches[0].DiskMode}else{''}
            SecondaryScsiNode=if($secondaryMatches.Count -eq 1){[string]$secondaryMatches[0].ScsiNode}else{''}
            TargetNodeOccupiedByExpectedDisk=$targetNodeOccupiedByExpectedDisk
            FinalStateCompliant=$finalStateCompliant
            ReconstructionStatus=if($finalStateCompliant){'Compliant'}else{'Blocked'}
        })
    }

    $blockingCount = @($findings | Where-Object { $_.Severity -eq 'BLOCK' }).Count
    $result = [pscustomobject][ordered]@{
        ValidatedAt=(Get-Date).ToString('o')
        Status=if($blockingCount){'Blocked'}else{'Pass'}
        BlockingCount=$blockingCount
        FindingCount=$findings.Count
        DestinationVCenter=$script:VCenterIdentity
        PrimaryVM=$primary.VM
        SecondaryVM=$secondary.VM
        FinalMappings=@($finalMappings)
        Findings=@($findings)
    }
    $result | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath (Join-Path $script:RunDir 'Destination-Final-Validation.json') -Encoding utf8BOM
    @($finalMappings) | Export-Csv -LiteralPath (Join-Path $script:RunDir 'Destination-Final-Mappings.csv') -NoTypeInformation -Encoding utf8BOM
    $script:gridFinal.ItemsSource = @($findings)

    if ($blockingCount) {
        $script:lblFinal.Text = "BLOCKED ($blockingCount) - DO NOT POWER ON"
        $script:lblFinal.Foreground = 'Tomato'
        Write-Log "Final destination validation blocked by $blockingCount finding(s). DO NOT POWER ON." ERROR
    }
    else {
        $script:lblFinal.Text = 'PASS: READY FOR CONTROLLED PRIMARY POWER-ON'
        $script:lblFinal.Foreground = 'LightGreen'
        Write-Log 'Final destination validation passed. Both VMs remain powered off and shared-disk topology is reconstructed.' PASS
    }
    return ($blockingCount -eq 0)
}

function Save-ConnectionProfile {
    $dialog = [Microsoft.Win32.SaveFileDialog]::new()
    $dialog.Filter = 'JSON files (*.json)|*.json'
    $dialog.FileName = 'vSphere-SharedDisk-PhaseII-Connection-Profile.json'
    if (-not $dialog.ShowDialog()) { return }
    [ordered]@{
        SchemaVersion='2.0'
        ProfileType='Destination'
        DestinationVCenter=$script:txtVCenter.Text.Trim()
        DestinationUsername=$script:txtUsername.Text.Trim()
        OutputPath=$script:OutputBase
    } | ConvertTo-Json | Set-Content -LiteralPath $dialog.FileName -Encoding utf8BOM
    Write-Log "Password-free destination connection profile saved: $($dialog.FileName)" PASS
}

function Load-ConnectionProfile {
    $dialog = [Microsoft.Win32.OpenFileDialog]::new()
    $dialog.Filter = 'JSON files (*.json)|*.json'
    if (-not $dialog.ShowDialog()) { return }
    $profile = Get-Content -LiteralPath $dialog.FileName -Raw | ConvertFrom-Json -DateKind String

    $destinationVCenterProperty = $profile.PSObject.Properties['DestinationVCenter']
    $sourceVCenterProperty = $profile.PSObject.Properties['SourceVCenter']
    $destinationUsernameProperty = $profile.PSObject.Properties['DestinationUsername']
    $sourceUsernameProperty = $profile.PSObject.Properties['SourceUsername']
    $outputPathProperty = $profile.PSObject.Properties['OutputPath']

    $vCenter = if ($destinationVCenterProperty) { [string]$destinationVCenterProperty.Value } elseif ($sourceVCenterProperty) { [string]$sourceVCenterProperty.Value } else { '' }
    $username = if ($destinationUsernameProperty) { [string]$destinationUsernameProperty.Value } elseif ($sourceUsernameProperty) { [string]$sourceUsernameProperty.Value } else { '' }

    if ([string]::IsNullOrWhiteSpace($vCenter)) { throw 'The selected profile does not contain DestinationVCenter or SourceVCenter.' }
    if ([string]::IsNullOrWhiteSpace($username)) { throw 'The selected profile does not contain DestinationUsername or SourceUsername.' }

    $script:txtVCenter.Text = $vCenter
    $script:txtUsername.Text = $username
    if ($outputPathProperty -and -not [string]::IsNullOrWhiteSpace([string]$outputPathProperty.Value)) {
        Initialize-RunFolder ([string]$outputPathProperty.Value)
        Start-AppTranscript
    }
    $schema = if ($profile.PSObject.Properties['SchemaVersion']) { [string]$profile.SchemaVersion } else { 'Legacy' }
    Write-Log "Connection profile loaded: $($dialog.FileName). Schema=$schema; password was not loaded." PASS
}

function Update-UiState {
    $connected = [bool]$script:VIServer
    $manifest = [bool]$script:Manifest
    $discovered = [bool]$script:Destination
    $status = if ($script:Validation) { [string]$script:Validation.Status } else { '' }
    $needsPreparation = $discovered -and @(Get-PrimaryPreparationTargets).Count -gt 0
    $script:btnDiscover.IsEnabled = $connected -and $manifest
    $script:btnValidate.IsEnabled = $discovered
    $script:btnPrepare.IsEnabled = $discovered -and $status -ne 'Blocked' -and $needsPreparation -and -not $script:ReconstructionCompleted
    $script:btnExecute.IsEnabled = ($status -eq 'Pass' -and -not $needsPreparation -and -not $script:ReconstructionCompleted)
    $script:btnFinal.IsEnabled = $script:ReconstructionCompleted
    $script:btnOpen.IsEnabled = [bool]$script:RunDir
}
$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="vSphere Shared-Disk Cluster Migration Assistant - Phase II" Height="920" Width="1580" MinHeight="760" MinWidth="1200" WindowStartupLocation="CenterScreen" Background="#071015" Foreground="#E6E6E6" FontFamily="Segoe UI"><Window.Resources>
<Style TargetType="Button"><Setter Property="Background" Value="#2B3740"/><Setter Property="Foreground" Value="#F1F4F6"/><Setter Property="BorderBrush" Value="#5F7482"/><Setter Property="Padding" Value="9,4"/><Setter Property="Margin" Value="4"/><Setter Property="MinHeight" Value="29"/><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#3A4E59"/><Setter Property="Foreground" Value="#FFFFFF"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Background" Value="#182229"/><Setter Property="Foreground" Value="#81919A"/><Setter Property="Opacity" Value="1"/></Trigger></Style.Triggers></Style>
<Style TargetType="TextBlock"><Setter Property="Foreground" Value="#E6E6E6"/><Setter Property="Margin" Value="3"/></Style><Style TargetType="TextBox"><Setter Property="Background" Value="#071015"/><Setter Property="Foreground" Value="#E6E6E6"/><Setter Property="BorderBrush" Value="#607D8B"/><Setter Property="Padding" Value="4"/></Style><Style TargetType="PasswordBox"><Setter Property="Background" Value="#071015"/><Setter Property="Foreground" Value="#E6E6E6"/><Setter Property="BorderBrush" Value="#607D8B"/><Setter Property="Padding" Value="4"/></Style><Style TargetType="GroupBox"><Setter Property="Foreground" Value="#E6E6E6"/><Setter Property="Background" Value="#0D1B22"/><Setter Property="BorderBrush" Value="#2B3740"/><Setter Property="Margin" Value="5"/><Setter Property="Padding" Value="7"/></Style><Style TargetType="TabControl"><Setter Property="Background" Value="#071015"/></Style>
<Style TargetType="TabItem"><Setter Property="Background" Value="#25343D"/><Setter Property="Foreground" Value="#F1F4F6"/><Setter Property="Padding" Value="11,6"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TabItem"><Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="#5B7280" BorderThickness="1,1,1,0" Padding="{TemplateBinding Padding}"><ContentPresenter ContentSource="Header" TextElement.Foreground="{TemplateBinding Foreground}"/></Border><ControlTemplate.Triggers><Trigger Property="IsSelected" Value="True"><Setter TargetName="b" Property="Background" Value="#17313D"/><Setter TargetName="b" Property="BorderBrush" Value="#76C7D8"/><Setter Property="Foreground" Value="#FFFFFF"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
<Style TargetType="DataGrid"><Setter Property="Background" Value="#071015"/><Setter Property="Foreground" Value="#E6E6E6"/><Setter Property="RowBackground" Value="#071015"/><Setter Property="AlternatingRowBackground" Value="#0D1B22"/><Setter Property="GridLinesVisibility" Value="All"/><Setter Property="HorizontalGridLinesBrush" Value="#607D8B"/><Setter Property="VerticalGridLinesBrush" Value="#607D8B"/><Setter Property="IsReadOnly" Value="True"/><Setter Property="CanUserAddRows" Value="False"/><Setter Property="EnableRowVirtualization" Value="True"/><Setter Property="EnableColumnVirtualization" Value="True"/><Setter Property="HorizontalScrollBarVisibility" Value="Auto"/><Setter Property="VerticalScrollBarVisibility" Value="Auto"/></Style><Style TargetType="DataGridColumnHeader"><Setter Property="Background" Value="#2B3740"/><Setter Property="Foreground" Value="#FFFFFF"/></Style>
</Window.Resources><Grid Margin="10"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="160"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<GroupBox Header="Destination vCenter and Phase I Evidence"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="105"/><ColumnDefinition Width="240"/><ColumnDefinition Width="80"/><ColumnDefinition Width="240"/><ColumnDefinition Width="80"/><ColumnDefinition Width="180"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><Grid.RowDefinitions><RowDefinition Height="34"/><RowDefinition Height="34"/></Grid.RowDefinitions><TextBlock Text="Destination VC"/><TextBox x:Name="txtVCenter" Grid.Column="1"/><TextBlock Text="Username" Grid.Column="2"/><TextBox x:Name="txtUsername" Grid.Column="3"/><TextBlock Text="Password" Grid.Column="4"/><PasswordBox x:Name="txtPassword" Grid.Column="5"/><WrapPanel Grid.Column="6"><Button x:Name="btnConnect" Content="Connect"/><Button x:Name="btnDisconnect" Content="Disconnect"/><Button x:Name="btnSave" Content="Save Profile"/><Button x:Name="btnLoad" Content="Load Profile"/></WrapPanel><StackPanel Grid.Row="1" Grid.ColumnSpan="2" Orientation="Horizontal"><TextBlock Text="Status:"/><TextBlock x:Name="lblConnection" Text="Not connected" Foreground="#76C7D8"/></StackPanel><Button x:Name="btnManifest" Grid.Row="1" Grid.Column="2" Grid.ColumnSpan="2" Content="Import Phase I Manifest"/><StackPanel Grid.Row="1" Grid.Column="4" Grid.ColumnSpan="3" Orientation="Horizontal"><TextBlock Text="Manifest:"/><TextBlock x:Name="lblManifest" Text="Not imported" Foreground="#76C7D8" TextTrimming="CharacterEllipsis" Width="500"/></StackPanel></Grid></GroupBox>
<TabControl Grid.Row="1"><TabItem Header="1. Destination Discovery"><Grid Margin="8"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="*"/></Grid.RowDefinitions><GroupBox Header="Destination VM Pair"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="100"/><ColumnDefinition Width="260"/><ColumnDefinition Width="110"/><ColumnDefinition Width="260"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="Primary VM"/><TextBox x:Name="txtPrimary" Grid.Column="1"/><TextBlock Text="Secondary VM" Grid.Column="2"/><TextBox x:Name="txtSecondary" Grid.Column="3"/><Button x:Name="btnDiscover" Grid.Column="4" Content="Discover Destination Pair" IsEnabled="False"/></Grid></GroupBox><DataGrid x:Name="gridVMs" Grid.Row="1" AutoGenerateColumns="True"/><DataGrid x:Name="gridDisks" Grid.Row="2" AutoGenerateColumns="True"/></Grid></TabItem>
<TabItem Header="2. Shared-Disk Mapping"><Grid Margin="8"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><GroupBox Header="Mapping Validation"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="250"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><Button x:Name="btnValidate" Content="Validate Destination Readiness" IsEnabled="False"/><StackPanel Grid.Column="1" Orientation="Horizontal"><TextBlock Text="Status:"/><TextBlock x:Name="lblValidation" Text="Not validated" Foreground="#76C7D8"/></StackPanel><Button x:Name="btnPrepare" Grid.Column="2" Content="Prepare Destination Primary" IsEnabled="False" Background="#8A6500"/><Button x:Name="btnExecute" Grid.Column="3" HorizontalAlignment="Right" Content="Execute Destination Reconstruction" IsEnabled="False" Background="#6B2020"/></Grid></GroupBox><DataGrid x:Name="gridMappings" Grid.Row="1" AutoGenerateColumns="True"/></Grid></TabItem>
<TabItem Header="3. Findings"><DataGrid x:Name="gridFindings" Margin="8" AutoGenerateColumns="True"/></TabItem><TabItem Header="4. Final Validation"><Grid Margin="8"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><GroupBox Header="Final Powered-Off Topology"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><Button x:Name="btnFinal" Content="Run Final Validation" IsEnabled="False"/><TextBlock x:Name="lblFinal" Grid.Column="1" Text="Not completed" Foreground="#76C7D8" FontSize="15" FontWeight="SemiBold"/></Grid></GroupBox><DataGrid x:Name="gridFinal" Grid.Row="1" AutoGenerateColumns="True"/></Grid></TabItem></TabControl>
<GroupBox Grid.Row="2" Header="Operational Log"><TextBox x:Name="txtLog" IsReadOnly="True" TextWrapping="NoWrap" FontFamily="Consolas" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/></GroupBox><Grid Grid.Row="3"><Grid.ColumnDefinitions><ColumnDefinition Width="95"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="Output Base"/><TextBox x:Name="txtOutput" Grid.Column="1"/><WrapPanel Grid.Column="2"><Button x:Name="btnApplyOutput" Content="Apply Output"/><Button x:Name="btnOpen" Content="Open Run Folder" IsEnabled="False"/><Button x:Name="btnClose" Content="Close"/></WrapPanel></Grid></Grid></Window>
'@
$script:Window=[Windows.Markup.XamlReader]::Parse($xaml)
foreach($n in @('txtVCenter','txtUsername','txtPassword','btnConnect','btnDisconnect','btnSave','btnLoad','lblConnection','btnManifest','lblManifest','txtPrimary','txtSecondary','btnDiscover','gridVMs','gridDisks','btnValidate','lblValidation','btnPrepare','btnExecute','gridMappings','gridFindings','btnFinal','lblFinal','gridFinal','txtLog','txtOutput','btnApplyOutput','btnOpen','btnClose')){Set-Variable -Scope Script -Name $n -Value $script:Window.FindName($n)}

Initialize-RunFolder $script:OutputBase;Start-AppTranscript;$script:txtOutput.Text=$script:OutputBase
$script:btnConnect.Add_Click({try{Connect-DestinationVCenter}catch{Write-ExceptionDiagnostic $_ 'DESTINATION-CONNECT';Show-Notice 'Destination Connection Failed' $_.Exception.Message Error}})
$script:btnDisconnect.Add_Click({Disconnect-DestinationVCenter});$script:btnSave.Add_Click({try{Save-ConnectionProfile}catch{Show-Notice 'Save Profile' $_.Exception.Message Error}});$script:btnLoad.Add_Click({try{Load-ConnectionProfile}catch{Show-Notice 'Load Profile' $_.Exception.Message Error}})
$script:btnManifest.Add_Click({try{Import-PhaseIManifest}catch{Write-ExceptionDiagnostic $_ 'MANIFEST-IMPORT';Show-Notice 'Manifest Import Failed' $_.Exception.Message Error}})
$script:btnDiscover.Add_Click({try{$script:Window.Cursor='Wait';Discover-DestinationPair}catch{Write-ExceptionDiagnostic $_ 'DESTINATION-DISCOVERY';Show-Notice 'Destination Discovery Failed' $_.Exception.Message Error}finally{$script:Window.Cursor=$null}})
$script:btnValidate.Add_Click({try{$null=Test-DestinationReadiness}catch{Write-ExceptionDiagnostic $_ 'DESTINATION-VALIDATION';Show-Notice 'Destination Validation Failed' $_.Exception.Message Error}})
$script:btnPrepare.Add_Click({try{$script:Window.Cursor='Wait';Invoke-DestinationPrimaryPreparation}catch{Write-ExceptionDiagnostic $_ 'PRIMARY-PREPARATION';Show-Notice 'Destination Primary Preparation Failed' $_.Exception.Message Error}finally{$script:Window.Cursor=$null;Update-UiState}})
$script:btnExecute.Add_Click({try{$script:Window.Cursor='Wait';Invoke-DestinationReconstruction}catch{Write-ExceptionDiagnostic $_ 'DESTINATION-RECONSTRUCTION';Show-Notice 'Destination Reconstruction Failed' $_.Exception.Message Error}finally{$script:Window.Cursor=$null;Update-UiState}})
$script:btnFinal.Add_Click({try{$null=Test-FinalDestinationConfiguration}catch{Write-ExceptionDiagnostic $_ 'FINAL-VALIDATION';Show-Notice 'Final Validation Failed' $_.Exception.Message Error}})
$script:btnApplyOutput.Add_Click({try{Initialize-RunFolder $script:txtOutput.Text;Start-AppTranscript;Update-UiState}catch{Show-Notice 'Output Path' $_.Exception.Message Error}});$script:btnOpen.Add_Click({if(Test-Path -LiteralPath $script:RunDir){Invoke-Item $script:RunDir}});$script:btnClose.Add_Click({$script:Window.Close()})
$script:Window.Add_Closing({try{$script:txtPassword.Clear()}catch{};try{Disconnect-DestinationVCenter}catch{};Stop-AppTranscript})
Write-Log "$script:AppName $script:Version started. Phase II restores manifest-identified Multi-writer settings, reconstructs the powered-off Secondary, and does not power on, migrate, create, or delete VMDKs." PASS;Update-UiState;$null=$script:Window.ShowDialog();Stop-AppTranscript
