function Remove-I2NimbleSnapshots {

<# 
    .SYNOPSIS 
        This scripts deletes vvol-snapcoll* snapshots on the specified Nimble array.
        It checks if the VM has an active vCenter snapshot, if it does the VM is skiped as not to delete active data. 
    .DESCRIPTION
        The script checks that the VM exists in the chosen vCenter and that there are no active snapshots on that VM in vCenter.
        The script then puts all vvol-snapcoll* snapshots for the VM in an offline state and deletes them. 
    .PARAMETER Nimble 
        Specify the Nimble array you want to run the script against.
    .PARAMETER vCenter
        Specify the vCenter.
    .PARAMETER LogLocation
        Specify location for the log file.
    .PARAMETER Confirm
        Enable this if you want to confirm delete operations for each VM. 
    .PARAMETER Credential
        Use powershell credential object to authenticate towards Nimble array. 
    .NOTES
        Author: Jørgen Søby
        Created: 01.04.2020
        Revised: 14.09.2020
        Changelog:
            01042020: First version created. /Jørgen Søby
            05042020: Added logging functionality and revised VM name gathering. 
            04052020: Added functionality for deleting replicated snapshots. 
            05052020: Added snapshot counter and confirm switch for deleting replicated snapshots as well. 
            25082020: Improved VM Snapshots gathering. Moved from matching VM name with Nimble volume name to using VVOL config UUID.
            14092020: The script now gathers all VM volumes, not just the config VVOL. 
            14092020: Improved logging and error handling. 
#>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$vCenter,

        [Parameter(Mandatory=$true)]
        [string]$NimbleArray,

        [Parameter(Mandatory=$true)]
        [string]$LogPath,

        [Parameter(Mandatory=$false)]
        [switch]$Confirm,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential
    )

    # Connecting to vCenter and the Nimble array
    if($Credential){
        Connect-NsGroup -Group $NimbleArray -IgnoreServerCertificate -Credential $Credential
        Connect-VIServer -Server $vCenter -Credential $Credential
    }
    else{
        Connect-NsGroup -Group $NimbleArray -IgnoreServerCertificate -Credential $(Get-Credential)
        Connect-VIServer $vCenter
    }

    # Get the Nimble group name. 
    $NimbleGP = (Get-NSGroup).name

    # Gathering datastores from vCenter that resides on the array.
    $datastores = Get-Datastore | Where-Object {$_.ExtensionData.Info.VVOLDS.storageArray.Name -like $NimbleGP}

    # If datastores are found, gather all VM's residing on those datastores. 
    if($datastores){
        $vms = $datastores | Get-VM
    }
    else{
        Write-Warning "No datastores for this Nimble array was found in vCenter $vCenter."
        break
    }
    
    # Using vmLoop label to continue with outermost loop in nested loops. 
    :vmLoop foreach($vm in $vms){

        Write-Log -Path $LogPath -Component $NimbleArray -Type "Info" -Message "Performing checks and snapshot deletion for VM $($vm.name)."
        Write-Host "Performing checks and snapshot deletion for VM $($vm.name)" -ForegroundColor Green

        # VM's that are spread between multiple VVOL datastores have multiple config VVOL's. This is not supported by this script. 
        if($vm.DatastoreIdList.Count -gt 1){
            Write-Warning "The VM$($vm.name) is located on more than one datastore. Skipping VM due to multiple config VVOLs."
            Write-Log -Path $LogPath -Component $NimbleArray -Type "Info" -Message "The VM $($vm.name) is located on more than one datastore. Skipping VM due to multiple config VVOLs."
            continue
        }
        
        try{
            Write-Log -Path $LogPath -Component $NimbleArray -Type "Info" -Message "Gathering volume UUIDs for VM $($vm.name)."
            Write-Host "Gathering volume UUIDs for VM $($vm.name)." -ForegroundColor Green
            # Array to store VVOL volume UUIDs. 
            $vmVolumeUUIDs = @()
            # Gather the volume UUID for the VM's config VVOL and adding them to the array.
            $vmVolumeUUIDs += $vm.ExtensionData.Config.VmStorageObjectId
            # Gather volume UUID for the VM's harddisks and adding them to the array.
            $vmVolumeUUIDs += $vm | Get-Harddisk | Select-Object -ExpandProperty ExtensionData | Select-Object -ExpandProperty backing | Select-Object -ExpandProperty BackingObjectId
        }
        catch{
            Write-Warning "Unable to gather volume UUIDs for VM $($vm.name). Checking next VM."
            Write-Log -Path $LogPath -Component $NimbleArray -Type "Error" -Message "Unable to gather volume UUIDs for VM $($vm.name). Checking next VM."
            continue
        }

        if(!$vmVolumeUUIDs){
            Write-Warning "Unable to determine VM volume UUIDs. Skipping VM $($vm.name)"
            Write-Log -Path $LogPath -Component $NimbleArray -Type "Error" -Message "Unable to determine VM volume UUIDs. Skipping VM $($vm.name)"
            continue
        }
        
        # Using volumeLoop label to continue with outermost loop in nested loops. 
        :volumeLoop foreach($vmVolumeUUID in $vmVolumeUUIDs){

            Try{
                $NSVolume = Get-NSVolume -app_uuid $vmVolumeUUID -ErrorAction stop
            }
            Catch{
                Write-Warning "Unable to get Nimble volume for UUID $vmVolumeUUID. Skipping VM $($vm.name)"
                Write-Log -Path $LogPath -Component $NimbleArray -Type "Error" -Message "Unable to get Nimble volume for UUID $vmVolumeUUID. Skipping VM $($vm.name)"
                continue vmLoop
            }

            
            # Gathering nimble vCenter snapshots for the volume.
            try{
                $VMNimbleSnaps = Get-NSSnapshot -vol_id $NSVolume.id | Where-Object {$_.name -like "vvol-snapcoll*"}
            }
            catch{
                Write-Warning "Unable to gather snapshots for volume $($NSVolume.name). Checking next volume."
                Write-Log -Path $LogPath -Component $NimbleArray -Type "Error" -Message "Unable to gather snapshots for volume $($NSVolume.name). Checking next volume."
                continue
            }
            

            # Checking if any snapshots were found. If not, we will continue with the next VM volume. 
            if(!$VMNimbleSnaps){
                Write-Log -Path $LogPath -Component $NimbleArray -Type "Info" -Message "No nimble snapshots found for volume $($NSVolume.name). Checking next volume."
                Write-Host "No nimble snapshots found for volume $($NSVolume.name) for $($vm.name). Checking next volume." -ForegroundColor Green
                continue
            }
    
            # Checks if the VM has any active snapshots in vCenter. If the checks fail the VM will be skipped as we can not safely delete the snapshots. 
            Try {
                Write-Log -Path $LogPath -Component $NimbleArray -Type "Info" -Message "Checking if $($vm.name) has an active vCenter snapshot"
                $snapshot = $vm | Get-Snapshot -ErrorAction Stop
            }
            # If snapshot status cannot be gathered, we will continue with the next VM.
            Catch {
                Write-Log -Path $LogPath -Component $NimbleArray -Type "Error" -Message "Skipping $($vm.name): unable to gather vCenter snapshot status"
                Write-Warning "SKIPPING $($vm.name) : unable to gather vCenter snapshot status"
                continue vmLoop
            }
    
            # If an active vCenter snapshot is found, we will continue with the next VM.
            if($snapshot){
                Write-Log -Path $LogPath -Component $NimbleArray -Type "Warning" -Message "Skipping VM $($vm.name): Active snapshot identified in vCenter"
                Write-Warning "SKIPPING $($vm.name) : Active snapshot identified in vCenter"
                continue vmLoop
            }
    
            else{
                Write-Host "INFO: No vCenter snapshot found for $($vm.name). Deleting snapshots for volume $($NSVolume.name)." -ForegroundColor Green
                Write-Log -Path $LogPath -Component $NimbleArray -Type "Info" -Message "No vCenter snapshot found for $($vm.name). Deleting snapshots for volume $($NSVolume.name)."
                #If the confirm switch is true the script will output the snapshots to be deleted and ask for a confirmation. 
                if($Confirm){
                    $VMNimbleSnaps | Select-Object -Property name, vol_name | Format-Table -Autosize
                    $confirmation = Read-Host "Do you want to delete $($VMNimbleSnaps.Count) snapshots in volume $($NSVolume.name) for VM $($vm.name) ? [y/n]"
                    while($confirmation -ne "y")
                    {
                        if ($confirmation -eq 'n') { continue volumeLoop } # Using volumeLoop label to continue with the next volume in the $vmVolumeUUIDs loop.
                        $confirmation = Read-Host "Do you want to delete $($VMNimbleSnaps.Count) snapshots in volume $($NSVolume.name) for VM $($vm.name) ? [y/n]"
                    }
                }
    
                Write-Host "ACTION: Deleting $($VMNimbleSnaps.Count) snapshots in volume $($NSVolume.name) for VM $($vm.name)" -ForegroundColor Green
                Write-Log -Path $LogPath -Component $NimbleArray -Type "Info" -Message "Deleting $($VMNimbleSnaps.Count) in volume $($NSVolume.name) for VM $($vm.name)"
                
                # Iterating through the gathered snapshots, setting them offline and deleting them.
                foreach($VMNimbleSnap in $VMNimbleSnaps){
                    Write-Log -Path $LogPath -Component $NimbleArray -Type "Info" -Message "Starting delete operation for snapshot $($VMNimblesnap.name) in volume $($vmnimblesnap.vol_name) for $($vm.name)"
                    # Checking if snapshot is already offline. This is mostly the case on the replication partner. 
                    $SettOfflineCheck = Get-NSSnapshot -id $VMNimbleSnap.id | Where-Object {$_.online -eq $true}
                    # Attempting to set the VMNimbleSnap offline on the array by it's ID. 
                    if ($SettOfflineCheck) {
                        Try{
                            Write-Log -Path $LogPath -Component $NimbleArray -Type "Info" -Message "Attempting to set $($VMNimbleSnap.id) for $($vmnimblesnap.vol_name) offline"
                            Set-NSSnapshot -id $VMNimbleSnap.id -online $false
                            Write-Log -Path $LogPath -Component $NimbleArray -Type "Info" -Message "Sucsesfully set $($VMNimbleSnap.id) for $($vmnimblesnap.vol_name) offline"
                            Write-Host "ACTION: Sucsesfully set $($VMNimbleSnap.id) offline" -ForegroundColor Green
                        }
                            # Writing to log and continuing with the next snapshot if the code above fails. 
                        Catch{
                            Write-Log -Path $LogPath -Component $NimbleArray -Type "Error" -Message "Unable to set snapshot $($VMNimblesnap.name) with ID $($VMNimbleSnap.id) in volume $($VMNimblesnap.vol_name) offline."
                            Write-Warning "Unable to set snapshot $($VMNimblesnap.name) with ID $($VMNimbleSnap.id) in volume $($VMNimblesnap.vol_name) offline."
                            continue
                        }
                    }
                    else {
                        Write-Log -Path $LogPath -Component $NimbleArray -Type "Info" -Message "Nimble snapshot $($VMNimbleSnap.id) for $($vmnimblesnap.vol_name) is already offline"
                    }
    
                    # Attempting to delete the VMNimbleSnap on the array by it's ID. This will fail if the snapshot is busy with replication or if it is the latest snapshot for this volume. 
                    Try{
                        Write-Log -Path $LogPath -Component $NimbleArray -Type "Info" -Message "Attempting to delete $($VMNimbleSnap.id) for $($vmnimblesnap.vol_name)"
                        Remove-NSSnapshot -id $VMNimbleSnap.id
                        Write-Log -Path $LogPath -Component $NimbleArray -Type "Info" -Message "Sucsesfully deleted $($VMNimbleSnap.id) for $($vmnimblesnap.vol_name)"
                        $SnapshotCounter++
                        Write-Host "ACTION: Sucsesfully deleted snapshot $($VMNimbleSnap.id) for $($vmnimblesnap.vol_name)" -ForegroundColor Green
                    }
                    # Writing to log and continuing with the next snapshot if the code above fails. 
                    Catch{
                        Write-Log -Path $LogPath -Component $NimbleArray -Type "Error" -Message "Unable to delete snapshot $($VMNimblesnap.name) with ID $($VMNimbleSnap.id) in volume $($vmnimblesnap.vol_name)"
                        Write-Warning "Unable to delete snapshot $($VMNimblesnap.name) with ID $($VMNimbleSnap.id) in volume $($vmnimblesnap.vol_name)"
                        continue
                    }
                }
            } 
        }
    }
    Write-Log -Path $LogPath -Component $NimbleArray -Type "Info" -Message "Deleted $($SnapshotCounter) snapshots on array $($NimbleArray)"
    Write-Host "Deleted $SnapshotCounter snapshots on array $NimbleArray" -ForegroundColor Green
    Disconnect-VIServer -Confirm:$false
    Disconnect-NSGroup
}

