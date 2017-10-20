# Some modifications Copyright (c) 2017 BlackBerry Limited
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Backwards compatible context script for use with Unattend.xml-style faster contextualization.
# This allows user-provided scripts to be run in the same manner that they currently are.
# The user creation part should probably move to Unattend.xml eventually.
#
# Author: Paul Batchelor
# based on: https://github.com/OpenNebula/addon-context-windows/blob/master/context.ps1
# -------------------------------------------------------------------------- #
# Copyright 2002-2014, OpenNebula Project (OpenNebula.org), C12G Labs        #
#                                                                            #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    #
# not use this file except in compliance with the License. You may obtain    #
# a copy of the License at                                                   #
#                                                                            #
# http://www.apache.org/licenses/LICENSE-2.0                                 #
#                                                                            #
# Unless required by applicable law or agreed to in writing, software        #
# distributed under the License is distributed on an "AS IS" BASIS,          #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   #
# See the License for the specific language governing permissions and        #
# limitations under the License.                                             #
#--------------------------------------------------------------------------- #

# Original work by:

#################################################################
##### Windows Powershell Script to configure OpenNebula VMs #####
#####   Created by andremonteiro@ua.pt and tsbatista@ua.pt  #####
#####        DETI/IEETA Universidade de Aveiro 2011         #####
#################################################################

$debug = $false

if ($debug)
    {
        if (-not (test-path c:\temp)) { mkdir c:\temp }
        Start-Transcript c:\temp\context-transcript.txt
    }

Set-ExecutionPolicy unrestricted -force # not needed if already done once on the VM
[string]$computerName = "$env:computername"
[string]$ConnectionString = "WinNT://$computerName"

function getContext($file) {
    $context = @{}
    switch -regex -file $file {
        "^([^=]+)='(.+?)'$" {
            $name, $value = $matches[1..2]
            $context[$name] = $value
        }
    }
    return $context
}

function initializeLogging()
    # Create a new log source for our messages if it doesn't already exist. We use the System event log
    {
        $log = Get-EventLog -list | where { $_.Log -eq 'System' }
        if (-not [System.Diagnostics.EventLog]::SourceExists( "Context", "." ))
            {
                [System.Diagnostics.EventLog]::CreateEventSource( "Context", "System" )
            }
        $log.Source = "Context"

        return $log
    }

function disableAutoLogon()
    {
        set-itemproperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name AutoAdminLogon -value 0
    }



function addLocalUser($context) {
    # Create new user
    $username =  $context["USERNAME"]
    $password =  $context["PASSWORD"]

    if ( ($username -ne $null) -and ($password -ne $null) )
      {
        # Only try to create a user if one is specified in the context.
        $Eventlog.WriteEvent(("Creating local user - " + $username), "Information" )
        $ADSI = [adsi]$ConnectionString

        if(!([ADSI]::Exists("WinNT://$computerName/$username"))) {
           $user = $ADSI.Create("user",$username)
           $user.setPassword($password)
           $user.SetInfo()
        }
        # Already exists, change password
        else{
           $admin = [ADSI]"WinNT://$env:computername/$username"
           $admin.psbase.invoke("SetPassword", $password)
        }

        # Set Password to Never Expires
        $admin = [ADSI]"WinNT://$env:computername/$username"
        $admin.UserFlags.value = $admin.UserFlags.value -bor 0x10000
        $admin.CommitChanges()

        # Add user to local Administrators
        # ATTENTION - language/regional settings have influence on this group, "Administrators" fits for English
        $groups = "Administrators"
        $groups = (Get-WmiObject -Class "Win32_Group" | where { $_.SID -like "S-1-5-32-544" } | select -ExpandProperty Name)

        foreach ($grp in $groups) {
        if([ADSI]::Exists("WinNT://$computerName/$grp,group")) {
                $group = [ADSI] "WinNT://$computerName/$grp,group"
                if([ADSI]::Exists("WinNT://$computerName/$username")) {
                     $group.Add("WinNT://$computerName/$username")
                        }
                }
            }
        }
    }


function runScripts($context, $contextLetter)
{
    # Execute
    $initscripts = $context["INIT_SCRIPTS"]

    if ($initscripts) {
        foreach ($script in $initscripts.split(" ")) {
            $script = $contextLetter + $script
            if (Test-Path $script) {
                $Eventlog.WriteEntry(("Running context script " + $script), "Information")
                & $script
                if ($LASTEXITCODE -ne 0) {
                   $Eventlog.WriteEntry(($script + " returned error code " + $LASTEXITCODE), "Warning" )
                }
            }
        }
    }
}


$Eventlog = initializeLogging

# Get all drives and select only the one that has "CONTEXT" as a label
$contextDrive = Get-WMIObject Win32_Volume | ? { $_.Label -eq "CONTEXT" }

# Return if no CONTEXT drive found
if ($contextDrive -eq $null) {
    $vmwareContext = & "c:\Program Files\VMware\VMware Tools\vmtoolsd.exe" --cmd "info-get guestinfo.opennebula.context" | Out-String

    if ($vmwareContext -eq "") {
        Write-Host "No Context CDROM found."
        $EventLog.WriteEntry("No Context CDROM found.", "Error" )
        exit 1
    }

    [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($vmwareContext)) | Out-File "C:\context.sh" "UTF8"
    $contextDrive = "C:"
}

# At this point we can obtain the letter of the contextDrive
$contextLetter     = $contextDrive.Name
$contextScriptPath = $contextLetter + "context.sh"

# Execute script
if(Test-Path $contextScriptPath) {
    $context = getContext $contextScriptPath

    addLocalUser $context
    runScripts $context $contextLetter
    disableAutoLogon
}

if ($debug)
  {
     Stop-Transcript
  }
