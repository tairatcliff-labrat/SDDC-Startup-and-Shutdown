#################### Define the Parameters ####################
#################### This script can be used to either Power On or Power Off the VMs in orer ####################

[cmdletbinding(DefaultParameterSetName='PowerOn')]
Param(
    [Parameter(ParameterSetName='PowerOn',Mandatory=$false, HelpMessage="Power on the SDDC")]
    [switch]$PowerOn,
    [Parameter(ParameterSetName='PowerOn',Mandatory=$false, HelpMessage="Wake on LAN")]
    [switch]$WoL,
    [Parameter(ParameterSetName='PowerOff',Mandatory=$false, HelpMessage="Power off the SDDC")]
    [switch]$PowerOff,
    [Parameter(Mandatory=$false, HelpMessage="Will not prompt the user for any questions")]
    [switch]$Unattended
)
If (!($PowerOn.IsPresent -or $PowerOff.IsPresent -or $WoL.IsPresent)) {
  Throw "At least one parameter must be used (-PowerOn, -WoL or -PowerOff)"
}

#################### Declare the functions to Power On or Power Off the Virtual Machine Groups ####################
#################### Function to Start VMs ####################
Function Start-VMGroup($VMGroup){
	#Start with an empty array that will be populated as VMs are successfully powered on
    $PoweredOnList = @()
    $shell = new-object -comobject "WScript.Shell"
		ForEach ($VMstring in $VMGroup){
			If(Get-VMQuestion){
				Get-VMQuestion | Set-VMQuestion -Option "I Copied It" -Confirm:$false
			}
			If(!($VMstring)){Continue}
			$Error.clear()
			$VM = Get-VM -Name $VMstring -ErrorAction SilentlyContinue
			If ($VM.count -gt 1){
				ForEach($VM in $VM){
					If($VM.PowerState -eq "PoweredOn"){
						$VM = $VM
					} Else {
						$VM = $VM[0]
					}
				}	
			}
			If(!($VM)){
				Write-Host "Failed to find a VM named $VMstring" -BackgroundColor Yellow -ForegroundColor Black
				Continue
			}			
			If($VM.PowerState -eq "PoweredOff"){
				Try {
					Start-VM $VM -ErrorAction Stop -Confirm:$false | Out-Null
				} Catch {
					#Any errors in the start up process will be captured and output
					Write-Host "Failed to start $VM" -BackgroundColor Red
					If($_.Exception.Message -contains "Another task is already in progress"){
						Write-Host "Error occurred because another task was in progress. Waiting before trying to power on $($VM.Name) again." -ForegroundColor Yellow
						Start-Sleep -Seconds 10 
						Start-VMGroup $VM
					} Else {
						Write-Host $_.Exception.Message -ForegroundColor Yellow
					}
					If(!($Unattended)){Pause-Script "$VM failed to power on."}
				} Finally {
					#If there were no errors it will be assumed the command to power on the VM was successful
					If(!($Error.Count)){
						Write-Host "Powered on $VM and now waiting for VM Tools to start"
						#A list of VMs that are assumed to be successfully powered on is created separately so that the script 
						#doesn't wait for VMTools to be running on VMs that don't exist or failed to start
						$PoweredOnList += $VM
					}
				} 
			} Else {
				If(!($Unattended)){$RestartVM = $shell.popup("$VM is already powered on, in the incorrect order. Would you like to restart $VM to ensure it is powered on in the correct order?",0,"Restart VM?",4)}
				If(($RestartVM -eq 6) -or ($Unattended)){
					Stop-VMGroup $VM
					Start-VMGroup $VM
				}
			}
		}
    #If VMs were successfully powered on then the PoweredOnList will have VM names that will need to be monitors for VMTools started
    If($PoweredOnList.Count -gt 0){
        ForEach($VM in $PoweredOnList){
            Check-VMToolsRunning $VM | Out-Null
        }
    }
	# Finished powering on the group. Pausing for 1 minute to create an additional time buffer before starting the next group
	# Some VMs can't use a URL to check it's available, so this will help to ensure all VMs in the group are ready for the next group to start.
	Start-Sleep -Seconds 60
}

