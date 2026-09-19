<#
.SYNOPSIS
  vSphere Shared-Disk Cluster Migration Assistant - Phase I Final
.DESCRIPTION
  Read-only Phase I utility for discovering a two-node shared-disk cluster, collecting
  complete VM/SCSI/disk inventory, correlating multi-writer VMDKs, validating source
  readiness, and exporting a checksum-protected JSON manifest with supporting CSV files.

  Phase I includes controlled Secondary shared-disk detach and post-change validation. It does not power off, migrate,
  attach, delete backing files, or modify the Primary VM.
.NOTES
  Version: 1.2.0-PhaseI-Final
  Requires: Windows, PowerShell 7+, STA, VCF.PowerCLI
#>
[CmdletBinding()]
param([switch]$NoRelaunch)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# region Runtime
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
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7 or later is required.' }

Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml,System.Windows.Forms
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:AppName = 'vSphere Shared-Disk Cluster Migration Assistant'
$script:Version = '1.2.0-PhaseI-Final'
$script:VIServer = $null
$script:VCenterIdentity = $null
$script:Discovery = $null
$script:Validation = $null
$script:ManifestPath = $null
$script:ChecksumPath = $null
$script:TranscriptStarted = $false
$script:OutputBase = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$script:RunDir = $null
$script:LogFile = $null
$script:TranscriptFile = $null
$script:DebugDir = $null
$script:DebugSequence = 0
$script:DetachPreviewCurrent = $false
$script:DetachCompleted = $false
$script:PostChangeValidation = $null
$script:AppliedChanges = @()
# endregion

# region Diagnostics and common helpers
function Get-SafeCount { param($Value) return @($Value).Count }
function DoEvents { try { [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background) } catch {} }
function Test-HasModule { param([string]$Name) return [bool](Get-Module -ListAvailable -Name $Name) }

function Protect-DiagnosticText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $safe = $Text
    $safe = $safe -replace '(?i)(password|passwd|pwd|token|authorization)\s*[:=]\s*[^;\r\n]+','$1=********'
    foreach ($secret in @($script:txtPassword.Password)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$secret)) {
            $safe = $safe -replace [regex]::Escape([string]$secret),'********'
        }
    }
    return $safe
}
function Initialize-RunFolder {
    param([string]$BasePath)
    $candidate = [Environment]::ExpandEnvironmentVariables($BasePath.Trim())
    if (-not $candidate) { throw 'Select an output folder.' }
    if (-not (Test-Path -LiteralPath $candidate)) { New-Item -ItemType Directory -Path $candidate -Force | Out-Null }
    $candidate = (Resolve-Path -LiteralPath $candidate).Path
    $test = Join-Path $candidate ('.write-test-' + [guid]::NewGuid().ToString('N'))
    try { [IO.File]::WriteAllText($test,'test'); Remove-Item -LiteralPath $test -Force }
    catch { throw "Output folder is not writable: $candidate" }
    $script:OutputBase = $candidate
    $script:RunDir = Join-Path $candidate ('vSphere-SharedDisk-Migration-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $script:RunDir -Force | Out-Null
    $script:DebugDir = Join-Path $script:RunDir 'Debug-Artifacts'
    New-Item -ItemType Directory -Path $script:DebugDir -Force | Out-Null
    $script:LogFile = Join-Path $script:RunDir ('vSphere-SharedDisk-Migration-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    $script:TranscriptFile = Join-Path $script:RunDir ('vSphere-SharedDisk-PowerShell-Transcript-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    if ($script:txtOutputPath) { $script:txtOutputPath.Text = $script:OutputBase }
}
function Write-Log {
    param([string]$Message,[ValidateSet('INFO','PASS','WARN','ERROR')][string]$Level='INFO')
    $safe = Protect-DiagnosticText $Message
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') [$Level] $safe"
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding utf8 }
    if ($script:txtLog) { $script:txtLog.AppendText($line + [Environment]::NewLine); $script:txtLog.ScrollToEnd(); DoEvents }
}
function Start-AppTranscript {
    if ($script:TranscriptStarted -or -not $script:TranscriptFile) { return }
    try { Start-Transcript -LiteralPath $script:TranscriptFile -IncludeInvocationHeader -Force | Out-Null; $script:TranscriptStarted = $true }
    catch { Write-Log "Transcript could not start: $($_.Exception.Message)" WARN }
}
function Stop-AppTranscript { if ($script:TranscriptStarted) { try { Stop-Transcript | Out-Null } catch {}; $script:TranscriptStarted = $false } }
function Save-DebugArtifact {
    param([string]$Category,[string]$Operation,$Data)
    if (-not $script:DebugDir) { return $null }
    $script:DebugSequence++
    $name = '{0:d4}-{1}-{2}-{3}.json' -f $script:DebugSequence,(Get-Date -Format 'yyyyMMdd-HHmmss-fff'),($Category -replace '[^A-Za-z0-9_-]','_'),($Operation -replace '[^A-Za-z0-9_-]','_')
    $path = Join-Path $script:DebugDir $name
    $Data | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $path -Encoding utf8BOM
    return $path
}
function Write-ExceptionDiagnostic {
    param($ErrorRecord,[string]$Context)
    $detail = [ordered]@{ CapturedAt=(Get-Date).ToString('o'); Context=$Context; Message=$ErrorRecord.Exception.Message; Type=$ErrorRecord.Exception.GetType().FullName; Line=$ErrorRecord.InvocationInfo.ScriptLineNumber; Position=$ErrorRecord.InvocationInfo.PositionMessage; Stack=$ErrorRecord.ScriptStackTrace }
    $path = Save-DebugArtifact 'EXCEPTION' $Context $detail
    Write-Log "${Context}: $($ErrorRecord.Exception.Message); Diagnostic=$path" ERROR
    return $path
}
function Wait-Tcp {
    param([string]$HostName,[int]$Port=443,[int]$Seconds=10)
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        try { $c=[Net.Sockets.TcpClient]::new(); $a=$c.BeginConnect($HostName,$Port,$null,$null); if($a.AsyncWaitHandle.WaitOne(1000)){ $c.EndConnect($a);$c.Close();return $true };$c.Close() } catch {}
    }
    return $false
}
function Ensure-Module {
    param([string]$Name)
    if (Test-HasModule $Name) { Import-Module $Name -ErrorAction Stop | Out-Null; return $true }
    $old=$ProgressPreference
    try {
        $ProgressPreference='SilentlyContinue'
        Install-PackageProvider NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue | Out-Null
        Set-PSRepository PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue | Out-Null
        Install-Module $Name -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck -AcceptLicense
        Import-Module $Name -ErrorAction Stop | Out-Null
        Write-Log "$Name installed and imported." PASS
        return $true
    } catch { Write-Log "$Name installation failed: $($_.Exception.Message)" ERROR; return $false }
    finally { $ProgressPreference=$old }
}
function Show-ThemedNotice {
    param([string]$Heading,[string]$Message,[ValidateSet('Success','Information','Warning','Error')][string]$Kind='Information',[string]$Details='')
    $icon = switch($Kind){'Success'{'Information'};'Warning'{'Warning'};'Error'{'Error'};default{'Information'}}
    [Windows.MessageBox]::Show(($Message + $(if($Details){"`n`n$Details"}else{''})),$Heading,'OK',$icon) | Out-Null
}
function Select-OutputFolder {
    $dialog = [Windows.Forms.FolderBrowserDialog]::new(); $dialog.Description='Select base folder for manifests, CSV files, logs, and evidence'; $dialog.SelectedPath=$script:OutputBase
    if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { Initialize-RunFolder $dialog.SelectedPath; Start-AppTranscript; Write-Log "Output folder initialized: $($script:RunDir)" PASS }
}
# endregion

