########################################################################################################################
## Copyright 2022 Tom Liddle <thomas_liddle@hotmail.com>
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
##     http://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##
## ----------------------------------------------------- ##
##  ######                      #     #                  ##
##  #     #   ##   #####   ##   ##   ##   ##   # #####   ##
##  #     #  #  #    #    #  #  # # # #  #  #  # #    #  ##
##  #     # #    #   #   #    # #  #  # #    # # #    #  ##
##  #     # ######   #   ###### #     # ###### # #    #  ##
##  #     # #    #   #   #    # #     # #    # # #    #  ##
##  ######  #    #   #   #    # #     # #    # # #####   ##
## ----------------------------------------------------- ##
##
########################################################################################################################

########################################################################################################################
# Command Line Parameters
########################################################################################################################
[CmdletBinding()]
Param (
	[Switch]$SCCM,
	[Switch]$Updates,
	[Switch]$Recycle,
	[Switch]$SysTemp,
	[Switch]$UserTemp,
	[Switch]$IIS,
	[Switch]$OldProf,
	[Switch]$DisProf,
    [switch]$BranchCache,
	[Int]$DaysToKeep = 7
)

########################################################################################################################
# Modules
########################################################################################################################
# Importing the InteractiveMenu Module.
Import-Module .\InteractiveMenu\InteractiveMenu.psd1

########################################################################################################################
# Functions
########################################################################################################################
Function global:Write-Verbose {
	Param (
		[string]$Message
	)
 	# check $VerbosePreference variable, and turns -Verbose on 
	If ($VerbosePreference -ne 'SilentlyContinue') {
		Write-Host " $Message" -ForegroundColor 'Red'
	} 
} 

Function Get-DiskSpace {
	# Returns disk space as string
	$DiskSpace = Get-WmiObject Win32_LogicalDisk | Where-Object {$_.DriveType -eq "3"} | `
		Select-Object SystemName,
			@{Name="Drive"; Expression={($_.DeviceID)}},
			@{Name="Size (GB)"; Expression={"{0:N1}" -f( $_.Size / 1gb)}},
			@{Name="FreeSpace (GB)"; Expression={"{0:N1}" -f($_.Freespace / 1gb)}},
			@{Name="PercentFree"; Expression={"{0:P1}" -f($_.FreeSpace / $_.Size)}} | Format-Table -AutoSize | Out-String    
		
	Return $DiskSpace
}

Function Get-Profiles {
	# Enumerates User Profiles
	$UserProfiles = Get-WmiObject -Class Win32_UserProfile -filter "not SID like '%-500' and Special = False" 
	$ProfileList=@()

	ForEach ($UserProfile in $UserProfiles) {

			$Rec = New-Object PSObject
				
			$Rec | Add-Member -MemberType NoteProperty -Name "ComputerName" -Value $UserProfile.PSComputerName
			$Rec | Add-Member -MemberType NoteProperty -Name "Path" -Value $UserProfile.LocalPath
			$Rec | Add-Member -MemberType NoteProperty -Name "SID" -Value $UserProfile.SID
			$Rec | Add-Member -MemberType NoteProperty -Name "Loaded" -Value $UserProfile.Loaded
			
			# Check Account Status
			$AccountStatus = $null
            $AccountStatus = (Get-WmiObject Win32_UserAccount | Where-Object {$_.SID -eq $UserProfile.SID}).Disabled
            If ($null -ne $AccountStatus) {
                $Rec | Add-Member -MemberType NoteProperty -Name "Disabled" -Value $AccountStatus
            } Else {
                $Rec | Add-Member -MemberType NoteProperty -Name "Disabled" -Value "N/A"
            }

			# Lookup Username by SID
			Try {
				$objSID = New-Object System.Security.Principal.SecurityIdentifier($UserProfile.SID) 
				$objUser = $objSID.Translate([System.Security.Principal.NTAccount]) 
	
				$Rec | Add-Member -MemberType NoteProperty -Name "UserName" -Value $objUser.Value
			} Catch {
				# Tag as Account Unknown if it cannot be resolved.
				$Rec | Add-Member -MemberType NoteProperty -Name "UserName" -Value "Account Unknown"
			}
			# Update array
			$ProfileList+=$Rec
	}
	Return $ProfileList
}

Function Clear-SCCMCache {
	# Clears SCCM cache if found
	Try {
		$CMObject = New-Object -ComObject "UIResource.UIResourceMgr"
		$CMCacheObjects = $CMObject.GetCacheInfo()
		$CMCacheElements = $CMCacheObjects.GetCacheElements()

		Foreach ($CacheElement in $CMCacheElements) {
		   	$CMCacheObjects.DeleteCacheElementEx($CacheElement.CacheElementID)
			Write-Verbose "SCCM: Removed - $CacheElement.CacheElementID"
		}
	} Catch {
		Write-Verbose "SCCM: SCCM Client does not exist."
	}
}

Function Clear-Updates {
	Get-Service -Name wuauserv | Stop-Service -Force -Verbose -ErrorAction SilentlyContinue
	Start-Process "dism.exe" -ArgumentList "/online /cleanup-image /spsuperseded" -NoNewWindow -Wait -PassThru | Out-Null

	Get-ChildItem "$Env:SystemRoot\SoftwareDistribution\*" -Recurse -Force -Verbose -ErrorAction SilentlyContinue | `
		Remove-Item -Force -Verbose -Recurse -ErrorAction SilentlyContinue
	
	Get-Service -Name wuauserv | Start-Service -Verbose 
}