#################### Function to Stop VMs ####################
Function Stop-VMGroup($VMGroup,[switch]$Force){
    #Start with an empty array that will be populated as VMs are successfully powered off
		$PoweredOffList = @()
		$shell = new-object -comobject "WScript.Shell"
		ForEach ($VMstring in $VMGroup){
			If(!($VMstring)){Continue}
			$Error.clear()
			Try {
				$VM = Get-VM -Name $VMstring -ErrorAction SilentlyContinue
				If ($VM.count -gt 1){
					ForEach($VM in $VM){
						If($VM.PowerState -eq "PoweredOn"){
							$VM = $VM
						} Else {
							$VM = $VM[0]
						}
					}
				}
				If(!($VM)){
					Write-Host "Failed to find a VM named $VMstring" -BackgroundColor Yellow -ForegroundColor Black
					Continue
				}
				If($VM.PowerState -eq "PoweredOn"){
					#Both options to Force the VMs to Power Off or to Shut Down the Guest OS is available
					If($Force){
						Stop-VM $VM -ErrorAction Stop -Confirm:$false | Out-Null
					} Else {
						Stop-VMGuest $VM -ErrorAction Stop -Confirm:$false | Out-Null
					}
				} Else {
					Write-Host "$($VM.Name) is already powered off"
					Continue
				}
				#If there were no errors it will be assumed the command to power off or shutdown the VM was successful
				If(!($Error.Count)){
					Write-Host "Powered off $($VM.Name) and now waiting for VM Tools to stop"
					#A list of VMs that are assumed to be successfully shut down is created separately so that the script 
					#doesn't wait for VMTools to stop on VMs that don't exist or failed to shut down
					$PoweredOffList += $VM
				}
			} Catch {
				#Any errors in the shutdown process will be captured and output
				Write-Host "Failed to stop $VM" -BackgroundColor Red
				Write-Host $_.Exception.Message -ForegroundColor Yellow
				If(!($Unattended)){Pause-Script "Failed to stop $VM"}
			}
		}
    #If VMs were successfully shut down then the PoweredOffList will have VM names that will need to be monitored for VMTools stopped
    If($PoweredOffList.Count -gt 0){
        ForEach($VM in $PoweredOffList){
            $VMPoweredOff = Check-VMToolsStopped $VM
            If(!($VMPoweredOff)){
                Write-Host "VMTools failed to stop on $($VM.Name)" -BackgroundColor Red
                If(!($Unattended)){$Retry = $shell.popup("Guest Shutdown failed. Would you like to try to try and shutdown $VM again? Selecting NO will continue to the next VM.",0,"Retry Shutdown",4)}
                #If you choose Yes, the VMs will be gracefully Powered Off
                If($Retry -eq 7){Break}
                If(!($Unattended)){$ForceRetry = $shell.popup("Would you like to force $VM to power off? Selecting NO will gracefully shutdown the Guest OS",0,"Force Shutdown",4)}
                #If you choose Yes, the VMs will be forcibly Powered Off
                If(($ForceRetry -eq 6) -or ($Unattended)){
                    Stop-VMGroup $VM -Force
                } Else {
                    Stop-VMGroup $VM
                }
            }
        }
    }
}


#################### Define function to send Wake on LAN packets ####################
function Send-WoL([array]$MacAddresses)
{
    ForEach ($MacAddress in $MacAddresses){
        Try{
            $Broadcast = ([System.Net.IPAddress]::Broadcast)
            ## Create UDP client instance
            $UdpClient = New-Object Net.Sockets.UdpClient
            ## Create IP endpoints for each port
            $IPEndPoint = New-Object Net.IPEndPoint $Broadcast, 9
            ## Construct physical address instance for the MAC address of the machine (string to byte array)
            $MAC = [Net.NetworkInformation.PhysicalAddress]::Parse($MacAddress.ToUpper())
            ## Construct the Magic Packet frame
            $Packet =  [Byte[]](,0xFF*6)+($MAC.GetAddressBytes()*16)
            ## Broadcast UDP packets to the IP endpoint of the machine
            $UdpClient.Send($Packet, $Packet.Length, $IPEndPoint) | Out-Null
            $UdpClient.Close()
            Write-Host "Sending Wake on LAN packet to $MacAddress"
        } Catch {
            $UdpClient.Dispose()
            $Error | Write-Error;
        }
    }
}