# region vCenter and inventory
function Get-VCenterIdentity {
    $si = Get-View -Server $script:VIServer -Id 'ServiceInstance-ServiceInstance' -ErrorAction Stop

    # Content.SessionManager is a ManagedObjectReference, not the SessionManager view.
    # Resolve the view before reading CurrentSession. Fall back to the VIServer user
    # when a vCenter build or PowerCLI serialization does not expose CurrentSession.
    $connectedUser = ''
    try {
        $sessionManager = Get-View -Server $script:VIServer `
            -Id $si.Content.SessionManager `
            -Property CurrentSession `
            -ErrorAction Stop
        if ($sessionManager.CurrentSession) {
            $connectedUser = [string]$sessionManager.CurrentSession.UserName
        }
    }
    catch {
        try { $connectedUser = [string]$script:VIServer.User }
        catch { $connectedUser = '' }
        Write-Log "Connected-user discovery used the VIServer fallback: $($_.Exception.Message)" WARN
    }

    [pscustomobject][ordered]@{
        Name          = [string]$script:VIServer.Name
        InstanceUuid  = [string]$si.Content.About.InstanceUuid
        FullName      = [string]$si.Content.About.FullName
        Version       = [string]$si.Content.About.Version
        Build         = [string]$si.Content.About.Build
        ConnectedUser = $connectedUser
        ConnectedAt   = (Get-Date).ToString('o')
    }
}
function Connect-SourceVCenter {
    if (-not (Test-HasModule 'VCF.PowerCLI')) { if (-not (Ensure-Module 'VCF.PowerCLI')) { throw 'VCF.PowerCLI is required.' } }
    Import-Module VCF.PowerCLI -ErrorAction Stop | Out-Null
    try { Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null } catch {}
    $server=$script:txtVCenter.Text.Trim(); $user=$script:txtUsername.Text.Trim(); $password=$script:txtPassword.Password
    if (-not $server -or -not $user -or -not $password) { throw 'Source vCenter, username, and password are required.' }
    if (-not (Wait-Tcp $server 443 10)) { throw "TCP 443 is not reachable on $server." }
    if ($script:VIServer) { Disconnect-VIServer -Server $script:VIServer -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
    $credential=[pscredential]::new($user,(ConvertTo-SecureString $password -AsPlainText -Force))
    $newConnection = $null
    try {
        $newConnection = Connect-VIServer -Server $server -Credential $credential -Force -ErrorAction Stop
        $script:VIServer = $newConnection
        $script:VCenterIdentity = Get-VCenterIdentity
    }
    catch {
        if ($newConnection) {
            Disconnect-VIServer -Server $newConnection -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }
        $script:VIServer = $null
        $script:VCenterIdentity = $null
        throw
    }
    $script:lblConnection.Text="Connected: $($script:VCenterIdentity.Name)"; $script:lblConnection.Foreground='LightGreen'
    Write-Log "Connected to source vCenter '$($script:VCenterIdentity.Name)' version $($script:VCenterIdentity.Version) build $($script:VCenterIdentity.Build)." PASS
    Update-UiState
}
function Disconnect-SourceVCenter {
    if($script:VIServer){Disconnect-VIServer -Server $script:VIServer -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null}
    $script:VIServer=$null;$script:VCenterIdentity=$null;$script:Discovery=$null;$script:Validation=$null
    $script:lblConnection.Text='Not connected';$script:lblConnection.Foreground='#76C7D8'
    Clear-InventoryGrids;Update-UiState;Write-Log 'Disconnected from source vCenter.' INFO
}
function Resolve-ExactVm {
    param([string]$Name,[string]$Role)
    if ([string]::IsNullOrWhiteSpace($Name)) { throw "$Role VM name is required." }
    $matches=@(Get-VM -Server $script:VIServer -Name $Name.Trim() -ErrorAction SilentlyContinue)
    if($matches.Count -eq 0){throw "$Role VM '$Name' was not found."}
    if($matches.Count -gt 1){throw "$Role VM name '$Name' is ambiguous and resolved to $($matches.Count) objects."}
    return $matches[0]
}
function Get-ClusterAndHostInfo {
    param($VM)
    $hostName='';$hostId='';$clusterName='';$clusterId=''
    try{$hostName=[string]$VM.VMHost.Name;$hostId=[string]$VM.VMHost.Id}catch{}
    try{$cluster=Get-Cluster -Server $script:VIServer -VM $VM -ErrorAction SilentlyContinue | Select-Object -First 1;if($cluster){$clusterName=$cluster.Name;$clusterId=$cluster.Id}}catch{}
    [pscustomobject]@{HostName=$hostName;HostId=$hostId;ClusterName=$clusterName;ClusterId=$clusterId}
}
function Get-StoragePolicyInfo {
    param($VM,$HardDisk)
    try {
        $cfg=Get-SpbmEntityConfiguration -Server $script:VIServer -HardDisk $HardDisk -ErrorAction Stop | Select-Object -First 1
        if($cfg -and $cfg.StoragePolicy){return [pscustomobject]@{Name=[string]$cfg.StoragePolicy.Name;Id=[string]$cfg.StoragePolicy.Id}}
    } catch {}
    return [pscustomobject]@{Name='';Id=''}
}
function Get-DatastoreRecord {
    param($Backing)
    $name='';$id='';$uuid=''
    try {
        if($Backing.Datastore){$dsView=Get-View -Server $script:VIServer -Id $Backing.Datastore -Property Name,Info -ErrorAction Stop;$name=[string]$dsView.Name;$id=[string]$dsView.MoRef.Value;try{$uuid=[string]$dsView.Info.Vmfs.Uuid}catch{}}
    } catch {}
    [pscustomobject]@{Name=$name;Id=$id;Uuid=$uuid}
}
function ConvertTo-CanonicalVmdkPath {
    param([string]$Path)
    if([string]::IsNullOrWhiteSpace($Path)){return ''}
    return (($Path.Trim() -replace '\\','/') -replace '/+','/').ToLowerInvariant()
}
function Get-ControllerTypeName {
    param($Device)
    switch -Regex ($Device.GetType().Name) {'ParaVirtualSCSI'{'VMware Paravirtual'};'VirtualLsiLogicSASController'{'LSI Logic SAS'};'VirtualLsiLogicController'{'LSI Logic Parallel'};'VirtualBusLogicController'{'BusLogic'};default{$Device.GetType().Name}}
}
function Get-NormalizedBusSharing {
    param($Value)
    switch -Regex ([string]$Value) {'noSharing'{'None'};'virtualSharing'{'Virtual'};'physicalSharing'{'Physical'};default{if($Value){[string]$Value}else{'Unknown'}}}
}
function Get-NormalizedDiskSharing {
    param($Value)
    if(([string]$Value) -match 'sharingMultiWriter'){return 'Multi-writer'}
    return 'No sharing'
}
function Get-DiskModeName { param($Backing) try{return [string]$Backing.DiskMode}catch{return ''} }
function Get-ManagedObjectName {
    [CmdletBinding()]
    param(
        [AllowNull()]$Reference,
        [Parameter(Mandatory)][string]$Fallback
    )

    if ($null -eq $Reference) { return $Fallback }

    # PowerCLI inventory properties may be full objects, managed-object references,
    # scalar IDs, arrays, or partially populated proxy objects. Resolve by property
    # only when the property is known to exist, then fall back to Get-View.
    try {
        $nameProperty = $Reference.PSObject.Properties['Name']
        if ($nameProperty -and -not [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) {
            return [string]$nameProperty.Value
        }
    }
    catch {}

    try {
        $candidate = @($Reference) | Select-Object -First 1
        if ($candidate) {
            $view = Get-View -Server $script:VIServer -Id $candidate -Property Name -ErrorAction Stop
            if ($view -and -not [string]::IsNullOrWhiteSpace([string]$view.Name)) {
                return [string]$view.Name
            }
        }
    }
    catch {
        Write-Log "Managed-object name resolution used fallback '$Fallback': $($_.Exception.Message)" WARN
    }

    return $Fallback
}
function Get-VmConfiguration {
    param($VM,[ValidateSet('Primary','Secondary')][string]$Role)

    $vmNameProperty = $VM.PSObject.Properties['Name']
    if (-not $vmNameProperty -or [string]::IsNullOrWhiteSpace([string]$vmNameProperty.Value)) {
        throw "$Role VM inventory object does not expose a usable Name property. RuntimeType='$($VM.GetType().FullName)'."
    }
    $vmName = [string]$vmNameProperty.Value
    $view=Get-View -Server $script:VIServer -Id $VM.Id -Property Name,Config,Runtime,Guest,Snapshot,Parent,ResourcePool -ErrorAction Stop
    $devices=@($view.Config.Hardware.Device)
    $controllers=@($devices | Where-Object { $_ -is [VMware.Vim.VirtualSCSIController] })
    $hardDisks=@(Get-HardDisk -Server $script:VIServer -VM $VM -ErrorAction Stop)
    $hardDiskByKey=@{};foreach($hd in $hardDisks){$hardDiskByKey[[int]$hd.ExtensionData.Key]=$hd}
    $controllerByKey=@{};foreach($c in $controllers){$controllerByKey[[int]$c.Key]=$c}
    $controllerRows=[Collections.Generic.List[object]]::new()
    foreach($c in $controllers){
        $attached=@($devices|Where-Object{$_.ControllerKey -eq $c.Key -and $_ -is [VMware.Vim.VirtualDisk]})
        $controllerRows.Add([pscustomobject][ordered]@{Role=$Role;VMName=$vmName;DeviceLabel=[string]$c.DeviceInfo.Label;DeviceKey=[int]$c.Key;BusNumber=[int]$c.BusNumber;ControllerType=(Get-ControllerTypeName $c);BusSharing=(Get-NormalizedBusSharing $c.SharedBus);AttachedDiskCount=$attached.Count;Validation='Not validated'})
    }
    $diskRows=[Collections.Generic.List[object]]::new()
    foreach($d in @($devices|Where-Object{$_ -is [VMware.Vim.VirtualDisk]})){
        $controller=$controllerByKey[[int]$d.ControllerKey];$hd=$hardDiskByKey[[int]$d.Key];$backing=$d.Backing;$ds=Get-DatastoreRecord $backing;$policy=if($hd){Get-StoragePolicyInfo $VM $hd}else{[pscustomobject]@{Name='';Id=''}}
        $backingType=$backing.GetType().Name;$sharing=Get-NormalizedDiskSharing $backing.Sharing;$path=[string]$backing.FileName
        $diskRows.Add([pscustomobject][ordered]@{
            Role=$Role;VMName=$vmName;DeviceLabel=[string]$d.DeviceInfo.Label;DeviceKey=[int]$d.Key;ControllerKey=[int]$d.ControllerKey;ControllerLabel=if($controller){[string]$controller.DeviceInfo.Label}else{''};ControllerBusNumber=if($controller){[int]$controller.BusNumber}else{-1};ControllerType=if($controller){Get-ControllerTypeName $controller}else{'Unknown'};ControllerBusSharing=if($controller){Get-NormalizedBusSharing $controller.SharedBus}else{'Unknown'};UnitNumber=[int]$d.UnitNumber;VirtualDeviceNode=if($controller){('SCSI {0}:{1}' -f $controller.BusNumber, $d.UnitNumber)}else{'Unresolved'};CapacityBytes=[int64]$d.CapacityInBytes;CapacityGB=[math]::Round($d.CapacityInBytes/1GB,2);BackingType=$backingType;BackingFileName=$path;CanonicalBackingPath=(ConvertTo-CanonicalVmdkPath $path);DatastoreName=$ds.Name;DatastoreMoRef=$ds.Id;DatastoreUuid=$ds.Uuid;DiskMode=(Get-DiskModeName $backing);Sharing=$sharing;SharingRaw=[string]$backing.Sharing;ThinProvisioned=try{[bool]$backing.ThinProvisioned}catch{$null};EagerlyScrubbed=try{[bool]$backing.EagerlyScrub}catch{$null};WriteThrough=try{[bool]$backing.WriteThrough}catch{$null};Uuid=try{[string]$backing.Uuid}catch{''};ContentId=try{[string]$backing.ContentId}catch{''};ChangeId=try{[string]$backing.ChangeId}catch{''};StoragePolicyName=$policy.Name;StoragePolicyId=$policy.Id;RdmCompatibilityMode=try{[string]$backing.CompatibilityMode}catch{''};RdmDeviceName=try{[string]$backing.DeviceName}catch{''};RdmLunUuid=try{[string]$backing.LunUuid}catch{''};OriginallyAttached=$true;OriginallyMultiWriter=($sharing -eq 'Multi-writer');CorrelationId='';CorrelationStatus=if($sharing -eq 'Multi-writer'){'Pending'}else{'Not Applicable'};PeerVMName='';PeerDeviceKey=$null;PlannedAction='None';Validation='Not validated'
        })
    }
    $ch=Get-ClusterAndHostInfo $VM
    $snapshots=@();try{if($view.Snapshot){$snapshots=@(Get-Snapshot -Server $script:VIServer -VM $VM -ErrorAction SilentlyContinue)}}catch{}
    $vmRecord=[pscustomobject][ordered]@{Role=$Role;VMName=$vmName;VMId=[string]$VM.Id;MoRef=[string]$view.MoRef.Value;InstanceUuid=[string]$view.Config.InstanceUuid;ConfigUuid=[string]$view.Config.Uuid;BiosUuid=[string]$view.Config.Uuid;PowerState=[string]$view.Runtime.PowerState;ConnectionState=[string]$view.Runtime.ConnectionState;GuestId=[string]$view.Config.GuestId;GuestFullName=[string]$view.Config.GuestFullName;NumCpu=[int]$view.Config.Hardware.NumCPU;MemoryMB=[int64]$view.Config.Hardware.MemoryMB;MemoryGB=[math]::Round($view.Config.Hardware.MemoryMB/1024,2);HardwareVersion=[string]$view.Config.Version;ChangeVersion=[string]$view.Config.ChangeVersion;VmPathName=[string]$view.Config.Files.VmPathName;ClusterName=$ch.ClusterName;ClusterMoRef=$ch.ClusterId;HostName=$ch.HostName;HostMoRef=$ch.HostId;FolderName=(Get-ManagedObjectName -Reference $VM.Folder -Fallback '[Folder unavailable]');ResourcePoolName=(Get-ManagedObjectName -Reference $VM.ResourcePool -Fallback '[Resource pool unavailable]');SnapshotCount=$snapshots.Count;SnapshotNames=@($snapshots | ForEach-Object {
    $nameProperty = $_.PSObject.Properties['Name']
    if ($nameProperty -and $null -ne $nameProperty.Value) {
        [string]$nameProperty.Value
    }
});ConsolidationNeeded=[bool]$view.Runtime.ConsolidationNeeded;CbtEnabled=[bool]$view.Config.ChangeTrackingEnabled;ControllerCount=$controllerRows.Count;DiskCount=$diskRows.Count;PrivateDiskCount=@($diskRows|Where-Object{-not $_.OriginallyMultiWriter}).Count;MultiWriterDiskCount=@($diskRows|Where-Object{$_.OriginallyMultiWriter}).Count;CapturedAt=(Get-Date).ToString('o');Validation='Not validated'}
    return [pscustomobject]@{VM=$vmRecord;Controllers=@($controllerRows);Disks=@($diskRows)}
}
function Resolve-SharedDiskCorrelations {
    param($PrimaryDisks,$SecondaryDisks)
    $results=[Collections.Generic.List[object]]::new();$primaryShared=@($PrimaryDisks|Where-Object OriginallyMultiWriter);$secondaryShared=@($SecondaryDisks|Where-Object OriginallyMultiWriter)
    foreach($sd in $secondaryShared){
        $exact=@($primaryShared|Where-Object{$_.CanonicalBackingPath -eq $sd.CanonicalBackingPath -and $_.DatastoreMoRef -eq $sd.DatastoreMoRef})
        $uuid=@();if($exact.Count -eq 0 -and $sd.Uuid){$uuid=@($primaryShared|Where-Object{$_.Uuid -and $_.Uuid -eq $sd.Uuid -and $_.CapacityBytes -eq $sd.CapacityBytes})}
        $match=$null;$status='Unmatched';$detail='No Primary multi-writer disk has the same backing identity.'
        if($exact.Count -eq 1){$match=$exact[0];$status='ExactBackingMatch';$detail='Datastore and canonical VMDK path match.'}
        elseif($exact.Count -gt 1){$status='Ambiguous';$detail="$($exact.Count) Primary disks share the same canonical backing identity."}
        elseif($uuid.Count -eq 1){$match=$uuid[0];$status='BackingUuidMatch';$detail='Backing UUID and capacity match.'}
        elseif($uuid.Count -gt 1){$status='Ambiguous';$detail="$($uuid.Count) Primary disks share the same UUID match."}
        if($match){
            $id=[guid]::NewGuid().ToString();$sd.CorrelationId=$id;$sd.CorrelationStatus=$status;$sd.PeerVMName=$match.VMName;$sd.PeerDeviceKey=$match.DeviceKey;$sd.PlannedAction='Detach from Secondary in Milestone 2';$match.CorrelationId=$id;$match.CorrelationStatus=$status;$match.PeerVMName=$sd.VMName;$match.PeerDeviceKey=$sd.DeviceKey;$match.PlannedAction='None - Primary remains unchanged'
            $capacityMatch=($match.CapacityBytes -eq $sd.CapacityBytes);$scsiMatch=($match.VirtualDeviceNode -eq $sd.VirtualDeviceNode)
        } else {$id='';$capacityMatch=$false;$scsiMatch=$false}
        $results.Add([pscustomobject][ordered]@{CorrelationId=$id;PrimaryVM=if($match){$match.VMName}else{''};PrimaryDevice=if($match){$match.DeviceLabel}else{''};PrimaryDeviceKey=if($match){$match.DeviceKey}else{$null};PrimaryScsiNode=if($match){$match.VirtualDeviceNode}else{''};PrimaryVmdkPath=if($match){$match.BackingFileName}else{''};PrimarySharing=if($match){$match.Sharing}else{''};PrimaryDiskMode=if($match){$match.DiskMode}else{''};SecondaryVM=$sd.VMName;SecondaryDevice=$sd.DeviceLabel;SecondaryDeviceKey=$sd.DeviceKey;SecondaryScsiNode=$sd.VirtualDeviceNode;SecondaryVmdkPath=$sd.BackingFileName;SecondarySharing=$sd.Sharing;SecondaryDiskMode=$sd.DiskMode;CapacityBytes=$sd.CapacityBytes;CapacityGB=$sd.CapacityGB;CapacityMatch=$capacityMatch;ScsiNodeMatch=$scsiMatch;Status=$status;Detail=$detail;PlannedPrimaryAction='None';PlannedSecondaryAction=if($match){'Detach device only in Milestone 2'}else{'Blocked'}})
    }
    return @($results)
}
function Discover-VmPair {
    if(-not$script:VIServer){throw 'Connect to the source vCenter first.'}
    $primary=Resolve-ExactVm $script:txtPrimaryVM.Text 'Primary';$secondary=Resolve-ExactVm $script:txtSecondaryVM.Text 'Secondary'
    if($primary.Id -eq $secondary.Id){throw 'Primary and Secondary resolve to the same virtual machine.'}
    Write-Log "Collecting authoritative hardware inventory for Primary '$($primary.Name)' and Secondary '$($secondary.Name)'..." INFO
    $p=Get-VmConfiguration $primary Primary;$s=Get-VmConfiguration $secondary Secondary
    $corr=Resolve-SharedDiskCorrelations $p.Disks $s.Disks
    $script:Discovery=[pscustomobject]@{CapturedAt=(Get-Date).ToString('o');Primary=$p;Secondary=$s;VMs=@($p.VM,$s.VM);Controllers=@($p.Controllers)+@($s.Controllers);Disks=@($p.Disks)+@($s.Disks);Correlations=@($corr)}
    Bind-DiscoveryGrids; $script:Validation=$null; $script:ManifestPath=$null;$script:ChecksumPath=$null
    Write-Log "Discovery completed. Controllers=$($script:Discovery.Controllers.Count); Disks=$($script:Discovery.Disks.Count); Shared correlations=$($corr.Count)." PASS
    Update-UiState
}
# endregion

# region Validation and export
function Add-Finding { param($List,[string]$Severity,[string]$Category,[string]$Object,[string]$Message) $List.Add([pscustomobject][ordered]@{Severity=$Severity;Category=$Category;Object=$Object;Message=$Message}) }
function Test-SourceConfiguration {
    if(-not$script:Discovery){throw 'Discover the VM pair first.'}
    $findings=[Collections.Generic.List[object]]::new();$vms=@($script:Discovery.VMs);$disks=@($script:Discovery.Disks);$corr=@($script:Discovery.Correlations)
    foreach($vm in $vms){
        if($vm.PowerState -ne 'poweredOff'){Add-Finding $findings 'BLOCK' 'PowerState' $vm.VMName "VM must be powered off for the final Phase I readiness state. Current state: $($vm.PowerState)."}
        if($vm.ConnectionState -ne 'connected'){Add-Finding $findings 'BLOCK' 'ConnectionState' $vm.VMName "VM connection state is $($vm.ConnectionState)."}
        if($vm.SnapshotCount -gt 0){Add-Finding $findings 'BLOCK' 'Snapshot' $vm.VMName "$($vm.SnapshotCount) snapshot(s) detected: $($vm.SnapshotNames -join ', ')."}
        if($vm.ConsolidationNeeded){Add-Finding $findings 'BLOCK' 'Snapshot' $vm.VMName 'Snapshot consolidation is required.'}
        if($vm.CbtEnabled){Add-Finding $findings 'BLOCK' 'CBT' $vm.VMName 'Changed Block Tracking is enabled.'}
        if($vm.MultiWriterDiskCount -eq 0){Add-Finding $findings 'BLOCK' 'MultiWriter' $vm.VMName 'No multi-writer disks were discovered.'}
    }
    foreach($disk in $disks){
        if($disk.ControllerBusNumber -lt 0){Add-Finding $findings 'BLOCK' 'Controller' "$($disk.VMName)/$($disk.DeviceLabel)" 'Disk controller could not be resolved.'}
        if($disk.BackingType -match 'RawDiskMapping|RawDisk'){Add-Finding $findings 'BLOCK' 'Backing' "$($disk.VMName)/$($disk.DeviceLabel)" 'RDM backing detected. Milestone 1 supports VMDK backings only.'}
        if($disk.BackingType -notmatch 'FlatVer2BackingInfo|SeSparseBackingInfo|SparseVer2BackingInfo' -and $disk.BackingType -notmatch 'VirtualDiskFlatVer2BackingInfo'){Add-Finding $findings 'BLOCK' 'Backing' "$($disk.VMName)/$($disk.DeviceLabel)" "Unsupported or unrecognized backing type: $($disk.BackingType)."}
        if($disk.OriginallyMultiWriter -and $disk.DiskMode -notmatch 'independent_persistent'){Add-Finding $findings 'WARN' 'DiskMode' "$($disk.VMName)/$($disk.DeviceLabel)" "Multi-writer disk mode is '$($disk.DiskMode)', not independent_persistent."}
    }
    foreach($group in @($disks|Group-Object VMName,VirtualDeviceNode|Where-Object Count -gt 1)){Add-Finding $findings 'BLOCK' 'ScsiNode' $group.Name 'Duplicate SCSI node detected.'}
    if($corr.Count -eq 0){Add-Finding $findings 'BLOCK' 'Correlation' 'VM Pair' 'No shared-disk correlations were produced.'}
    foreach($c in $corr){
        if($c.Status -notin @('ExactBackingMatch','BackingUuidMatch')){Add-Finding $findings 'BLOCK' 'Correlation' $c.SecondaryDevice "$($c.Status): $($c.Detail)"}
        if($c.Status -in @('ExactBackingMatch','BackingUuidMatch') -and -not$c.CapacityMatch){Add-Finding $findings 'BLOCK' 'Capacity' $c.SecondaryDevice 'Correlated Primary and Secondary capacities differ.'}
        if(-not$c.ScsiNodeMatch -and $c.Status -in @('ExactBackingMatch','BackingUuidMatch')){Add-Finding $findings 'WARN' 'ScsiNode' $c.SecondaryDevice "Primary node '$($c.PrimaryScsiNode)' differs from Secondary node '$($c.SecondaryScsiNode)'."}
    }
    $blocks=@($findings|Where-Object Severity -eq 'BLOCK').Count;$warnings=@($findings|Where-Object Severity -eq 'WARN').Count
    $script:Validation=[pscustomobject][ordered]@{ValidatedAt=(Get-Date).ToString('o');Status=if($blocks){'Blocked'}else{'Pass'};BlockingCount=$blocks;WarningCount=$warnings;Findings=@($findings)}
    $script:gridFindings.ItemsSource=@($findings);$script:lblValidation.Text=if($blocks){"Blocked ($blocks), warnings ($warnings)"}else{"Pass, warnings ($warnings)"};$script:lblValidation.Foreground=if($blocks){'Tomato'}else{'LightGreen'}
    foreach($f in $findings){Write-Log "$($f.Severity): [$($f.Category)] $($f.Object): $($f.Message)" $(if($f.Severity -eq 'BLOCK'){'ERROR'}else{'WARN'})}
    if(-not$findings.Count){Write-Log 'Source validation passed with no findings.' PASS}else{Write-Log "Source validation completed. Blocking=$blocks; Warnings=$warnings." $(if($blocks){'ERROR'}else{'PASS'})}
    $inventoryValidationStatus = if ($blocks) { 'Blocked' } else { 'Pass' }
    Set-ValidatedInventoryStatus -Status $inventoryValidationStatus
    Update-UiState
    return ($blocks -eq 0)
}
function New-ManifestObject {
    [ordered]@{SchemaVersion='1.0';Tool=[ordered]@{Name=$script:AppName;Version=$script:Version;Milestone='Phase I';Mode='Discovery, Manifest, Controlled Secondary Detach, and Post-Change Validation'};ManifestId=[guid]::NewGuid().ToString();CapturedAt=(Get-Date).ToString('o');SourceVCenter=$script:VCenterIdentity;ClusterPair=[ordered]@{PrimaryVM=$script:Discovery.Primary.VM;SecondaryVM=$script:Discovery.Secondary.VM};Controllers=@($script:Discovery.Controllers);Disks=@($script:Discovery.Disks);SharedDiskCorrelations=@($script:Discovery.Correlations);Validation=$script:Validation;PlannedChanges=@($script:Discovery.Disks|Where-Object{$_.Role -eq 'Secondary' -and $_.OriginallyMultiWriter}|ForEach-Object{[ordered]@{VMName=$_.VMName;DeviceKey=$_.DeviceKey;DeviceLabel=$_.DeviceLabel;ScsiNode=$_.VirtualDeviceNode;VmdkPath=$_.BackingFileName;Operation='Detach device only in Milestone 2';FileOperation='None'}});RollbackActions=@('Keep both VMs powered off','Load and verify this manifest','Resolve each shared VMDK through the Primary VM','Reattach each disk to the Secondary using the recorded controller bus and unit number','Restore original disk mode and sharingMultiWriter','Compare both VMs with this manifest before power-on');Integrity=[ordered]@{ChecksumAlgorithm='SHA256';ChecksumFile='SharedDiskMigrationManifest.sha256'}}
}
function Export-ManifestAndInventory {
    if(-not$script:Discovery){throw 'Discover the VM pair first.'}
    if(-not$script:Validation){throw 'Run source validation before exporting the manifest.'}
    if(-not$script:RunDir){Initialize-RunFolder $script:OutputBase;Start-AppTranscript}
    $manifest=New-ManifestObject
    $script:ManifestPath=Join-Path $script:RunDir 'SharedDiskMigrationManifest.json'
    $script:ChecksumPath=Join-Path $script:RunDir 'SharedDiskMigrationManifest.sha256'
    $manifest|ConvertTo-Json -Depth 50|Set-Content -LiteralPath $script:ManifestPath -Encoding utf8BOM
    $hash=(Get-FileHash -LiteralPath $script:ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  SharedDiskMigrationManifest.json"|Set-Content -LiteralPath $script:ChecksumPath -Encoding ascii
    @($script:Discovery.VMs | ForEach-Object {
    $copy = $_ | Select-Object *
    $copy.SnapshotNames = @($_.SnapshotNames) -join '; '
    $copy
}) | Export-Csv -LiteralPath (Join-Path $script:RunDir 'VM-Summary.csv') -NoTypeInformation -Encoding utf8BOM
    @($script:Discovery.Controllers)|Export-Csv -LiteralPath (Join-Path $script:RunDir 'ControllerInventory.csv') -NoTypeInformation -Encoding utf8BOM
    @($script:Discovery.Disks)|Export-Csv -LiteralPath (Join-Path $script:RunDir 'DiskInventory.csv') -NoTypeInformation -Encoding utf8BOM
    @($script:Discovery.Correlations)|Export-Csv -LiteralPath (Join-Path $script:RunDir 'SharedDiskCorrelation.csv') -NoTypeInformation -Encoding utf8BOM
    $script:Validation|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $script:RunDir 'PreChange-Validation.json') -Encoding utf8BOM
    $manifest.PlannedChanges|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $script:RunDir 'PlannedChanges.json') -Encoding utf8BOM
    [ordered]@{ManifestId=$manifest.ManifestId;ManifestPath=$script:ManifestPath;Checksum=$hash;RunFolder=$script:RunDir;Note='Phase I evidence export completed. The manifest records discovery and planned changes; controlled detach evidence is recorded separately when executed.'}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $script:RunDir 'Export-Summary.json') -Encoding utf8BOM
    $script:lblManifest.Text="Exported: $hash";$script:lblManifest.Foreground='LightGreen';Write-Log "Manifest and supporting inventory exported. Manifest=$($script:ManifestPath); SHA256=$hash" PASS
    Update-UiState;Show-ThemedNotice 'Manifest Export Complete' 'The Phase I manifest and supporting inventory files were created.' Success "Run folder: $($script:RunDir)`nSHA256: $hash"
}
# endregion

# region Milestone 2 - controlled Secondary detach
function Get-ManifestAndVerifyIntegrity {
    if (-not $script:ManifestPath -or -not (Test-Path -LiteralPath $script:ManifestPath)) {
        throw 'Export the pre-change manifest before preparing a detach operation.'
    }
    if (-not $script:ChecksumPath -or -not (Test-Path -LiteralPath $script:ChecksumPath)) {
        throw 'The manifest checksum file is missing.'
    }
    $expectedLine = (Get-Content -LiteralPath $script:ChecksumPath -Raw).Trim()
    $expectedHash = ($expectedLine -split '\s+')[0].ToLowerInvariant()
    $actualHash = (Get-FileHash -LiteralPath $script:ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expectedHash -ne $actualHash) {
        throw "Manifest checksum mismatch. Expected='$expectedHash'; Actual='$actualHash'."
    }
    $manifest = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json -Depth 60 -DateKind String
    if ([string]$manifest.SchemaVersion -ne '1.0') { throw "Unsupported manifest schema '$($manifest.SchemaVersion)'." }
    if ([string]$manifest.SourceVCenter.InstanceUuid -ne [string]$script:VCenterIdentity.InstanceUuid) {
        throw 'The manifest source-vCenter identity does not match the active connection.'
    }
    return $manifest
}
function Set-ValidatedInventoryStatus {
    param([string]$Status)
    if (-not $script:Discovery) { return }
    foreach ($row in @($script:Discovery.VMs)) { $row.Validation = $Status }
    foreach ($row in @($script:Discovery.Controllers)) { $row.Validation = $Status }
    foreach ($row in @($script:Discovery.Disks)) { $row.Validation = $Status }
    if ($script:gridVMs) { $script:gridVMs.Items.Refresh() }
    if ($script:gridControllers) { $script:gridControllers.Items.Refresh() }
    if ($script:gridDisks) { $script:gridDisks.Items.Refresh() }
}
function Test-LiveDetachContract {
    param($Manifest)
    $primaryName = [string]$Manifest.ClusterPair.PrimaryVM.VMName
    $secondaryName = [string]$Manifest.ClusterPair.SecondaryVM.VMName
    $primary = Resolve-ExactVm $primaryName 'Primary'
    $secondary = Resolve-ExactVm $secondaryName 'Secondary'
    $primaryConfig = Get-VmConfiguration $primary Primary
    $secondaryConfig = Get-VmConfiguration $secondary Secondary

    if ($primaryConfig.VM.PowerState -ne 'poweredOff') { throw "Primary VM '$primaryName' is not powered off." }
    if ($secondaryConfig.VM.PowerState -ne 'poweredOff') { throw "Secondary VM '$secondaryName' is not powered off." }
    if ([string]$primaryConfig.VM.ChangeVersion -ne [string]$Manifest.ClusterPair.PrimaryVM.ChangeVersion) {
        throw "Primary VM configuration changed after manifest capture. Expected ChangeVersion='$($Manifest.ClusterPair.PrimaryVM.ChangeVersion)'; Current='$($primaryConfig.VM.ChangeVersion)'. Refresh, validate, and export a new manifest."
    }
    if ([string]$secondaryConfig.VM.ChangeVersion -ne [string]$Manifest.ClusterPair.SecondaryVM.ChangeVersion) {
        throw "Secondary VM configuration changed after manifest capture. Expected ChangeVersion='$($Manifest.ClusterPair.SecondaryVM.ChangeVersion)'; Current='$($secondaryConfig.VM.ChangeVersion)'. Refresh, validate, and export a new manifest."
    }

    $planned = @($Manifest.PlannedChanges)
    if ($planned.Count -eq 0) { throw 'The manifest contains no planned Secondary detach operations.' }
    $resolvedDevices = [Collections.Generic.List[object]]::new()
    foreach ($change in $planned) {
        if ([string]$change.VMName -ne $secondaryName) { throw "Planned change targets unexpected VM '$($change.VMName)'." }
        if ([string]$change.FileOperation -ne 'None') { throw "Safety violation: planned change for '$($change.DeviceLabel)' has FileOperation='$($change.FileOperation)'." }
        $live = @($secondaryConfig.Disks | Where-Object { [int]$_.DeviceKey -eq [int]$change.DeviceKey })
        if ($live.Count -ne 1) { throw "Secondary device key '$($change.DeviceKey)' resolved to $($live.Count) live disks; exactly one is required." }
        $disk = $live[0]
        if (-not $disk.OriginallyMultiWriter -or $disk.Sharing -ne 'Multi-writer') { throw "$secondaryName/$($disk.DeviceLabel) is not currently Multi-writer." }
        if ($disk.CanonicalBackingPath -ne (ConvertTo-CanonicalVmdkPath ([string]$change.VmdkPath))) { throw "$secondaryName/$($disk.DeviceLabel) backing path changed after manifest capture." }
        $primaryMatch = @($primaryConfig.Disks | Where-Object { $_.CanonicalBackingPath -eq $disk.CanonicalBackingPath -and $_.OriginallyMultiWriter })
        if ($primaryMatch.Count -ne 1) { throw "$secondaryName/$($disk.DeviceLabel) has $($primaryMatch.Count) matching Primary multi-writer backings; exactly one is required." }
        $resolvedDevices.Add($disk)
    }
    [pscustomobject]@{ Primary=$primaryConfig; Secondary=$secondaryConfig; Planned=$planned; Devices=@($resolvedDevices) }
}
function Show-DetachConfirmationDialog {
    param($Contract,$Manifest)
    $secondaryName=[string]$Manifest.ClusterPair.SecondaryVM.VMName
    $required="DETACH SHARED DISKS FROM $secondaryName"
    $capacity=[math]::Round((@($Contract.Devices|Measure-Object CapacityBytes -Sum).Sum/1GB),2)
    $x=@"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Confirm Secondary Shared-Disk Detach" Height="490" Width="790" WindowStartupLocation="CenterOwner" Background="#071015" Foreground="#E6E6E6" FontFamily="Segoe UI" ShowInTaskbar="False">
<Grid Margin="18"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<Border Background="#2A2108" BorderBrush="#F2C94C" BorderThickness="1" CornerRadius="4" Padding="14"><StackPanel><TextBlock Text="Destructive configuration change requiring explicit confirmation" FontSize="18" FontWeight="SemiBold" Foreground="#F2C94C"/><TextBlock Text="The VMDK backing files will not be deleted. Only confirmed virtual disk devices will be removed from the Secondary VM configuration." TextWrapping="Wrap" Margin="0,7,0,0"/></StackPanel></Border>
<TextBlock x:Name="summary" Grid.Row="1" Margin="0,14,0,8" TextWrapping="Wrap"/>
<TextBox x:Name="details" Grid.Row="2" IsReadOnly="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Background="#0D1B22" Foreground="#E6E6E6" BorderBrush="#607D8B" FontFamily="Consolas" Padding="9"/>
<StackPanel Grid.Row="3" Margin="0,12,0,4"><TextBlock x:Name="instruction" FontWeight="SemiBold"/><TextBox x:Name="phrase" Margin="0,6,0,0" Background="#071015" Foreground="#FFFFFF" BorderBrush="#F2C94C" Padding="7"/></StackPanel>
<StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="cancel" Content="Cancel" Width="110" Margin="4"/><Button x:Name="execute" Content="Execute Detach" Width="145" Margin="4" IsEnabled="False" Background="#6B2020" Foreground="#FFFFFF"/></StackPanel>
</Grid></Window>
"@
    $d=[Windows.Markup.XamlReader]::Parse($x);if($script:Window){$d.Owner=$script:Window}
    $d.FindName('summary').Text="Source vCenter: $($script:VCenterIdentity.Name)`nPrimary VM: $($Manifest.ClusterPair.PrimaryVM.VMName) (no changes)`nSecondary VM: $secondaryName`nDevices to detach: $($Contract.Devices.Count)`nTotal shared capacity: $capacity GB`nVMDK files to delete: 0"
    $d.FindName('details').Text=(@($Contract.Devices|ForEach-Object{"$($_.DeviceLabel) | $($_.VirtualDeviceNode) | $($_.CapacityGB) GB | $($_.BackingFileName)"}) -join [Environment]::NewLine)
    $d.FindName('instruction').Text="Type exactly: $required"
    $phrase=$d.FindName('phrase');$execute=$d.FindName('execute')
    $phrase.Add_TextChanged({$execute.IsEnabled=([string]::Equals($phrase.Text.Trim(),$required,[StringComparison]::OrdinalIgnoreCase))})
    $execute.Add_Click({$d.DialogResult=$true;$d.Close()});$d.FindName('cancel').Add_Click({$d.DialogResult=$false;$d.Close()})
    return [bool]$d.ShowDialog()
}
function Invoke-SecondarySharedDiskDetach {
    if (-not $script:Validation -or $script:Validation.Status -ne 'Pass') { throw 'Source validation must pass before detach.' }
    $manifest=Get-ManifestAndVerifyIntegrity
    $contract=Test-LiveDetachContract $manifest
    $script:gridDetach.ItemsSource=@($contract.Devices)
    $script:DetachPreviewCurrent=$true
    $script:lblDetachStatus.Text="Preview ready: $($contract.Devices.Count) device(s)";$script:lblDetachStatus.Foreground='#F2C94C'
    Update-UiState
    if (-not (Show-DetachConfirmationDialog $contract $manifest)) { Write-Log 'Secondary shared-disk detach canceled by the operator.' WARN; return }

    # Re-run the entire live contract after typed confirmation to close the UI review race.
    $contract=Test-LiveDetachContract $manifest
    $secondaryVm=Resolve-ExactVm ([string]$manifest.ClusterPair.SecondaryVM.VMName) 'Secondary'
    $secondaryView=Get-View -Server $script:VIServer -Id $secondaryVm.Id -Property Config.Hardware.Device,Config.ChangeVersion,Runtime.PowerState -ErrorAction Stop
    $spec=[VMware.Vim.VirtualMachineConfigSpec]::new()
    $spec.ChangeVersion=[string]$secondaryView.Config.ChangeVersion
    $deviceChanges=[Collections.Generic.List[VMware.Vim.VirtualDeviceConfigSpec]]::new()
    foreach($plannedDisk in @($contract.Devices)){
        $liveDevice=@($secondaryView.Config.Hardware.Device|Where-Object{$_ -is [VMware.Vim.VirtualDisk] -and [int]$_.Key -eq [int]$plannedDisk.DeviceKey})
        if($liveDevice.Count -ne 1){throw "Device key '$($plannedDisk.DeviceKey)' changed before submission."}
        $change=[VMware.Vim.VirtualDeviceConfigSpec]::new()
        $change.Operation=[VMware.Vim.VirtualDeviceConfigSpecOperation]::remove
        $change.Device=$liveDevice[0]
        if($null -ne $change.FileOperation){throw "Safety violation: FileOperation is populated for '$($plannedDisk.DeviceLabel)'."}
        $deviceChanges.Add($change)
    }
    $spec.DeviceChange=[VMware.Vim.VirtualDeviceConfigSpec[]]$deviceChanges.ToArray()
    $audit=[ordered]@{CapturedAt=(Get-Date).ToString('o');TargetVM=$secondaryVm.Name;ChangeVersion=$spec.ChangeVersion;Operation='Remove virtual devices only';FileOperation='None';Devices=@($contract.Devices|ForEach-Object{[ordered]@{DeviceKey=$_.DeviceKey;DeviceLabel=$_.DeviceLabel;ScsiNode=$_.VirtualDeviceNode;VmdkPath=$_.BackingFileName}})}
    $requestArtifact=Save-DebugArtifact 'DETACH' 'REQUEST' $audit
    Write-Log "Submitting one read-safe VM reconfiguration task to detach $($deviceChanges.Count) Secondary shared-disk device(s). Request=$requestArtifact" WARN
    $taskRef=$secondaryView.ReconfigVM_Task($spec)
    $taskView=Get-View -Server $script:VIServer -Id $taskRef -ErrorAction Stop
    while($taskView.Info.State -in @('queued','running')){Start-Sleep -Seconds 1;$taskView.UpdateViewData('Info.State','Info.Error','Info.Result')}
    if($taskView.Info.State -ne 'success'){$message=if($taskView.Info.Error){$taskView.Info.Error.LocalizedMessage}else{"Task state: $($taskView.Info.State)"};throw "Secondary detach task failed: $message"}
    $script:AppliedChanges=@($contract.Devices|ForEach-Object{[pscustomobject][ordered]@{AppliedAt=(Get-Date).ToString('o');VMName=$secondaryVm.Name;DeviceKey=$_.DeviceKey;DeviceLabel=$_.DeviceLabel;ScsiNode=$_.VirtualDeviceNode;VmdkPath=$_.BackingFileName;Operation='Detached virtual device';FileOperation='None';TaskId=[string]$taskRef.Value}})
    $script:AppliedChanges|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $script:RunDir 'AppliedChanges.json') -Encoding utf8BOM
    $script:DetachCompleted=$true;$script:DetachPreviewCurrent=$false
    Write-Log "Secondary detach task completed successfully. Devices=$($script:AppliedChanges.Count); VMDK files deleted=0." PASS
    $null=Test-PostChangeConfiguration -Manifest $manifest
    Update-UiState
}
function Test-PostChangeConfiguration {
    param($Manifest=(Get-ManifestAndVerifyIntegrity))
    $findings=[Collections.Generic.List[object]]::new()
    $primary=Resolve-ExactVm ([string]$Manifest.ClusterPair.PrimaryVM.VMName) 'Primary'
    $secondary=Resolve-ExactVm ([string]$Manifest.ClusterPair.SecondaryVM.VMName) 'Secondary'
    $p=Get-VmConfiguration $primary Primary;$s=Get-VmConfiguration $secondary Secondary
    if($p.VM.PowerState -ne 'poweredOff'){Add-Finding $findings 'BLOCK' 'PowerState' $p.VM.VMName 'Primary VM is not powered off.'}
    if($s.VM.PowerState -ne 'poweredOff'){Add-Finding $findings 'BLOCK' 'PowerState' $s.VM.VMName 'Secondary VM is not powered off.'}
    foreach($original in @($Manifest.Disks|Where-Object Role -eq 'Primary')){
        $match=@($p.Disks|Where-Object{[int]$_.DeviceKey -eq [int]$original.DeviceKey -and $_.CanonicalBackingPath -eq [string]$original.CanonicalBackingPath})
        if($match.Count -ne 1){Add-Finding $findings 'BLOCK' 'Primary' $original.DeviceLabel 'Primary disk is missing or changed.';continue}
        if([bool]$original.OriginallyMultiWriter -and $match[0].Sharing -ne 'Multi-writer'){Add-Finding $findings 'BLOCK' 'Primary' $original.DeviceLabel 'Primary shared disk is no longer Multi-writer.'}
        if($match[0].VirtualDeviceNode -ne [string]$original.VirtualDeviceNode){Add-Finding $findings 'BLOCK' 'Primary' $original.DeviceLabel 'Primary SCSI node changed.'}
    }
    foreach($original in @($Manifest.Disks|Where-Object{ $_.Role -eq 'Secondary' -and -not [bool]$_.OriginallyMultiWriter })){
        $match=@($s.Disks|Where-Object{[int]$_.DeviceKey -eq [int]$original.DeviceKey -and $_.CanonicalBackingPath -eq [string]$original.CanonicalBackingPath})
        if($match.Count -ne 1){Add-Finding $findings 'BLOCK' 'SecondaryPrivate' $original.DeviceLabel 'Secondary private disk is missing or changed.';continue}
        if($match[0].VirtualDeviceNode -ne [string]$original.VirtualDeviceNode){Add-Finding $findings 'BLOCK' 'SecondaryPrivate' $original.DeviceLabel 'Secondary private-disk SCSI node changed.'}
    }
    foreach($planned in @($Manifest.PlannedChanges)){
        $remaining=@($s.Disks|Where-Object{[int]$_.DeviceKey -eq [int]$planned.DeviceKey -or $_.CanonicalBackingPath -eq (ConvertTo-CanonicalVmdkPath ([string]$planned.VmdkPath))})
        if($remaining.Count -gt 0){Add-Finding $findings 'BLOCK' 'SecondaryShared' $planned.DeviceLabel 'Planned shared disk remains attached to the Secondary VM.'}
        $primaryBacking=@($p.Disks|Where-Object{$_.CanonicalBackingPath -eq (ConvertTo-CanonicalVmdkPath ([string]$planned.VmdkPath)) -and $_.Sharing -eq 'Multi-writer'})
        if($primaryBacking.Count -ne 1){Add-Finding $findings 'BLOCK' 'PrimaryBacking' $planned.DeviceLabel 'Detached backing is not present exactly once as a Primary multi-writer disk.'}
    }
    $blocks=@($findings|Where-Object Severity -eq 'BLOCK').Count
    $script:PostChangeValidation=[pscustomobject][ordered]@{ValidatedAt=(Get-Date).ToString('o');Status=if($blocks){'Blocked'}else{'Pass'};BlockingCount=$blocks;FindingCount=$findings.Count;PrimaryVM=$p.VM.VMName;SecondaryVM=$s.VM.VMName;PrimaryDiskCount=$p.Disks.Count;SecondaryDiskCount=$s.Disks.Count;Findings=@($findings)}
    $script:PostChangeValidation|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $script:RunDir 'PostChange-Validation.json') -Encoding utf8BOM
    $script:gridPost.ItemsSource=@($findings)
    if($blocks){$script:lblDetachStatus.Text="POST-CHANGE BLOCKED ($blocks) - DO NOT MIGRATE";$script:lblDetachStatus.Foreground='Tomato';Write-Log "Post-change validation failed with $blocks blocking finding(s). DO NOT BEGIN MIGRATION." ERROR}
    else{$script:lblDetachStatus.Text='PASS: READY FOR COLD MIGRATION';$script:lblDetachStatus.Foreground='LightGreen';Write-Log 'Post-change validation passed. Primary unchanged; Secondary shared disks detached; VMDK files preserved. READY FOR COLD MIGRATION.' PASS}
    return ($blocks -eq 0)
}
# endregion
# region UI helpers
function Clear-InventoryGrids {$script:gridVMs.ItemsSource=$null;$script:gridControllers.ItemsSource=$null;$script:gridDisks.ItemsSource=$null;$script:gridCorrelations.ItemsSource=$null;$script:gridFindings.ItemsSource=$null}
function Bind-DiscoveryGrids {$script:gridVMs.ItemsSource=@($script:Discovery.VMs);$script:gridControllers.ItemsSource=@($script:Discovery.Controllers);$script:gridDisks.ItemsSource=@($script:Discovery.Disks);$script:gridCorrelations.ItemsSource=@($script:Discovery.Correlations);$script:gridFindings.ItemsSource=$null;$script:lblValidation.Text='Not validated';$script:lblValidation.Foreground='#76C7D8';$script:lblManifest.Text='Not exported';$script:lblManifest.Foreground='#76C7D8'}
function Update-Prerequisites {
    $script:lblPS.Text=$PSVersionTable.PSVersion.ToString();$script:lblPS.Foreground='LightGreen'
    $script:lblSTA.Text=[Threading.Thread]::CurrentThread.ApartmentState.ToString();$script:lblSTA.Foreground=if([Threading.Thread]::CurrentThread.ApartmentState -eq 'STA'){'LightGreen'}else{'Tomato'}
    $found=Test-HasModule 'VCF.PowerCLI';$script:lblPowerCLI.Text=if($found){'Found'}else{'Missing'};$script:lblPowerCLI.Foreground=if($found){'LightGreen'}else{'Tomato'}
    $script:lblOutput.Text=if($script:RunDir){$script:RunDir}else{'Not initialized'};$script:lblOutput.Foreground=if($script:RunDir){'LightGreen'}else{'#76C7D8'}
}
function Update-UiState {
    $connected=[bool]$script:VIServer;$discovered=[bool]$script:Discovery;$validated=[bool]$script:Validation
    $script:btnDiscover.IsEnabled=$connected;$script:btnRefresh.IsEnabled=$connected -and $discovered;$script:btnValidate.IsEnabled=$discovered;$script:btnExport.IsEnabled=$validated;$script:btnOpenRun.IsEnabled=[bool]$script:RunDir
    if($script:btnPreviewDetach){$script:btnPreviewDetach.IsEnabled=($validated -and $script:Validation.Status -eq 'Pass' -and [bool]$script:ManifestPath -and -not$script:DetachCompleted)}
    if($script:btnExecuteDetach){$script:btnExecuteDetach.IsEnabled=($validated -and $script:Validation.Status -eq 'Pass' -and [bool]$script:ManifestPath -and -not$script:DetachCompleted)}
    if($script:btnValidatePost){$script:btnValidatePost.IsEnabled=[bool]$script:DetachCompleted}
}
# endregion