Function Clear-Recycler {
	# Empties Recycle Bin
	# $objShell = New-Object -ComObject Shell.Application  
	# $objFolder = $objShell.Namespace(0xA)
	(New-Object -ComObject Shell.Application).NameSpace(0x0a).Items() | Select-Object `
		Name, `
		Size, `
		Path, `
		ModifyDate | Remove-Item -Verbose -Force -ErrorAction SilentlyContinue
}

Function Clear-SysTemp {
	# Cleans System Temp Directory
	Param (
		[Int]$Days
	)
	
	Get-ChildItem "$Env:SystemRoot\Temp\*" -Recurse -Force -Verbose -ErrorAction SilentlyContinue | `
		Where-Object {($_.CreationTime -lt $(Get-Date).AddDays(-$Days))} | `
		Remove-Item -Force -Verbose -Recurse -ErrorAction SilentlyContinue 
}

Function Clear-UserTemp {
	# Clean User Temp Directories, pass Output of Get-Profiles to $ProfileList
	Param (
		[Int]$Days,
		$ProfileList
	)
	
	ForEach ($Profile in $ProfileList) {
		# Deletes all files and folders in user's Temp folder.
		$Path = Join-Path -Path $Profile.Path -ChildPath "\AppData\Local\Temp\*"
		
		Get-ChildItem $Path -Recurse -Force -ErrorAction SilentlyContinue | 
			Where-Object { ($_.CreationTime -lt $(Get-Date).AddDays(-$Days))} | 
			Remove-Item -Force -Verbose -Recurse -ErrorAction SilentlyContinue 
			
		# Deletes all files and folders in user's Temporary Internet Files.
		$Path = Join-Path -Path $Profile.Path -ChildPath "\AppData\Local\Microsoft\Windows\Temporary Internet Files\*"
		Get-ChildItem $Path -Recurse -Force -Verbose -ErrorAction SilentlyContinue | 
			Where-Object {($_.CreationTime -le $(Get-Date).AddDays(-$Days))} | 
			Remove-Item -Force -Recurse -ErrorAction SilentlyContinue 
	}
}

