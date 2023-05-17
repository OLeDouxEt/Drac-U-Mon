<#.SYNOPSIS
This script is meant to collect data from the Dell OpenManage program and the iDrac management platform.
It will then parse this data, extract important information, pass this information on to the Datto RMM console, and
raise an alert there is a bad hardware status or sensor is above or below a limit.
#>
# Variables pulled from Site settings in Datto RMM
$DRAC_IP = $env:Site_DRAC_IP
$DRAC_UN = $env:Site_DRAC_UN
$DRAC_Pass = $env:Site_DRAC_PW
# Directory that contains Dell Openmanage reporting executable
$OpenM_Dir = "C:\Program Files\Dell\SysMgt\oma\bin"
$RMM_Reg_Path = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\CentraStage"
$OpenManageUDF = "Custom30"
$DRAC_UDFS = @{
    Fan = "Custom26";
    Temp = "Custom27";
    Power = "Custom28";
    Voltage = "Custom29"
}
$TempLimit = 70
$WattLimit = 500
$URIS = @{
    MainURI = "https://$DRAC_IP/redfish/v1/Chassis/System.Embedded.1";
    SenseURI = "https://$DRAC_IP/redfish/v1/Chassis/System.Embedded.1/Sensors";
    PowerURI = "https://$DRAC_IP/redfish/v1/Chassis/System.Embedded.1/Power";
    ThermURI = "https://$DRAC_IP/redfish/v1/Chassis/System.Embedded.1/Thermal";
    MemURI = "https://$DRAC_IP/redfish/v1/Systems/System.Embedded.1/Memory";
    FansURI = "https://$DRAC_IP/redfish/v1/Chassis/System.Embedded.1/Thermal#/Fans/0"
}

# Used to update UDF data for RMM console
Function Set-RMMStatus {
    param(
        [string]$Path,
        [string]$Status,
        [string]$UDF
    )
    
    try{
        New-ItemProperty -Path $Path -Name $UDF -Value $Status -PropertyType String -ErrorAction Stop
    }catch{
        Set-ItemProperty -Path $Path -Name $UDF -Value $Status
    }
}

# ------------------- OpenManage Section ------------------- #

Function Get-OpenMRep {
    param(
        [string]$OMDir
    )
    Set-Location $OMDir
    $report = .\omreport.exe chassis
    return $report
}

<#.DESCRIPTION
This function is mostly meant to confirm useable data was returned from the
"Get-OpenMRep" function and convert it into a hashtable to make it easier to
check for alerts in the "Publish-OMData" function.
#>
Function Convert-OMData {
    param(
        $Data
    )
    $Returnable = @{}
    # Checking type to avoid errors
    $Type1 = $Data.GetType()
    $Type2 = $Type1.BaseType.Name
    if($Type2 -eq "Array"){
        # Relevant information begins at index 5
        for ($i = 5; $i -lt 15; $i++) {
            $TempArr = $Data[$i].Split(":")
            $Val = $TempArr[0].Trim()
            $Key = $TempArr[1].Trim()
            $Returnable[$key] = $Val
        }
    }else{
        $Returnable["No_Data"] = "Unable to retrieve OpenManage Data."
    }
    Return $Returnable
}

<#.DESCRIPTION
This function will check for any status that is not "Ok" and raise an alert. alert and status information
will be returned and used in "Publish-MonitorData". It will also publish all the status data to the RMM
console under a UDF field.
#>
Function Publish-OMData {
    param(
        $Data,
        [String]$UDF,
        [String]$Path
    )
    $Alert = @{
        Status = $False;
        Message = ""
    }
    $No_Data = $False
    $DisplayStatus = ""
    # Need to check if OpenManage was able to return data by looking for "No_Data" key.
    # No alert will be raised or display string will be created if data was not retrieved from OpenManage.
    foreach ($status in $Data.GetEnumerator()) {
        if($status.Key -eq "No_Data"){
            $No_Data = $True
            $DisplayStatus = $status.Value
            break
        }
    }
    if($No_Data -eq $False){
        # Checking the status for each status reading and raising an alert to display
        # in the RMM console.
        foreach ($status in $Data.GetEnumerator()) {
            if($status.Value -ne "Ok"){
                $Alert["Status"] = $True
            }
        }
        # Converting OpenManage data into a string to display to RMM console.
        foreach ($status in $Data.GetEnumerator()) {
            $DisplayStatus += "$($status.Key): $($status.Value); "
        }
    }
    $Alert["Message"] = $DisplayStatus
    Set-RMMStatus -Path $Path -Status "$DisplayStatus $(Get-Date)" -UDF $UDF
    Return $Alert
}