# region XAML
$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="vSphere Shared-Disk Cluster Migration Assistant" Height="900" Width="1560" MinHeight="760" MinWidth="1200" WindowStartupLocation="CenterScreen" Background="#071015" Foreground="#E6E6E6" FontFamily="Segoe UI">
<Window.Resources>
<Style TargetType="Button">
  <Setter Property="Background" Value="#2B3740"/>
  <Setter Property="Foreground" Value="#F1F4F6"/>
  <Setter Property="BorderBrush" Value="#5F7482"/>
  <Setter Property="Padding" Value="9,4"/>
  <Setter Property="Margin" Value="4"/>
  <Setter Property="MinHeight" Value="29"/>
  <Style.Triggers>
    <Trigger Property="IsMouseOver" Value="True">
      <Setter Property="Background" Value="#3A4E59"/>
      <Setter Property="BorderBrush" Value="#76C7D8"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
    </Trigger>
    <Trigger Property="IsEnabled" Value="False">
      <Setter Property="Background" Value="#182229"/>
      <Setter Property="Foreground" Value="#81919A"/>
      <Setter Property="BorderBrush" Value="#3C4B53"/>
      <Setter Property="Opacity" Value="1"/>
    </Trigger>
  </Style.Triggers>
</Style>
<Style TargetType="TextBlock"><Setter Property="Foreground" Value="#E6E6E6"/><Setter Property="Margin" Value="3"/></Style>
<Style TargetType="TextBox"><Setter Property="Background" Value="#071015"/><Setter Property="Foreground" Value="#E6E6E6"/><Setter Property="BorderBrush" Value="#607D8B"/><Setter Property="Padding" Value="4"/></Style>
<Style TargetType="PasswordBox"><Setter Property="Background" Value="#071015"/><Setter Property="Foreground" Value="#E6E6E6"/><Setter Property="BorderBrush" Value="#607D8B"/><Setter Property="Padding" Value="4"/></Style>
<Style TargetType="GroupBox"><Setter Property="Foreground" Value="#E6E6E6"/><Setter Property="Background" Value="#0D1B22"/><Setter Property="BorderBrush" Value="#2B3740"/><Setter Property="Margin" Value="5"/><Setter Property="Padding" Value="7"/></Style>
<Style TargetType="TabControl"><Setter Property="Background" Value="#071015"/><Setter Property="BorderBrush" Value="#5B7280"/></Style>
<Style TargetType="TabItem">
  <Setter Property="Background" Value="#25343D"/>
  <Setter Property="Foreground" Value="#F1F4F6"/>
  <Setter Property="BorderBrush" Value="#5B7280"/>
  <Setter Property="Padding" Value="11,6"/>
  <Setter Property="Margin" Value="2,0,2,0"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="TabItem">
        <Border x:Name="TabBorder"
                Background="{TemplateBinding Background}"
                BorderBrush="{TemplateBinding BorderBrush}"
                BorderThickness="1,1,1,0"
                CornerRadius="3,3,0,0"
                Padding="{TemplateBinding Padding}">
          <ContentPresenter x:Name="TabContent"
                            ContentSource="Header"
                            HorizontalAlignment="Center"
                            VerticalAlignment="Center"
                            TextElement.Foreground="{TemplateBinding Foreground}"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsSelected" Value="True">
            <Setter TargetName="TabBorder" Property="Background" Value="#17313D"/>
            <Setter TargetName="TabBorder" Property="BorderBrush" Value="#76C7D8"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
          </Trigger>
          <Trigger Property="IsMouseOver" Value="True">
            <Setter TargetName="TabBorder" Property="Background" Value="#3A4E59"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
          </Trigger>
          <Trigger Property="IsEnabled" Value="False">
            <Setter TargetName="TabBorder" Property="Background" Value="#182229"/>
            <Setter Property="Foreground" Value="#81919A"/>
            <Setter Property="Opacity" Value="1"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="DataGrid"><Setter Property="Background" Value="#071015"/><Setter Property="Foreground" Value="#E6E6E6"/><Setter Property="RowBackground" Value="#071015"/><Setter Property="AlternatingRowBackground" Value="#0D1B22"/><Setter Property="GridLinesVisibility" Value="All"/><Setter Property="HorizontalGridLinesBrush" Value="#607D8B"/><Setter Property="VerticalGridLinesBrush" Value="#607D8B"/><Setter Property="BorderBrush" Value="#607D8B"/><Setter Property="RowHeaderWidth" Value="0"/><Setter Property="CanUserAddRows" Value="False"/><Setter Property="IsReadOnly" Value="True"/><Setter Property="VerticalScrollBarVisibility" Value="Auto"/><Setter Property="HorizontalScrollBarVisibility" Value="Auto"/><Setter Property="EnableRowVirtualization" Value="True"/><Setter Property="EnableColumnVirtualization" Value="True"/></Style>