#################### Define Monitoring functions for startup confirmation #################### 
Function Check-Web($URL){
    If($URL){
        #This will allow self-signed certificates to work
        Disable-SslVerification 
        $CheckWebStopWatch = [System.Diagnostics.Stopwatch]::StartNew()
        #Define the total time to wait for a response
        $CheckWebTimeOut = New-TimeSpan -Minutes 15
        Write-Host "Waiting until $URL is available"
        #$Response = Invoke-WebRequest $URL -ErrorAction SilentlyContinue
        While(($Response.StatusCode -ne "200") -and ($CheckWebStopWatch.Elapsed -le $CheckWebTimeOut)){
            Try{
                $Response = Invoke-WebRequest $URL -ErrorAction SilentlyContinue
            } Catch {
                Start-Sleep -Seconds 10
            }        
        }
        If($Response.StatusCode -eq "200"){
            Write-Host "$URL is now responding" -BackgroundColor Blue -ForegroundColor Yellow
			return $true
        } Else {
            If(!($Unattended)){Pause-Script "Timed out while waiting for $URL to respond."}
            return $false
        }
    }
}

Function Check-VMToolsRunning([PSObject]$VM){
    #$VM = Get-VM -Name $VMName
    $ToolsRunningStopWatch = [System.Diagnostics.Stopwatch]::StartNew()
    #Define the total time to wait for a response
    $ToolsRunningTimeOut = New-TimeSpan -Minutes 5
    While(($VM.Guest.ExtensionData.GuestState -ne "running") -and ($ToolsRunningStopWatch.Elapsed -le $ToolsRunningTimeOut)){
                Start-Sleep -Seconds 10
            }
    If($VM.Guest.ExtensionData.GuestState -eq "running"){
                Write-Host "VMTools is now confirmed running on $($VM.Name)" -BackgroundColor Blue
                return $True
            } Else {
                return $False
            }
}

Function Check-VMToolsStopped([PSObject]$VM){
    $ToolsStoppedStopWatch = [System.Diagnostics.Stopwatch]::StartNew()
    #Define the total time to wait for a response
    $ToolsStoppedTimeOut = New-TimeSpan -Minutes 15
    While(($VM.Guest.ExtensionData.GuestState -ne "NotRunning") -and ($ToolsStoppedStopWatch.Elapsed -le $ToolsStoppedTimeOut)){
                Start-Sleep -Seconds 10
            }
    If($VM.Guest.ExtensionData.GuestState -eq "NotRunning"){
                Write-Host "VMTools is now confirmed stopped on $($VM.Name)" -BackgroundColor Blue
                return $True
            } Else {
                return $False
            }
}

Function Pause-Script($Reason){
    $shell = new-object -comobject "WScript.Shell"
    $Continue = $shell.popup("$Reason The script is now paused. Manually remediate the issue and click YES to continue or NO to quit.",0,"Continue?",4)
    #Yes(6) to continue, No(7) to quit
    If($Continue -eq 7){Exit-Script}
}

Function Disable-SslVerification{
    if (-not ([System.Management.Automation.PSTypeName]"TrustEverything").Type){
        Add-Type -TypeDefinition  @"
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class TrustEverything
{
    private static bool ValidationCallback(object sender, X509Certificate certificate, X509Chain chain,
        SslPolicyErrors sslPolicyErrors) { return true; }
    public static void SetCallback() { System.Net.ServicePointManager.ServerCertificateValidationCallback = ValidationCallback; }
    public static void UnsetCallback() { System.Net.ServicePointManager.ServerCertificateValidationCallback = null; }
}
"@
    }
    [TrustEverything]::SetCallback()
}

Function Enable-SslVerification{
    if (([System.Management.Automation.PSTypeName]"TrustEverything").Type){
        [TrustEverything]::UnsetCallback()
    }
}

Function Exit-Script{
	Disconnect-VIServer * -confirm:$false -Force
	Write-Host
	Write-Host "Completed the process in" $TimeTaken.Elapsed -BackgroundColor Black -ForegroundColor Yellow
	Enable-SslVerification
	Exit
}


########################################################################################################################
####################                                                                                ####################
####################                       Define Start and Stop Functions                          ####################
####################                                                                                ####################
########################################################################################################################

