#################### Define the Parameters ####################
#################### This script can be used to either Power On or Power Off the VMs in orer ####################
Param(
    [switch]$PowerOn,
    [switch]$PowerOff
)

#################### Load VMware modules if not loaded ####################
Import-Module -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue

#################### Define the Virtual Machine Priority Groups and Start Order  ####################
#################### All VMs in the same group will be Powered on simultaniously ####################
$Properties = @{'PriorityGroup1'=   "psc01",`
                                    "psc02",`
                                    "psc-0",`
                                    "psc-1"
                'PriorityGroup2'=   "vc01",`
                                    "vc02"
                'PriorityGroup3'=   "nsx01",`
                                    "nsx02"
                'PriorityGroup4'=   "NSX_Controller_78d21c55-f254-4a5e-a501-326eded463d1",`
                                    "NSX_Controller_ca9f2efa-d3f9-4d5d-bed1-46b5390fa38a",`
                                    "NSX_Controller_075fa393-caa2-4fe8-b2be-c164c163db0f",`
                                    "NSX_Controller_0a24223f-801d-4a75-870d-46c238788195",`
                                    "NSX_Controller_32324c0d-425e-4a73-bc05-427296c4a746",`
                                    "NSX_Controller_f0ebefa2-49ff-4c24-bfeb-1e10576828b0"
                'PriorityGroup5'=   "MGMT-ESG01-0",`
                                    "MGMT-ESG02-0",`
                                    "COMPUTE-ESG01-0",`
                                    "COMPUTE-ESG02-0",`
                                    "DLR01-EDGE-0",`
                                    "DLR01-EDGE-1",`
                                    "edge-9fc6404e-dcb2-4b3f-bd4f-7e368c4d104f-1-UDLR01-MGMT",`
                                    "edge-9fc6404e-dcb2-4b3f-bd4f-7e368c4d104f-0-UDLR01-MGMT",`
                                    "edge-758cfb8d-3d59-4082-96a3-ce44417930db-1-UDLR01-EDGE",`
                                    "edge-758cfb8d-3d59-4082-96a3-ce44417930db-0-UDLR01-EDGE",`
                                    "MGMT-LB01-0",`
                                    "MGMT-LB01-1"
                'PriorityGroup6'=   "sql01"
                'PriorityGroup7'=   "vra01",
                                    "vra02"
                'PriorityGroup8'=   "iaas01",
                                    "iaas02"
                'PriorityGroup9'=   "ims01",`
                                    "ims02"
                'PriorityGroup10'=  "dem01",`
                                    "dem02"
                'PriorityGroup11'=  "vra-agent01",`
                                    "vra-agent02"
                'PriorityGroup12'=  "vrops01"
                'PriorityGroup13'=  "vrops02"
                'PriorityGroup14'=  "vrops03"
                'PriorityGroup15'=  "vrops-col-01",`
                                    "vrops-col-02"
                'PriorityGroup16'=  "vrli01"
                'PriorityGroup17'=  "vrli02"
                'PriorityGroup18'=  "vrli03"
                'PriorityGroup19'=  "vrb"
                'PriorityGroup20'=  "vrb01"
                'PriorityGroup21'=  "vdp"
}
$StartOrder = New-Object -TypeName PSObject –Prop $Properties

#################### List all of the ESXi hosts where the VMs may be hosted. #################### 
$EsxHosts = "esxi101.labrat.local",`
            "esxi102.labrat.local",`
            "esxi103.labrat.local",`
            "esxi131.labrat.local",`
            "esxi132.labrat.local",`
            "esxi133.labrat.local",`
            "esxi138.labrat.local"

#################### Log on to all of the ESXi hosts in a single shared session ####################
$Credentials = Get-Credential
Connect-VIServer $EsxHosts -Credential $Credentials -Force

#################### Declare the functions to Power On or Power Off the Virtual Machine Groups ####################
#################### Function to Start VMs ####################
Function Start-VMGroup($VMGroup){
    #Start with an empty array that will be populated as VMs are successfully powered on
    $PoweredOnList = @()
    ForEach ($VM in $VMGroup){
        $Error.clear()
        Try {
            Start-VM $VM -ErrorAction Stop -Confirm:$false | Out-Null
        } Catch {
            #Any errors in the shutdown process will be captured and output
            Write-Host "Failed to start VM: $VM" -BackgroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Yellow
            Continue
        } Finally {
            #If there were no errors it will be assumed the command to power on the VM was successful
            If(!($Error.Count)){
                Write-Host "Powered on $VM and now waiting for VM Tools to start"
                #A list of VMs that are assumed to be successfully powered on is created separately so that the script 
                #doesn't wait for VMTools to be running on VMs that don't exist or failed to start
                $PoweredOnList += $VM
            }
        }
    }
    #If VMs were successfully powered on then the PoweredOnList will have VM names that will need to be monitors for VMTools started
    If($PoweredOnList.Count -gt 0){
        ForEach($VM in $PoweredOnList){
            #Start a stopwatch so that after a defined period of time the script will continue regardless of the VMTools status
            $StopWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $VM = Get-VM | Where{$_.Name -eq $VM}
            #Define the total time to wait for each VM to confirm VMTools is stopped
            $TimeOut = New-TimeSpan -Minutes 5
            While(($VM.Guest.ExtensionData.GuestState -ne "running") -and ($StopWatch.Elapsed -le $TimeOut)){
                Start-Sleep -Seconds 10
            }
            If($VM.Guest.ExtensionData.GuestState -eq "running"){
                Write-Host "VMTools is now running on VM:" $VM.Name -BackgroundColor Blue
            } Else {
                Write-Host "Timed out while waiting for VMTools to start on VM:" $VM.Name
                #If the first start up process doesn't work for any VMs they will be entered into a new list to be retried
                #Any VMs that failed to start up will need to be processed before moving to the next VM Priority Group
                $RetryPowerOnList += $VM.Name
            }
        }
    }
    #Ask if you would like the script to retry starting up the VMs.
    If($RetryPowerOnList.Count -gt 0){
        $shell = new-object -comobject "WScript.Shell"
        #A shell popup will ask if you woul dlike to retry the VMs that failed to power on
        $Retry = $shell.popup("Would you like to try and power on the VMs where VMTools have not yet responded?",0,"Retry?",4)
        #If you answer Yes to retry, you will then be asked if you would like to to force a VM shut down, or a chose a Guest OS shut down
        #If you chose No, the script will continue to run and move on to the next VM Priority Groups - This is not recommended unless manual intervention is actioned
        If($Retry -eq "6"){Start-VMGroup $RetryPowerOnList}
        #If you chose to Cancel the script will exit 
        If($Retry -eq 2){Break}
    }
}

#################### Function to Stop VMs ####################
Function Stop-VMGroup($VMGroup,[switch]$Force){
    #Start with an empty array that will be populated as VMs are successfully powered off
    $PoweredOffList = @()
    $RetryPowerOffList = @()
    ForEach ($VM in $VMGroup){
        $Error.clear()
        Try {
            #Both options to Force the VMs to Power Off or to Shut Down the Guest OS is available
            If($Force){Stop-VM $VM -ErrorAction Stop -Confirm:$false | Out-Null}
            Else {Stop-VMGuest $VM -ErrorAction Stop -Confirm:$false | Out-Null}
        } Catch {
            #Any errors in the shutdown process will be captured and output
            Write-Host "Failed to stop VM: $VM" -BackgroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Yellow
            Continue
        } Finally {
            #If there were no errors it will be assumed the command to power off or shutdown the VM was successful
            If(!($Error.Count)){
                Write-Host "Powered off $VM and now waiting for VM Tools to stop"
                #A list of VMs that are assumed to be successfully shut down is created separately so that the script 
                #doesn't wait for VMTools to stop on VMs that don't exist or failed to shut down
                $PoweredOffList += $VM
            }
        }
    }
    #If VMs were successfully shut down then the PoweredOffList will have VM names that will need to be monitors for VMTools stopped
    If($PoweredOffList.Count -gt 0){
        ForEach($VM in $PoweredOffList){
            #Start a stopwatch so that after a defined period of time the script will continue regardless of the VMTools status
            $StopWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $VM = Get-VM | Where{$_.Name -eq $VM}
            #Define the total time to wait for each VM to confirm VMTools is stopped
            $TimeOut = New-TimeSpan -Minutes 5
            While(($VM.Guest.ExtensionData.GuestState -ne "NotRunning") -and ($StopWatch.Elapsed -le $TimeOut)){
                Start-Sleep -Seconds 10
            }
            If($VM.Guest.ExtensionData.GuestState -eq "NotRunning"){
                Write-Host "VMTools is now stopped on VM:" $VM.Name -BackgroundColor Blue
            } Else {
                Write-Host "Timed out while waiting for VMTools to stop on VM:" $VM.Name -BackgroundColor Red
                #If the first shutdown process doesn't work for any VMs they will be entered into a new list to be retried
                #Any VMs that failed to shut down will need to be processed before moving to the next VM Priority Group
                $RetryPowerOffList += $VM.Name
            }
        }
    }
    #Ask if you would like the script to retry shutting down VMs. Both options are are provided to shut down the Guest OS or force a Power Off
    If($RetryPowerOffList.Count -gt 0){
        $shell = new-object -comobject "WScript.Shell"
        $Retry = $shell.popup("Would you like to try and power off the failed VM Guest OS again?",0,"Retry?",3)
        #If you answer Yes to retry, you will then be asked if you would like to to force a VM shut down, or a chose a Guest OS shut down
        #If you chose to Cancel the script will exit
        #If you chose No, the script will continue to run and move on to the next VM Priority Groups - This is not recommended unless manual intervention is actioned
        If($Retry -eq "6"){
            $ForceRetry = $shell.popup("Would you like to force the VM to power off?",0,"Force Retry",3)
            #If you choose Yes, the VMs will be forcibly Powered Off
            If($ForceRetry -eq 6){Stop-VMGroup $RetryPowerOffList -Force}
            #If you chose to Cancel the entire script will exit and no VMs in the remaining Priority Groups will be attempted to shut down
            If($ForceRetry -eq "2"){Break}
            #If you answer No to the Force Shutdown, a Guest OS shut down will be retried
            If($ForceRetry -eq 7){Stop-VMGroup $RetryPowerOffList}
        If($Retry -eq 2){Break}
        }
    }
}

#################### Execute each priority group in the order it is to be ran ####################
If($PowerOn){
    Start-VMGroup $StartOrder.PriorityGroup1
    Start-VMGroup $StartOrder.PriorityGroup2
    Start-VMGroup $StartOrder.PriorityGroup3
    Start-VMGroup $StartOrder.PriorityGroup4
    Start-VMGroup $StartOrder.PriorityGroup5
    Start-VMGroup $StartOrder.PriorityGroup6
    Start-VMGroup $StartOrder.PriorityGroup7
    Start-VMGroup $StartOrder.PriorityGroup8
    Start-VMGroup $StartOrder.PriorityGroup9
    Start-VMGroup $StartOrder.PriorityGroup10
    Start-VMGroup $StartOrder.PriorityGroup11
    Start-VMGroup $StartOrder.PriorityGroup12
    Start-VMGroup $StartOrder.PriorityGroup13
    Start-VMGroup $StartOrder.PriorityGroup14
    Start-VMGroup $StartOrder.PriorityGroup15
    Start-VMGroup $StartOrder.PriorityGroup16
    Start-VMGroup $StartOrder.PriorityGroup17
    Start-VMGroup $StartOrder.PriorityGroup18
    Start-VMGroup $StartOrder.PriorityGroup19
    Start-VMGroup $StartOrder.PriorityGroup20
    Start-VMGroup $StartOrder.PriorityGroup21
}

If($PowerOff){
    Stop-VMGroup $StartOrder.PriorityGroup21
    Stop-VMGroup $StartOrder.PriorityGroup20
    Stop-VMGroup $StartOrder.PriorityGroup19
    Stop-VMGroup $StartOrder.PriorityGroup18
    Stop-VMGroup $StartOrder.PriorityGroup17
    Stop-VMGroup $StartOrder.PriorityGroup16
    Stop-VMGroup $StartOrder.PriorityGroup15
    Stop-VMGroup $StartOrder.PriorityGroup14
    Stop-VMGroup $StartOrder.PriorityGroup13
    Stop-VMGroup $StartOrder.PriorityGroup12
    Stop-VMGroup $StartOrder.PriorityGroup11
    Stop-VMGroup $StartOrder.PriorityGroup10
    Stop-VMGroup $StartOrder.PriorityGroup9
    Stop-VMGroup $StartOrder.PriorityGroup8
    Stop-VMGroup $StartOrder.PriorityGroup7
    Stop-VMGroup $StartOrder.PriorityGroup6
    Stop-VMGroup $StartOrder.PriorityGroup5
    Stop-VMGroup $StartOrder.PriorityGroup4
    Stop-VMGroup $StartOrder.PriorityGroup3
    Stop-VMGroup $StartOrder.PriorityGroup2
    Stop-VMGroup $StartOrder.PriorityGroup1
}