<Style TargetType="DataGridColumnHeader"><Setter Property="Background" Value="#2B3740"/><Setter Property="Foreground" Value="#F1F4F6"/><Setter Property="FontWeight" Value="SemiBold"/></Style>
</Window.Resources>
<Grid Margin="10"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="165"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<Grid><Grid.ColumnDefinitions><ColumnDefinition Width="470"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
<GroupBox Header="Prerequisites"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><WrapPanel><TextBlock Text="PowerShell:"/><TextBlock x:Name="lblPS"/><TextBlock Text="STA:" Margin="18,3,3,3"/><TextBlock x:Name="lblSTA"/><TextBlock Text="VCF.PowerCLI:" Margin="18,3,3,3"/><TextBlock x:Name="lblPowerCLI"/></WrapPanel><WrapPanel Grid.Row="1"><TextBlock Text="Output:"/><TextBlock x:Name="lblOutput" Text="Not initialized" TextTrimming="CharacterEllipsis" Width="365"/></WrapPanel><WrapPanel Grid.Row="2" HorizontalAlignment="Center"><Button x:Name="btnRecheck" Content="Recheck"/><Button x:Name="btnInstall" Content="Install VCF.PowerCLI"/><Button x:Name="btnBrowse" Content="Output Folder"/></WrapPanel></Grid></GroupBox>
<GroupBox Grid.Column="1" Header="Source vCenter Connection"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="120"/><ColumnDefinition Width="*"/><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><Grid.RowDefinitions><RowDefinition Height="34"/><RowDefinition Height="34"/></Grid.RowDefinitions><TextBlock Text="Source vCenter" VerticalAlignment="Center"/><TextBox x:Name="txtVCenter" Grid.Column="1"/><TextBlock Text="Username" Grid.Column="2" VerticalAlignment="Center"/><TextBox x:Name="txtUsername" Grid.Column="3"/><TextBlock Text="Password" Grid.Column="4" VerticalAlignment="Center"/><PasswordBox x:Name="txtPassword" Grid.Column="5"/><StackPanel Grid.Row="1" Grid.ColumnSpan="2" Orientation="Horizontal"><TextBlock Text="Status:"/><TextBlock x:Name="lblConnection" Text="Not connected" Foreground="#76C7D8"/></StackPanel><WrapPanel Grid.Row="1" Grid.Column="2" Grid.ColumnSpan="4" HorizontalAlignment="Right"><Button x:Name="btnConnect" Content="Connect"/><Button x:Name="btnDisconnect" Content="Disconnect"/><Button x:Name="btnSaveProfile" Content="Save Profile"/><Button x:Name="btnLoadProfile" Content="Load Profile"/></WrapPanel></Grid></GroupBox>
</Grid>
<TabControl Grid.Row="1" Margin="0,6,0,0">
<TabItem Header="1. VM Pair Discovery"><Grid Margin="8"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><GroupBox Header="Explicit Cluster Roles"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="125"/><ColumnDefinition Width="300"/><ColumnDefinition Width="145"/><ColumnDefinition Width="300"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="Primary / Active VM" VerticalAlignment="Center"/><TextBox x:Name="txtPrimaryVM" Grid.Column="1"/><TextBlock Text="Secondary / Standby VM" Grid.Column="2" VerticalAlignment="Center"/><TextBox x:Name="txtSecondaryVM" Grid.Column="3"/><WrapPanel Grid.Column="4" HorizontalAlignment="Right"><Button x:Name="btnDiscover" Content="Discover VM Pair" IsEnabled="False"/><Button x:Name="btnRefresh" Content="Refresh Live Inventory" IsEnabled="False"/></WrapPanel></Grid></GroupBox><DataGrid x:Name="gridVMs" Grid.Row="1" AutoGenerateColumns="True"/></Grid></TabItem>
<TabItem Header="2. Controllers"><DataGrid x:Name="gridControllers" Margin="8" AutoGenerateColumns="True"/></TabItem>
<TabItem Header="3. Complete Disk Inventory"><DataGrid x:Name="gridDisks" Margin="8" AutoGenerateColumns="True"><DataGrid.RowStyle><Style TargetType="DataGridRow"><Style.Triggers><DataTrigger Binding="{Binding Validation}" Value="BLOCK"><Setter Property="Background" Value="#8B1E1E"/></DataTrigger><DataTrigger Binding="{Binding OriginallyMultiWriter}" Value="True"><Setter Property="Background" Value="#31265C"/></DataTrigger></Style.Triggers></Style></DataGrid.RowStyle></DataGrid></TabItem>
<TabItem Header="4. Shared-Disk Correlation"><DataGrid x:Name="gridCorrelations" Margin="8" AutoGenerateColumns="True"><DataGrid.RowStyle><Style TargetType="DataGridRow"><Style.Triggers><DataTrigger Binding="{Binding Status}" Value="ExactBackingMatch"><Setter Property="Background" Value="#153D2E"/></DataTrigger><DataTrigger Binding="{Binding Status}" Value="BackingUuidMatch"><Setter Property="Background" Value="#153D2E"/></DataTrigger><DataTrigger Binding="{Binding Status}" Value="Unmatched"><Setter Property="Background" Value="#8B1E1E"/></DataTrigger><DataTrigger Binding="{Binding Status}" Value="Ambiguous"><Setter Property="Background" Value="#8B1E1E"/></DataTrigger></Style.Triggers></Style></DataGrid.RowStyle></DataGrid></TabItem>
<TabItem Header="5. Validation and Manifest"><Grid Margin="8"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><GroupBox Header="Milestone 1 Read-Only Actions"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="220"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><Button x:Name="btnValidate" Content="Validate Source Configuration" IsEnabled="False"/><StackPanel Grid.Column="1" Orientation="Horizontal"><TextBlock Text="Validation:" FontWeight="SemiBold"/><TextBlock x:Name="lblValidation" Text="Not validated" Foreground="#76C7D8"/></StackPanel><Button x:Name="btnExport" Grid.Column="2" Content="Export Manifest and CSV Files" IsEnabled="False"/><StackPanel Grid.Column="3" Orientation="Horizontal"><TextBlock Text="Manifest:" FontWeight="SemiBold"/><TextBlock x:Name="lblManifest" Text="Not exported" Foreground="#76C7D8" TextTrimming="CharacterEllipsis"/></StackPanel><Button x:Name="btnOpenRun" Grid.Column="4" Content="Open Run Folder" IsEnabled="False"/></Grid></GroupBox><DataGrid x:Name="gridFindings" Grid.Row="1" AutoGenerateColumns="True"><DataGrid.RowStyle><Style TargetType="DataGridRow"><Style.Triggers><DataTrigger Binding="{Binding Severity}" Value="BLOCK"><Setter Property="Background" Value="#8B1E1E"/></DataTrigger><DataTrigger Binding="{Binding Severity}" Value="WARN"><Setter Property="Background" Value="#8A6500"/></DataTrigger></Style.Triggers></Style></DataGrid.RowStyle></DataGrid></Grid></TabItem>
<TabItem Header="6. Controlled Detach"><Grid Margin="8"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
<GroupBox Header="Secondary Shared-Disk Detach"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><Button x:Name="btnPreviewDetach" Content="Preview Detach Contract" IsEnabled="False"/><Button x:Name="btnExecuteDetach" Grid.Column="1" Content="Execute Controlled Detach" IsEnabled="False" Background="#6B2020" Foreground="#FFFFFF"/><StackPanel Grid.Column="2" Orientation="Horizontal"><TextBlock Text="Status:" FontWeight="SemiBold"/><TextBlock x:Name="lblDetachStatus" Text="Not prepared" Foreground="#76C7D8"/></StackPanel><Button x:Name="btnValidatePost" Grid.Column="3" Content="Validate Post-Change" IsEnabled="False"/></Grid></GroupBox>
<DataGrid x:Name="gridDetach" Grid.Row="1" AutoGenerateColumns="True"/>
<TextBlock Grid.Row="2" Text="Post-change findings. An empty grid with PASS status indicates that the Primary remained unchanged, Secondary private disks remained attached, and all planned Secondary shared disks were removed without deleting backing files." Foreground="#76C7D8" TextWrapping="Wrap" Margin="6"/>
<DataGrid x:Name="gridPost" Grid.Row="3" AutoGenerateColumns="True"/>
</Grid></TabItem>
</TabControl>
<GroupBox Grid.Row="2" Header="Operational Log"><TextBox x:Name="txtLog" IsReadOnly="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12"/></GroupBox>
<Grid Grid.Row="3"><Grid.ColumnDefinitions><ColumnDefinition Width="110"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="Output Base" VerticalAlignment="Center"/><TextBox x:Name="txtOutputPath" Grid.Column="1"/><WrapPanel Grid.Column="2"><Button x:Name="btnApplyOutput" Content="Apply Output Path"/><Button x:Name="btnClose" Content="Close"/></WrapPanel></Grid>
</Grid></Window>
'@
$script:Window=[Windows.Markup.XamlReader]::Parse($xaml)
$controlNames=@('lblPS','lblSTA','lblPowerCLI','lblOutput','btnRecheck','btnInstall','btnBrowse','txtVCenter','txtUsername','txtPassword','lblConnection','btnConnect','btnDisconnect','btnSaveProfile','btnLoadProfile','txtPrimaryVM','txtSecondaryVM','btnDiscover','btnRefresh','gridVMs','gridControllers','gridDisks','gridCorrelations','btnValidate','lblValidation','btnExport','lblManifest','btnOpenRun','gridFindings','txtLog','txtOutputPath','btnApplyOutput','btnClose','btnPreviewDetach','btnExecuteDetach','lblDetachStatus','btnValidatePost','gridDetach','gridPost')
foreach($n in $controlNames){Set-Variable -Scope Script -Name $n -Value $script:Window.FindName($n)}
# endregion