Function Start-Core(){
    Start-VMGroup $StartOrder.Core.PSC.Name; ForEach($URL in $StartOrder.Core.PSC.URL){Check-Web $URL | Out-Null}
    Start-VMGroup $StartOrder.Core.PSCLoadBalacer.Name; ForEach($URL in $StartOrder.Core.PSCLoadBalacer.URL){Check-Web $URL | Out-Null}
	Start-VMGroup $StartOrder.Core.vCenter.Name; ForEach($URL in $StartOrder.Core.vCenter.URL){Check-Web $URL | Out-Null}
	Start-VMGroup $StartOrder.Core.vUMDownloadService.Name; ForEach($URL in $StartOrder.Core.vUMDownloadService.URL){Check-Web $URL | Out-Null}
}
Function Stop-Core(){
	Stop-VMGroup $StartOrder.Core.vUMDownloadService.Name
	Stop-VMGroup $StartOrder.Core.vCenter.Name
	Stop-VMGroup $StartOrder.Core.PSCLoadBalacer.Name
	Stop-VMGroup $StartOrder.Core.PSC.Name
}
Function Start-NSX(){
	Start-VMGroup $StartOrder.NSX.NSXManager.Name; ForEach($URL in $StartOrder.Core.NSXManager.URL){Check-Web $URL | Out-Null}
	Start-VMGroup $StartOrder.NSX.NSXController.Name; ForEach($URL in $StartOrder.Core.NSXController.URL){Check-Web $URL | Out-Null}
	Start-VMGroup $StartOrder.NSX.NSXEdge.Name; ForEach($URL in $StartOrder.Core.NSXEdge.URL){Check-Web $URL | Out-Null}
}
Function Stop-NSX(){
	Stop-VMGroup $StartOrder.NSX.NSXEdge.Name
	Stop-VMGroup $StartOrder.NSX.NSXController.Name
	Stop-VMGroup $StartOrder.NSX.NSXManager.Name
}
Function Start-BCDR(){
	Start-VMGroup $StartOrder.BCDR.vSphereReplication.Name; ForEach($URL in $StartOrder.BCDR.vSphereReplication.URL){Check-Web $URL | Out-Null}
	Start-VMGroup $StartOrder.BCDR.SRM.Name; ForEach($URL in $StartOrder.BCDR.SRM.URL){Check-Web $URL | Out-Null}
}
Function Stop-BCDR(){
	Stop-VMGroup $StartOrder.BCDR.SRM.Name
	Stop-VMGroup $StartOrder.BCDR.vSphereReplication.Name
}
Function Start-Database(){
	Start-VMGroup $StartOrder.Database.SQL.Name; ForEach($URL in $StartOrder.Database.SQL.URL){Check-Web $URL | Out-Null}
}
Function Stop-Database(){
	Stop-VMGroup $StartOrder.Database.SQL.Name
}
Function Start-vRealizeAutomation(){
	Start-VMGroup $StartOrder.vRealizeAutomation.vRAMaster.Name; ForEach($URL in $StartOrder.vRealizeAutomation.vRAMaster.URL){Check-Web $URL | Out-Null}
	Start-VMGroup $StartOrder.vRealizeAutomation.vRASecondary.Name; ForEach($URL in $StartOrder.vRealizeAutomation.vRASecondary.URL){Check-Web $URL | Out-Null}
	Start-VMGroup $StartOrder.vRealizeAutomation.vRAWebPrimary.Name; ForEach($URL in $StartOrder.vRealizeAutomation.vRAWebPrimary.URL){Check-Web $URL | Out-Null}
	Start-VMGroup $StartOrder.vRealizeAutomation.vRAWebSecondary.Name; ForEach($URL in $StartOrder.vRealizeAutomation.vRAWebSecondary.URL){Check-Web $URL | Out-Null}
	Start-VMGroup $StartOrder.vRealizeAutomation.vRAManagerPrimary.Name; ForEach($URL in $StartOrder.vRealizeAutomation.vRAManagerPrimary.URL){Check-Web $URL | Out-Null}
	Start-VMGroup $StartOrder.vRealizeAutomation.vRAManagerSecondary.Name; ForEach($URL in $StartOrder.vRealizeAutomation.vRAManagerSecondary.URL){Check-Web $URL | Out-Null}
	Start-VMGroup $StartOrder.vRealizeAutomation.vRADEMProxyAgent.Name; ForEach($URL in $StartOrder.vRealizeAutomation.vRADEMProxyAgent.URL){Check-Web $URL | Out-Null}
	Start-VMGroup $StartOrder.vRealizeAutomation.vRB.Name; ForEach($URL in $StartOrder.vRealizeAutomation.vRB.URL){Check-Web $URL | Out-Null}
	Start-VMGroup $StartOrder.vRealizeAutomation.vRBCollector.Name; ForEach($URL in $StartOrder.vRealizeAutomation.vRBCollector.URL){Check-Web $URL | Out-Null}
}
Function Stop-vRealizeAutomation(){
	Stop-VMGroup $StartOrder.vRealizeAutomation.vRBCollector.Name
	Stop-VMGroup $StartOrder.vRealizeAutomation.vRB.Name
	Stop-VMGroup $StartOrder.vRealizeAutomation.vRADEMProxyAgent.Name
	Stop-VMGroup $StartOrder.vRealizeAutomation.vRAManagerSecondary.Name
	Stop-VMGroup $StartOrder.vRealizeAutomation.vRAManagerPrimary.Name
	Stop-VMGroup $StartOrder.vRealizeAutomation.vRAWebSecondary.Name
	Stop-VMGroup $StartOrder.vRealizeAutomation.vRAWebPrimary.Name
	Stop-VMGroup $StartOrder.vRealizeAutomation.vRASecondary.Name
	Stop-VMGroup $StartOrder.vRealizeAutomation.vRAMaster.Name
}
Function Start-vRealizeOperations(){
	Start-VMGroup $StartOrder.vRealizeOperations.vROpsMaster.Name; ForEach($URL in $StartOrder.vRealizeOperations.vROpsMaster.URL){Check-Web $URL | Out-Null}
	Start-VMGroup $StartOrder.vRealizeOperations.vROpsReplica.Name; ForEach($URL in $StartOrder.vRealizeOperations.vROpsReplica.URL){Check-Web $URL | Out-Null}
	Start-VMGroup $StartOrder.vRealizeOperations.vROpsData.Name; ForEach($URL in $StartOrder.vRealizeOperations.vROpsData.URL){Check-Web $URL | Out-Null}
	Start-VMGroup $StartOrder.vRealizeOperations.vROpsCollector.Name; ForEach($URL in $StartOrder.vRealizeOperations.vROpsCollector.URL){Check-Web $URL | Out-Null}
}
Function Stop-vRealizeOperations(){
	Stop-VMGroup $StartOrder.vRealizeOperations.vROpsCollector.Name
	Stop-VMGroup $StartOrder.vRealizeOperations.vROpsData.Name
	Stop-VMGroup $StartOrder.vRealizeOperations.vROpsReplica.Name
	Stop-VMGroup $StartOrder.vRealizeOperations.vROpsMaster.Name
}
Function Start-vRealizeLogInsight(){
	Start-VMGroup $StartOrder.vRealizeLogInsight.vRLIMaster.Name; ForEach($URL in $StartOrder.vRealizeLogInsight.vRLIMaster.URL){Check-Web $URL | Out-Null}
	Start-VMGroup $StartOrder.vRealizeLogInsight.vRLISecondaries.Name; ForEach($URL in $StartOrder.vRealizeLogInsight.vRLISecondaries.URL){Check-Web $URL | Out-Null}
}
Function Stop-vRealizeLogInsight(){
    Stop-VMGroup $StartOrder.vRealizeLogInsight.vRLISecondaries.Name
	Stop-VMGroup $StartOrder.vRealizeLogInsight.vRLIMaster.Name
}
Function Start-DataProtection(){
	Start-VMGroup $StartOrder.DataProtection.vDP.Name; ForEach($URL in $StartOrder.DataProtection.vDP.URL){Check-Web $URL | Out-Null}
}
Function Stop-DataProtection(){
    Stop-VMGroup $StartOrder.DataProtection.vDP.Name
}