Function Clear-IISLogs {
	# Derived from: https://gallery.technet.microsoft.com/scriptcenter/31db73b4-746c-4d33-a0aa-7a79006317e6
	# Title: Compress and Remove Log Files (IIS and others)
	# Author: Bernie Salvaggio
	Param (
		[Int]$Days
	)
	
	Try {
		# IIS: Automatically parse IIS log file folders 
	    # Check IIS version and load the WebAdministration module accordingly 
	    $iisVersion = Get-ItemProperty "HKLM:\software\microsoft\InetStp" -ErrorAction SilentlyContinue
	    If ($iisVersion.MajorVersion -ge 7) { 
	        If ($iisVersion.MinorVersion -ge 5 -or $iisVersion.MajorVersion -ge 8) { 
	            # IIS 7.5 or higher 
	            Import-Module WebAdministration -ErrorAction Stop
	        } Else {  
	            If (-not (Get-PSSnapIn | Where-Object {$_.Name -eq "WebAdministration"})) { 
	                # IIS 7 
	                Add-PSSnapIn WebAdministration -ErrorAction Stop 
	            } 
	        } 
	        # Grab a list of the IIS sites 
	        $Sites = get-item IIS:\Sites\* -ErrorAction Stop 
	        $Targets = @() 
	        ForEach ($Site in $Sites) {  
	            # Grab the site's base log file directory  
	            $SiteDirectory = $Site.logFile.Directory 
	            # That returns %SystemDrive% as text instead of the value of the  
	            # env variable, which PoSH chokes on, so replace it correctly 
	            $SiteDirectory = $SiteDirectory.replace("%SystemDrive%",$env:SystemDrive) 
	            # Set the site's actual log file folder (the W3SVC## or FTPSVC## dir) 
	            If ($Site.Bindings.Collection.Protocol -like "*ftp*") {
					$SiteLogfileDirectory = $SiteDirectory+"\FTPSVC"+$Site.ID
				} Else {
					$SiteLogfileDirectory = $SiteDirectory+"\W3SVC"+$Site.ID
				} 
	             
	            # Create/Add site name and logfile directory to a hash table, then  
	            # feed it into a multi-dimension array 
	            $Properties = @{SiteName=$Site.Name;  
	                            SiteLogFolder=$SiteLogfileDirectory} 
	            $TempObject = New-Object PSObject -Property $Properties 
	            $Targets += $TempObject 
	        } 
	    } 
		ForEach ($Target in $Targets) {
				Get-ChildItem $Target.SiteLogFolder -Recurse -ErrorAction SilentlyContinue | `
			Where-Object { ($_.CreationTime -le $(Get-Date).AddDays(-$Days)) } | `
			Remove-Item -Force -Verbose -Recurse -ErrorAction SilentlyContinue 
		
		}
	} Catch {
		Write-Verbose "IIS: Unable to clean, or IIS not installed."
	}
}

Function Clear-OldProfiles {
	# Clean Profiles that cannot be resolved to a username. (Deleted accounts)
	Param (
		$ProfileList
	)
	$ProfileList = $ProfileList | Where-Object {$_.UserName -eq "Account Unknown"}
	ForEach ($Profile in $ProfileList) {
		Get-WmiObject -Class Win32_UserProfile -filter "SID like '$($Profile.SID)'" | Remove-WmiObject -Verbose
		Write-Host "Removed Old Profile: " $Profile.Path
	}
}

Function Clear-DisabledProfiles {
	# Clean Profiles from disabled accounts
	Param (
		$ProfileList
	)
	$ProfileList = $ProfileList | Where-Object {$_.Disabled -eq $True}
	ForEach ($Profile in $ProfileList) {
		Get-WmiObject -Class Win32_UserProfile -filter "SID like '$($Profile.SID)'" | Remove-WmiObject -Verbose
		Write-Verbose "Removed Disabled User Profile: " $Profile.Path
	}
}