# region Profiles and events
function Save-ConnectionProfile {
    $d=[Microsoft.Win32.SaveFileDialog]::new();$d.Filter='JSON files (*.json)|*.json';$d.InitialDirectory=$script:OutputBase;$d.FileName='vSphere-SharedDisk-Connection-Profile.json';if(-not$d.ShowDialog()){return}
    [ordered]@{SchemaVersion='1.0';SourceVCenter=$script:txtVCenter.Text.Trim();SourceUsername=$script:txtUsername.Text.Trim();OutputPath=$script:OutputBase}|ConvertTo-Json|Set-Content -LiteralPath $d.FileName -Encoding utf8BOM;Write-Log "Password-free connection profile saved: $($d.FileName)" PASS
}
function Load-ConnectionProfile {
    $d=[Microsoft.Win32.OpenFileDialog]::new();$d.Filter='JSON files (*.json)|*.json';if(-not$d.ShowDialog()){return};$p=Get-Content -LiteralPath $d.FileName -Raw|ConvertFrom-Json;$script:txtVCenter.Text=[string]$p.SourceVCenter;$script:txtUsername.Text=[string]$p.SourceUsername;if($p.OutputPath){Initialize-RunFolder ([string]$p.OutputPath);Start-AppTranscript};Write-Log "Connection profile loaded: $($d.FileName). Password was not loaded." PASS
}
Initialize-RunFolder $script:OutputBase
Start-AppTranscript
$script:txtOutputPath.Text=$script:OutputBase
$script:btnRecheck.Add_Click({Update-Prerequisites})
$script:btnInstall.Add_Click({$null=Ensure-Module 'VCF.PowerCLI';Update-Prerequisites})
$script:btnBrowse.Add_Click({try{Select-OutputFolder}catch{Write-ExceptionDiagnostic $_ 'OUTPUT-FOLDER'|Out-Null;Show-ThemedNotice 'Output Folder' $_.Exception.Message Error}})
$script:btnApplyOutput.Add_Click({try{Initialize-RunFolder $script:txtOutputPath.Text;Start-AppTranscript;Update-Prerequisites;Write-Log "Output path applied: $($script:RunDir)" PASS}catch{Write-ExceptionDiagnostic $_ 'OUTPUT-PATH'|Out-Null;Show-ThemedNotice 'Output Path' $_.Exception.Message Error}})
$script:btnConnect.Add_Click({try{$script:btnConnect.IsEnabled=$false;Connect-SourceVCenter}catch{Write-ExceptionDiagnostic $_ 'VCENTER-CONNECT'|Out-Null;Show-ThemedNotice 'vCenter Connection Failed' $_.Exception.Message Error}finally{$script:btnConnect.IsEnabled=$true;Update-Prerequisites}})
$script:btnDisconnect.Add_Click({Disconnect-SourceVCenter})
$script:btnSaveProfile.Add_Click({try{Save-ConnectionProfile}catch{Write-ExceptionDiagnostic $_ 'SAVE-PROFILE'|Out-Null;Show-ThemedNotice 'Save Profile' $_.Exception.Message Error}})
$script:btnLoadProfile.Add_Click({try{Load-ConnectionProfile;Update-Prerequisites}catch{Write-ExceptionDiagnostic $_ 'LOAD-PROFILE'|Out-Null;Show-ThemedNotice 'Load Profile' $_.Exception.Message Error}})
$script:btnDiscover.Add_Click({try{$script:Window.Cursor='Wait';Discover-VmPair}catch{Write-ExceptionDiagnostic $_ 'DISCOVERY'|Out-Null;Show-ThemedNotice 'VM Pair Discovery Failed' $_.Exception.Message Error}finally{$script:Window.Cursor=$null}})
$script:btnRefresh.Add_Click({try{$script:Window.Cursor='Wait';Discover-VmPair}catch{Write-ExceptionDiagnostic $_ 'REFRESH'|Out-Null;Show-ThemedNotice 'Inventory Refresh Failed' $_.Exception.Message Error}finally{$script:Window.Cursor=$null}})
$script:btnValidate.Add_Click({try{$null=Test-SourceConfiguration}catch{Write-ExceptionDiagnostic $_ 'VALIDATION'|Out-Null;Show-ThemedNotice 'Validation Failed' $_.Exception.Message Error}})
$script:btnExport.Add_Click({try{Export-ManifestAndInventory}catch{Write-ExceptionDiagnostic $_ 'EXPORT'|Out-Null;Show-ThemedNotice 'Manifest Export Failed' $_.Exception.Message Error}})
$script:btnOpenRun.Add_Click({if($script:RunDir -and (Test-Path -LiteralPath $script:RunDir)){Invoke-Item $script:RunDir}})
$script:btnPreviewDetach.Add_Click({
    try{
        $manifest=Get-ManifestAndVerifyIntegrity
        $contract=Test-LiveDetachContract $manifest
        $script:gridDetach.ItemsSource=@($contract.Devices)
        $script:DetachPreviewCurrent=$true
        $script:lblDetachStatus.Text="Preview ready: $($contract.Devices.Count) device(s); Primary changes=0; File deletions=0"
        $script:lblDetachStatus.Foreground='#F2C94C'
        Write-Log "Detach preview passed for $($contract.Devices.Count) Secondary multi-writer device(s). Primary changes=0; VMDK deletions=0." PASS
        Update-UiState
    }catch{Write-ExceptionDiagnostic $_ 'DETACH-PREVIEW'|Out-Null;Show-ThemedNotice 'Detach Preview Failed' $_.Exception.Message Error}
})
$script:btnExecuteDetach.Add_Click({
    try{$script:btnExecuteDetach.IsEnabled=$false;$script:Window.Cursor='Wait';Invoke-SecondarySharedDiskDetach}
    catch{Write-ExceptionDiagnostic $_ 'DETACH-EXECUTION'|Out-Null;$script:lblDetachStatus.Text='FAILED - LIVE REVIEW REQUIRED';$script:lblDetachStatus.Foreground='Tomato';Show-ThemedNotice 'Controlled Detach Failed' $_.Exception.Message Error}
    finally{$script:Window.Cursor=$null;Update-UiState}
})
$script:btnValidatePost.Add_Click({try{$null=Test-PostChangeConfiguration}catch{Write-ExceptionDiagnostic $_ 'POST-CHANGE-VALIDATION'|Out-Null;Show-ThemedNotice 'Post-Change Validation Failed' $_.Exception.Message Error}})
$script:btnClose.Add_Click({$script:Window.Close()})
$script:Window.Add_Closing({try{$script:txtPassword.Clear()}catch{};try{Disconnect-SourceVCenter}catch{};try{Stop-AppTranscript}catch{}})

Update-Prerequisites;Update-UiState
Write-Log "$($script:AppName) $($script:Version) started. Milestone 2 controlled detach is enabled with checksum, drift, typed-confirmation, and post-change gates." PASS
Write-Log 'Milestone 2 can detach confirmed shared-disk devices from the Secondary VM only. FileOperation remains null; Primary, migration, power, snapshot, and backing-file deletion operations are not implemented.' PASS
$null=$script:Window.ShowDialog()
Stop-AppTranscript
# endregion