########################################################################################################################
####################                                                                                ####################
####################                             Script Starts Here                                 ####################
####################                                                                                ####################
########################################################################################################################

#################### Load VMware modules if not loaded ####################
Import-Module -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue

#################### Import the Json file that contains the list of VMs to start  ###################
$StartOrder = Get-Content "$PSScriptRoot\PowerSDDC.json" | ConvertFrom-Json

#################### Import all of the ESXi hosts and login credentials. #################### 
$EsxHosts = Import-Csv -Path "$PSScriptRoot\EsxHosts.csv"
If($EsxHosts.Name){$Credentials = Get-Credential}
If(!($Credentials)){Exit}

#################### Use Wake on LAN to power on all of the ESXi Hosts and wait until finished ####################
If($WoL){
    If($EsxHosts.MAC){
        Send-WoL $EsxHosts.MAC
    } Else {
        Throw "There are no MAC addressed defined in the configuration for Wake on LAN"
    }
}

################### Check that all the intended ESXi hosts are available ####################
ForEach($EsxHost in $EsxHosts.Name){
    Check-Web "https://$EsxHost/ui/#/login" | Out-Null
}

#################### Log on to all of the ESXi hosts in a single shared session ####################
If($EsxHosts.Name){Connect-VIServer $EsxHosts.Name -Credential $Credentials -Force}