function Get-I2NimbleSnapshotsCount {
    <# 
    .DESCRIPTION
        This function outputs the requested number of offline or online snapshots on the nimble array. 
    .PARAMETER NimbleArray 
        Specify the IP address or hostname of the Nimble array you want to gather writable or offline snapshots from.
    .PARAMETER WritableSnapshots
        Switch parameter to request the number of writable snapshots on the array.
    .PARAMETER OfflineSnapshots
        Switch parameter to request the number of offline snapshots on the array.
    .PARAMETER Credentiatl
        Pass trough a powershell credential object for auththentication.
    .NOTES
        Author: Jørgen Søby
        Created: 28.05.2020
        Revised: N/A
        Changelog:
#>

[CmdLetBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$NimbleArray,

        [Parameter(Mandatory=$false)]
        [switch]$WritableSnapshots,

        [Parameter(Mandatory=$false)]
        [switch]$OfflineSnapshots,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential
    )

    Try{
        if($Credential){
            Connect-NsGroup -Group $NimbleArray -IgnoreServerCertificate -Credential $Credential
        }
        else{
            Connect-NsGroup -Group $NimbleArray -IgnoreServerCertificate -Credential $(Get-Credential)
        }
    }
    Catch{
        Write-Error "Unable to connect to $NimbleArray"
        break
    }

    if(!$OfflineSnapshots -and !$WritableSnapshots){
        Write-Error Please specify the switch parameter OfflineSnapshots or WritableSnapshots.
        break
    }

    $SnapData = @() 

    $nimvols = Get-NSVolume

    if($WritableSnapshots){
        $WritableSnapshotsCounter = foreach ($nimvol in $($nimvols.name)){
            Get-NSSnapshot -writable $true -vol_name $nimvol
        }
        $SnapData += ([pscustomobject]@{Value='Writable Snapshots';Count=$WritableSnapshotsCounter.count})

    }

    if($OfflineSnapshots){
        $OfflineSnapshotsCounter = foreach ($nimvol in $nimvols.Name){
            Get-NSSnapshot -writable $false -vol_name $nimvol
        }
    $SnapData += ([pscustomobject]@{Value='Non-writable snapshots';Count=$OfflineSnapshotsCounter.count})
    }
    return $SnapData
    Disconnect-NSGroup
}
function Write-log {

    [CmdletBinding()]
    Param(
          [parameter(Mandatory=$true)]
          [String]$Path,

          [parameter(Mandatory=$true)]
          [String]$Message,

          [parameter(Mandatory=$true)]
          [String]$Component,

          [Parameter(Mandatory=$true)]
          [ValidateSet("Info", "Warning", "Error")]
          [String]$Type
    )

    switch ($Type) {
        "Info" { [int]$Type = 1 }
        "Warning" { [int]$Type = 2 }
        "Error" { [int]$Type = 3 }
    }

    # Create a log entry
    $Content = "<![LOG[$Message]LOG]!>" +`
        "<time=`"$(Get-Date -Format "HH:mm:ss.ffffff")`" " +`
        "date=`"$(Get-Date -Format "M-d-yyyy")`" " +`
        "component=`"$Component`" " +`
        "context=`"$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)`" " +`
        "type=`"$Type`" " +`
        "thread=`"$([Threading.Thread]::CurrentThread.ManagedThreadId)`" " +`
        "file=`"`">"

    # Write the line to the log file
    Add-Content -Path $Path -Value $Content
}

function Remove-I2NimbleReplicatedSnapshots {
    <#
        .DESCRIPTION 
            This function deletes all offline and replicated vvol-snapcoll snapshots on the Nimble array. 
        .PARAMETER NimbleArray
            Specify the IP address or hostname of the nimble array the you want to run the function against.
        .PARAMETER LogLocation
            Specify an existing .txt file to log the function operations. This is mandatory. 
        .PARAMETER Confirm 
            If this parameter is specified the function will output the number of snapshots to be deleted and ask for confirmation before performing the deletion. 
        .PARAMETER Credential
            Pass trough a powershell credential object to authenticate to the Nimble array.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$NimbleArray,

        [Parameter(Mandatory=$true)]
        [string]$LogPath,

        [Parameter(Mandatory=$false)]
        [switch]$Confirm,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential
    )
    
    # Connecting Nimble array
    if($Credential){
        Connect-NsGroup -Group $NimbleArray -IgnoreServerCertificate -Credential $Credential
    }
    else{
        Connect-NsGroup -Group $NimbleArray -IgnoreServerCertificate -Credential $(Get-Credential)
    }

    # Verify connection to Nimble array and outputing group name.
    Try{
        $NSGroupName = $(Get-NSGroup).Name
    }
    Catch{
        Write-Host "--- Could not verify connection to $NimbleArray. Exiting. ---" -ForegroundColor Red
        Write-Log -Path $LogPath -Component $NimbleArray -Type "Error" -Message "Could not verify connection to $NimbleArray. Exiting."
        break
    }

    if($NSGroupName){
        Write-Host "-- Sucsesfully connected to $NSGroupName ---" -ForegroundColor Green
        Write-Log -Path $LogPath -Component $NimbleArray -Type "Info" -Message "Sucsesfully connected to $NSGroupName."
    }


    #Gather all volumes on the Nimble array that are replicated and offline.
    $nimvols = Get-NSVolume | Where-Object {$_.offline_reason -eq "replica" -and  $_.vol_state -eq "offline"}

    #Iterating trough all volumes gathering snapshots with the name "vvol-snapcoll*" that are replicated and offline. 
    $ReplicatedVolumeSnapshots = @()
    foreach($nimvol in $nimvols){
        $ReplicatedVolumeSnapshots += Get-NSSnapshot -vol_id $nimvol.id | Where-Object {$_.name -like "vvol-snapcoll*" -and $_.is_replica -eq $True -and $_.online -eq $false}
    }
    Write-Host "Gathered $($ReplicatedVolumeSnapshots.count) replicated and offline vvol-snapcoll snapshots for deletion on array $NSGroupName"
    Write-Log -Path $LogPath -Component $NimbleArray -Type "Info" -Message "Gathered $($ReplicatedVolumeSnapshots.count) replicated and offline vvol-snapcoll snapshots for deletion on array $NSGroupName"

    if($Confirm){
        $confirmation = Read-Host "Are you sure you want to delete these snapshots? [y/n]"
        while($confirmation -ne "y"){
            Write-Host "Breaking script. Snapshot deletion will not be performed." -ForegroundColor Red
            break
        }
    }

    # Section to delete the gathered replica snapshots.
    if($ReplicatedVolumeSnapshots){
        foreach($ReplicatedVolumeSnapshot in $ReplicatedVolumeSnapshots){
            Try{
                Write-Log -Path $LogPath -Component $NimbleArray -Type "Info" -Message "Attempting to delete replicated snapshot $($ReplicatedVolumeSnapshot.id) in volume $($ReplicatedVolumeSnapshot.vol_name)"
                Remove-NSSnapshot -id $ReplicatedVolumeSnapshot.id
                Write-Log -Path $LogPath -Component $NimbleArray -Type "Info" -Message "Sucsesfully deleted replicated snapshot $($ReplicatedVolumeSnapshot.id) in volume $($ReplicatedVolumeSnapshot.vol_name)"
                Write-Host "Sucsesfully deleted snapshot $($ReplicatedVolumeSnapshot.name) in volume $($ReplicatedVolumeSnapshot.vol_name)" -ForegroundColor Green
                $ReplicatedSnapshotCounter++
            }
            Catch{
                Write-Log -Path $LogPath -Component $NimbleArray -Type "Error" -Message "Unable to delete snapshot $($ReplicatedVolumeSnapshot.name) with ID $($ReplicatedVolumeSnapshot.id) in volume $($ReplicatedVolumeSnapshot.vol_name)"
                Write-Warning "Unable to delete replicated snapshot $($ReplicatedVolumeSnapshot.name) with ID $($ReplicatedVolumeSnapshot.id) in volume $($ReplicatedVolumeSnapshot.vol_name)"
            }
        }
    }
    else{
        Write-host "No snapshots to delete on $NSGroupName" -ForegroundColor Green
        Write-Log -Path $LogPath -Component $NimbleArray -Type "Info" -Message "No snapshots to delete on $NSGroupName"
        break
    }
    Write-Host "Deleted $ReplicatedSnapshotCounter offline and replicated snapshots on $NSGroupName"
    Write-Log -Path $LogPath -Component $NimbleArray -Type "Info" -Message "Deleted $ReplicateSnapshotCounter offline and replicated snapshots on $NSGroupName"
    Disconnect-NSGroup
}