Function Clear-CrashDump {
	# Clean Dump/Minidump files
	
	# Remove DumpFile
	Try {
		$DumpFile = $(Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl\" -ErrorAction SilentlyContinue).DumpFile 
		Remove-Item -Path $DumpFile	-Force -ErrorAction SilentlyContinue
	} Catch {
		Write-Verbose "DumpFile: Unable to clean."
	}
	
	# Remove MiniDumps
	$MiniDumpDir = $(Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl\").MinidumpDir
	Try {
		$MiniDumps = Get-ChildItem -Path $MiniDumpDir -Recurse -ErrorVariable | Out-Null
		$MiniDumps | Remove-Item -Force -Recurse -Verbose -ErrorAction SilentlyContinue
	} Catch {
		Write-Verbose "MiniDumps: Unable to clean."
	}
}

Function Clear-BranchCache {
    Clear-BCCache -Force
    Reset-BC -ResetPerfCountersOnly -Force
}

Function Clear-BrowserCache {
	Param (
		$ProfileList
	)

	# Loops through each user profile in 'C:\Users\' and deletes the browser cache.
	ForEach ($Profile in $ProfileList) {
		Write-Host "Clearing profile $($Profile)."
		#Clear Mozilla Firefox Cache
		Write-Host -ForegroundColor Green "Deleting Mozilla Firefox Caches."
		Write-Host -ForegroundColor Black
		# Creating the profile path variable.
		$Path = Join-Path -Path $Profile.Path -ChildPath "\AppData\Local\Mozilla\Firefox\Profiles\*.default"
		Remove-Item -path "$($Path)\cache\*" -Recurse -Force -EA SilentlyContinue -Verbose
		Remove-Item -path "$($Path)\cache\*.*" -Recurse -Force -EA SilentlyContinue -Verbose
		Remove-Item -path "$($Path)\cache2\entries\*.*" -Recurse -Force -EA SilentlyContinue -Verbose
		Remove-Item -path "$($Path)\thumbnails\*" -Recurse -Force -EA SilentlyContinue -Verbose
		Remove-Item -path "$($Path)\cookies.sqlite" -Recurse -Force -EA SilentlyContinue -Verbose
		Remove-Item -path "$($Path)\webappsstore.sqlite" -Recurse -Force -EA SilentlyContinue -Verbose
		Remove-Item -path "$($Path)\chromeappsstore.sqlite" -Recurse -Force -EA SilentlyContinue -Verbose
		Write-Host -ForegroundColor yellow "Done..."

		# Google Chrome 
		Write-Host -ForegroundColor Green "Deleting Google Chrome Caches."
		Write-Host -ForegroundColor Black
		# Creating the profile path variable.
		$Path = Join-Path -Path $Profile.Path -ChildPath "\AppData\Local\Google\Chrome\User Data\Default"
		Remove-Item -path "$($Path)\Cache\*" -Recurse -Force -EA SilentlyContinue -Verbose
		Remove-Item -path "$($Path)\Cache2\entries\*" -Recurse -Force -EA SilentlyContinue -Verbose
		Remove-Item -path "$($Path)\Cookies" -Recurse -Force -EA SilentlyContinue -Verbose
		Remove-Item -path "$($Path)\Media Cache" -Recurse -Force -EA SilentlyContinue -Verbose
		Remove-Item -path "$($Path)\Cookies-Journal" -Recurse -Force -EA SilentlyContinue -Verbose
		Remove-Item -path "$($Path)\ChromeDWriteFontCache" -Recurse -Force -EA SilentlyContinue -Verbose
		Write-Host -ForegroundColor yellow "Done..."

		# Internet Explorer
	    Write-Host -ForegroundColor Green "Deleting Internet Explorer Caches."
		Write-Host -ForegroundColor Black
		# Creating the profile path variable.
		$Path = Join-Path -Path $Profile.Path -ChildPath "\AppData\Local\"
		Remove-Item -path "$($Path)\Microsoft\Windows\Temporary Internet Files\*" -Recurse -Force -EA SilentlyContinue -Verbose
		Remove-Item -path "$($Path)\Microsoft\Internet Explorer\CacheStorage\*" -Recurse -Force -EA SilentlyContinue -Verbose
		Remove-Item -path "$($Path)\Microsoft\Windows\WER\*" -Recurse -Force -EA SilentlyContinue -Verbose
		Remove-Item -path "$($Path)\Temp\*" -Recurse -Force -EA SilentlyContinue -Verbose
		Write-Host -ForegroundColor yellow "Done..."

		# Microsoft Edge
		Write-Host -ForegroundColor Green "Deleting Microsoft Edge Caches"
		Write-Host -ForegroundColor Black
		# Creating the profile path variable.
		$Path = Join-Path -Path $Profile.Path -ChildPath "\AppData\Local\Microsoft\Edge\User Data\Default"
		Remove-Item -path "$($Path)\*" -Recurse -Force -EA SilentlyContinue -Verbose
		Remove-Item -path "$($Path)\Cache\*" -Recurse -Force -EA SilentlyContinue -Verbose
		Write-Host -ForegroundColor yellow "Done..."

		# Microsoft Cache Locations
		Write-Host -ForegroundColor Green "Deleting Microsoft Cache Locations"
		Write-Host -ForegroundColor Black
		Remove-Item -path "C:\Windows\Temp\*" -Recurse -Force -EA SilentlyContinue -Verbose
		Remove-Item -path "C:\`$recycle.bin\" -Recurse -Force -EA SilentlyContinue -Verbose
		Remove-Item -path "C:\Windows\Downloaded Program Files\*" -Recurse -Force -EA SilentlyContinue -Verbose
		Write-Host -ForegroundColor Green "All Tasks Done!"
	}
}

Function Start-DiskCleanup {
	Write-Verbose 'Clearing CleanMgr.exe automation settings.'
	Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\*' -Name StateFlags0001 -ErrorAction SilentlyContinue | Remove-ItemProperty -Name StateFlags0001 -ErrorAction SilentlyContinue

	Write-Verbose 'Enabling Update Cleanup. This is done automatically in Windows 10 via a scheduled task.'
	New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Update Cleanup' -Name StateFlags0001 -Value 2 -PropertyType DWord

	Write-Verbose 'Enabling Temporary Files Cleanup.'
	New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Temporary Files' -Name StateFlags0001 -Value 2 -PropertyType DWord

	Write-Verbose 'Starting CleanMgr.exe...'
	Start-Process -FilePath CleanMgr.exe -ArgumentList '/sagerun:1' -WindowStyle Hidden -Wait

	Write-Verbose 'Waiting for CleanMgr and DismHost processes. Second wait neccesary as CleanMgr.exe spins off separate processes.'
	Get-Process -Name cleanmgr,dismhost -ErrorAction SilentlyContinue | Wait-Process

	$UpdateCleanupSuccessful = $false

	if (Test-Path $env:SystemRoot\Logs\CBS\DeepClean.log) {
    	$UpdateCleanupSuccessful = Select-String -Path $env:SystemRoot\Logs\CBS\DeepClean.log -Pattern 'Total size of superseded packages:' -Quiet
	}

	if ($UpdateCleanupSuccessful) {
    	Write-Verbose 'Unable to clear the Update Catalog, a reboot is required to complete the cleanup!'
    	#SHUTDOWN.EXE /r /f /t 0 /c 'Rebooting to complete CleanMgr.exe Update Cleanup....'
	}
}

function MainMenu {
	$multiMenuOptions = @(
		Get-InteractiveMultiMenuOption `
			-Item "SCCMCache" `
			-Label "Clear the SCCM Cache." `
			-Order 0 `
			-Info "This clears the SCCM Cache on the machine." `
			-Url ""
		Get-InteractiveMultiMenuOption `
			-Item "Updates" `
			-Label "Clear the Windows Updates." `
			-Order 1 `
			-Info "This clears the Windows Update Cache." `
			-Url ""
		Get-InteractiveMultiMenuOption `
			-Item "OldProfiles" `
			-Label "Clear old user profiles." `
			-Order 2 `
			-Info "This clears the Windows Update Cache." `
			-Url ""
		Get-InteractiveMultiMenuOption `
			-Item "DisabledProfiles" `
			-Label "Clear disabled user profiles." `
			-Order 3 `
			-Info "This clears the disabled user accounts on the machine." `
			-Url ""
		Get-InteractiveMultiMenuOption `
			-Item "SysTemp" `
			-Label "Clear the System Temp Cache." `
			-Order 4 `
			-Info "This clears the System Temp Cache on the machine." `
			-Url ""
		Get-InteractiveMultiMenuOption `
			-Item "UserTemp" `
			-Label "Clear the User Temp Cache." `
			-Order 5 `
			-Info "This clears the User Temp on the machine." `
			-Url ""
		Get-InteractiveMultiMenuOption `
			-Item "IISLogs" `
			-Label "Clear the IIS Logs Cache." `
			-Order 6 `
			-Info "This clears the IIS Logs on the machine." `
			-Url ""
		Get-InteractiveMultiMenuOption `
			-Item "CrashDump" `
			-Label "Clear the Windows Crash Dumps." `
			-Order 7 `
			-Info "This clears the Windows Crash Dumps on the machine." `
			-Url ""
		Get-InteractiveMultiMenuOption `
			-Item "BranchCache" `
			-Label "Clear the Windows Branch Cache." `
			-Order 8 `
			-Info "This clears the Windows Branch Cache on the machine." `
			-Url ""
		Get-InteractiveMultiMenuOption `
			-Item "BrowserCache" `
			-Label "Clear the Browser Cache (Check info for supported browsers)." `
			-Order 9 `
			-Info "This loops through each user profile on the machine, it then clears the browser cache for: Mozilla Firefox, Google Chrome, Microsoft Edge and Internet Explorer." `
			-Url ""
		Get-InteractiveMultiMenuOption `
			-Item "DiskCleanup" `
			-Label "Executes a DiskCleanup on the machine." `
			-Order 10 `
			-Info "Executes a DiskCleanup on the machine and clears all of the temporary files." `
			-Url ""
		Get-InteractiveMultiMenuOption `
			-Item "BrowserCache" `
			-Label "Clear the Browser Cache (Check info for supported browsers)." `
			-Order 11 `
			-Info "This loops through each user profile on the machine, it then clears the browser cache for: Mozilla Firefox, Google Chrome, Microsoft Edge and Internet Explorer." `
			-Url ""
		Get-InteractiveMultiMenuOption `
			-Item "DiskCleanup" `
			-Label "Executes a DiskCleanup on the machine." `
			-Order 12 `
			-Info "Executes a DiskCleanup on the machine and clears all of the temporary files." `
			-Url ""
	)
	
	$options = @{
		HeaderColor = [ConsoleColor]::DarkGreen;
		HelpColor = [ConsoleColor]::Cyan;
		CurrentItemColor = [ConsoleColor]::DarkGreen;
		LinkColor = [ConsoleColor]::DarkCyan;
		CurrentItemLinkColor = [ConsoleColor]::Black;
		MenuDeselected = "[ ]";
		MenuSelected = "[x]";
		MenuCannotSelect = "[/]";
		MenuCannotDeselect = "[!]";
		MenuInfoColor = [ConsoleColor]::DarkYellow;
		MenuErrorColor = [ConsoleColor]::DarkRed;
	}
	Clear-Host
	$header = "::===========================================================================::
::        ######                          #     #                            ::
::        #     #    ##    #####    ##    ##   ##    ##    #  #####          ::
::        #     #   #  #     #     #  #   # # # #   #  #   #  #    #         ::
::        #     #  #    #    #    #    #  #  #  #  #    #  #  #    #         ::
::        #     #  ######    #    ######  #     #  ######  #  #    #         ::
::        #     #  #    #    #    #    #  #     #  #    #  #  #    #         ::
::        ######   #    #    #    #    #  #     #  #    #  #  #####     v2.0 ::
::===========================================================================::"
	$selectedOptions = Get-InteractiveMenuUserSelection -Header $header -Items $multiMenuOptions -Options $options
	ForEach ($option in $selectedOptions) {
		if ($option -eq "SCCMCache")           { Clear-SCCMCache }
		if ($option -eq "Updates")             { Clear-Updates }
		if ($option -eq "OldProfiles")         { Clear-OldProfiles -ProfileList $ProfileList }
		if ($option -eq "DisabledProfiles")    { Clear-DisabledProfiles -ProfileList $ProfileList }
		if ($option -eq "SysTemp")             { Clear-UserTemp -Days $DaysToKeep }
		if ($option -eq "UserTemp")            { Clear-SysTemp -Days $DaysToKeep }
		if ($option -eq "IISLogs")             { Clear-IISLogs -Days $DaysToKeep }
		if ($option -eq "CrashDump")           { Clear-CrashDump }
		if ($option -eq "BranchCache")         { Clear-BranchCache }
		if ($option -eq "BrowserCache")        { Clear-BrowserCache -ProfileList $ProfileList }
		if ($option -eq "DiskCleanup")         { Start-DiskCleanup }
	}
}

########################################################################################################################
# Main
########################################################################################################################
$LogDate = Get-Date -Format "MM-d-yy-HH"
$HostName = $Env:COMPUTERNAME
Start-Transcript -Path "$Env:SystemRoot\Temp\$HostName-$LogDate.log" -ErrorAction SilentlyContinue
$ProfileList = Get-Profiles
$DiskSpaceStart = Get-DiskSpace
Clear-Host

# Run Selected options
Switch (($PSBoundParameters.GetEnumerator() | Where-Object {$_.Value -eq $true}).Key) {
	'SCCM' {
		Clear-SCCMCache
	}
	'Updates' {
		Clear-Updates
	}
	'Recycle' {
		Clear-Recycler
	}
	'SysTemp' {
		Clear-SysTemp -Days $DaysToKeep
	}
	'UserTemp' {
		Clear-UserTemp -Days $DaysToKeep
	}
	'IIS' {
		Clear-IISLogs -Days $DaysToKeep
	}
	'OldProf' {
		Clear-OldProfiles -ProfileList $ProfileList
	}
	'DisProf' {
		Clear-DisabledProfiles -ProfileList $ProfileList
	}
	'CrashDump' {
		Clear-CrashDump
	}
    'BranchCache' {
        Clear-BranchCache
    }
    'BrowserCache' {
        Clear-BrowserCache -ProfileList $ProfileList
    }
    'DiskCleanup' {
        Start-DiskCleanup
    }
	default {
		MainMenu
	}
}
$DiskSpaceEnd = Get-DiskSpace
	
# Write statistics
Write-Host "Machine: $HostName" 
Get-Date | Select-Object DateTime 
Write-Host "Before: $DiskSpaceStart" 
Write-Host "After: $DiskSpaceEnd" 
Stop-Transcript -ErrorAction SilentlyContinue

# Removing the InteractiveMenu Module.
Remove-Module InteractiveMenu