#################### Execute each priority group in the order it is to be ran ####################
$TimeTaken = [System.Diagnostics.Stopwatch]::StartNew()

If($PowerOn){
    #exit maintenance mode
    Set-VMHost -Host $EsxHosts.Name -State "Connected" | Out-Null

	Start-Core
	Start-NSX
	Start-BCDR
	Start-Database
	Start-vRealizeAutomation
	Start-vRealizeOperations
	Start-vRealizeLogInsight
	Start-DataProtection
}

If($PowerOff){
	Stop-DataProtection -RunAsync
	Stop-vRealizeLogInsight -RunAsync
	Stop-vRealizeOperations -RunAsync
	Stop-vRealizeAutomation
	Stop-Database
	Stop-BCDR
	Stop-NSX
	Stop-Core
   
    #Check for any remaining powered on VMs
    $PoweredOnVMs = Get-VM | Where {$_.PowerState -eq "PoweredOn"}
    If($PoweredOnVMs){
        Write-Host "Found the following VMs are still powered on. Would you like to try and power them off?" -BackgroundColor Yellow -ForegroundColor Black
        Write-Host $PoweredOnVMs
        $shell = new-object -comobject "WScript.Shell"
        If(!($Unattended)){$PowerOffRemaingVMs = $shell.popup("Found a list of VMs still powered ON. Would you like to try and power them off?",0,"Power Off remaining VMs?",4)}
        If(($PowerOffRemaingVMs -eq 6) -or ($Unattended)){Stop-VMGroup $PoweredOnVMs}
    }
    If($PowerOffRemaingVMs -eq 7){
        Exit-Script
    }Else{
        #Enter maintenance mode
        $shell = new-object -comobject "WScript.Shell"
        If(!($Unattended)){$MaintenanceMode = $shell.popup("Would you like to put all ESXi hosts in Maintenance Mode?",0,"Maintenance Mode?",4)}
        If(($MaintenanceMode -eq "6") -or ($Unattended)){
            ForEach($VMHost in $EsxHosts.Name){
                Write-Host "$VMHost is now entering Maintenance Mode" -BackgroundColor Yellow -ForegroundColor Black
				Write-Host ""
				Set-VMHost -Host $VMHost -State "Maintenance" -evacuate:$false -VsanDataMigrationMode "NoDataMigration" | Out-Null
            }
        Get-VMHost | Select "Name","ConnectionState","PowerState" | FT
        }

        #Power off the ESXi Hosts
        If(!($Unattended)){$PowerOffESXi = $shell.popup("Would you like to power off all the ESXi hosts?",0,"Power Off ESXi?",4)}
        If(($PowerOffESXi -eq "6") -or ($Unattended)){
            ForEach($VMHost in $EsxHosts.Name){
				Write-Host "$VMHost is now being powered off" -BackgroundColor Yellow -ForegroundColor Black
				Write-Host ""
                Stop-VMHost -Host $VMHost -Confirm:$false | Out-Null
            }
        }
    }
}

Exit-Script
