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
    Raid = "Custom25"
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

# ------------------- iDRAC Section ------------------- #
Function Invoke-IDRAC_Request {
    param(
        [string]$Uri,
        [string]$UN,
        [string]$Pass
    )
    $Req = ""
# Nessecary to make request to API with self-signed cert
add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Ssl3, [Net.SecurityProtocolType]::Tls, [Net.SecurityProtocolType]::Tls11, [Net.SecurityProtocolType]::Tls12

    $Headers = @{'Accept'='application/json'}
    $User = $UN
    $PWord = ConvertTo-SecureString -String $Pass -AsPlainText -Force
    $Cred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $User, $PWord
    try{
        $Req = Invoke-RestMethod -Uri $uri -Credential $Cred -Method Get -ContentType 'application/json' -Headers $Headers
    }Catch{
        $Req = 1
    }
    Return $Req
}

<#.DESCRIPTION
Probably a better way to extract the links, but this works.
Casting to string, splitting the string, and trimming to extract
the different sensor links. All because I could not access the "odata.id"
property.
#>
Function Select-Links {
    param(
        $Ldata
    )
    $TempStr = [string]$Ldata
    $TpStrArr = $TempStr.Split("=")
    $TempPartLink = $TpStrArr[1].Trim("}")
    Return $TempPartLink
}

Function Get-SensorInfo {
    $AllSenInfo = @()
    $Sensors = Invoke-IDRAC_Request -Uri $URIS["SenseURI"] -UN $DRAC_UN -Pass $DRAC_Pass
    $SenLinks = $Sensors.Members
    for ($i = 0; $i -lt $SenLinks.Count; $i++) {
        $TempPartLink = Select-Links -Ldata $SenLinks[$i]
        $TempInfo = Invoke-IDRAC_Request -Uri "https://$DRAC_IP$($TempPartLink)" -UN $DRAC_UN -Pass $DRAC_Pass
        $AllSenInfo += $TempInfo
    }
    return $AllSenInfo
}

<#.DESCRIPTION
This function differs a bit from the "Get-SensorInfo" in the way it functions. It needs
to probe a layer deeper for the links to the drives in the raid array.
#>
Function Get-StorageInfo {
    $StorInfo = @{}
    $Allinfo = Invoke-IDRAC_Request -Uri $URIS["MainURI"] -UN $DRAC_UN -Pass $DRAC_Pass
    $RawStorLinks = $Allinfo.Links.Storage
    for ($i = 0; $i -lt $RawStorLinks.Count; $i++) {
        $TempPartLink = Select-Links -Ldata $RawStorLinks[$i]
        $TempInfo = Invoke-IDRAC_Request -Uri "https://$DRAC_IP$($TempPartLink)" -UN $DRAC_UN -Pass $DRAC_Pass
        $StorInfo[$TempInfo.Id] += $TempInfo
    }
    # Checking for RAID array drives in the "StorInfo" hashmap. Then extracting
    # the link information, sending a request using the link info, and adding the
    # disk information fetched from the request to an array. Will be an array of objects.
    $RaidDiskInfo = @()
    foreach($storage in $StorInfo.GetEnumerator()){
        if($storage.Key -like '*RAID*'){
            for($i=0;$i -lt $storage.Value.Drives.Count; $i++) {
                $TmpPtLnk = Select-Links -Ldata $storage.Value.Drives[$i]
                $TempInfo = Invoke-IDRAC_Request -Uri "https://$DRAC_IP$($TmpPtLnk)" -UN $DRAC_UN -Pass $DRAC_Pass
                $RaidDiskInfo += $TempInfo
            }
        }
    }
    # Adding the array containing objects with each disk's info
    # to the parent object containing the rest of the storage info
    $StorInfo['RaidDiskInfo'] = $RaidDiskInfo
    Return $StorInfo
}

<#.DESCRIPTION
This function is meant to select a few properties from each object in the hashmap returned 
from the "Get-StorageInfo" function and return another, smaller, hashmap for the "Publish-MonitorData"
function display in RMM. This function can be changed later to add or remove properties the user would
like to monitor. Right now this only pulls out data about each disk's health in a raid array.
#>
Function Select-StorageData {
    param(
        $StorData
    )
    $StorageMap = @{}
    $TypeChx = $StorData.GetType()
    if($TypeChx.Name -ne "Hashtable"){
        $StorageMap["No_Data"] = "Unable to retrieve iDRAC Data."
        Return $StorageMap
    }
    # Converting key collection to an array to check if passed in data
    # contains the key "RaidDiskInfo" before attempting to parse data.
    $KeyArr = [Array]$StorData.Keys
    if(!$KeyArr.Contains("RaidDiskInfo")){
        $StorageMap["No_Data"] = "Unable to retrieve status of disks in RAID array."
        Return $StorageMap
    }
    for($i=0;$i -lt $StorData.RaidDiskInfo.Count;$i++){
        $TempMap = @{}
        # Extracting portion of name property to create a
        # succint key for the disk in "$StorData"
        $NameArr = $StorData.RaidDiskInfo[$i].Name.Split()
        $NameDigis = $NameArr[$NameArr.Count - 1].Split(":")
        $NewKey = "Disk$($NameDigis[2])_Array$($NameDigis[1])"
        $TempMap["FailurePredicted"] = $StorData.RaidDiskInfo[$i].FailurePredicted
        $TempMap["FailurePredicted"] = $StorData.RaidDiskInfo[$i].FailurePredicted
        $TempMap["Health"] = $StorData.RaidDiskInfo[$i].Status.Health
        $StorageMap[$NewKey] = $TempMap
    }

    Return $StorageMap
}

Function Convert-iDracData {
    param(
        $Data
    )
    $SenseTable = @{}
    # Checking type to avoid errors
    $Type0 = $Data.GetType()
    $Type1 = $Type0.BaseType.Name
    if($Type1 -eq "Array"){
        # Converting array of table data into a hashtable of table data. Selecting
        # a few prefered fields, combinding some of them, and adding that data to a smaller table.
        # Then, using the "Name" data to create a key in "SenseTable", assigning that smaller table
        # to an appropriately named key in "SenseTable". 
        for($i=0;$i -lt $Data.Count;$i++){
            $TempTable = @{}
            $TempTable["Reading"] = "$($Data[$i].Reading)  $($Data[$i].ReadingUnits)"
            $TempTable["Status"] = $Data[$i].Status
            $SenseTable[$Data[$i].Name] = $TempTable
        }
    }else{
        $SenseTable["No_Data"] = "Unable to retrieve iDRAC Data."
    }
    Return $SenseTable
}

# Meant to extract sensors reading and convert it to an int to compare against
# limits set.
Function Select-Reading {
    param (
        [string]$Read
    )
    $ReadArr = $Read.Split()
    $ReadDecArr = $ReadArr[0].Split(".")
    $ReadInt = [int32]$ReadDecArr[0]
    Return $ReadInt
}

<#.DESCRIPTION
This function will display alert and UDF information in the RMM console from the parsed iDrac sensor data from "Convert-iDracData" and the
OpenManage status data returned from "Publish-OMData". The "Publish-OMData" will handle populating the OpenManage status UDF in the RMM console, 
but this function will handle the rest.
#>
Function Publish-MonitorData {
    param(
        [Hashtable]$Sense_Data,
        [Hashtable]$Stor_Data,
        [String]$Path,
        [Int32]$TmpLim,
        [Int32]$WttLim,
        [Hashtable]$OM_Alert,
        [Hashtable]$Fields
    )
    $Alert = $False
    $No_Data = $False
    $DisplayStatus = ""
    # Need to check if iDrac was able to return data by looking for "No_Data" key.
    # No alert will be raised or display string will be created if data was not retrieved from iDrac, but a message
    # will be displayed to the RMM console to inform the tech.
    foreach ($status in $Sense_Data.GetEnumerator()) {
        if($status.Key -eq "No_Data"){
            $No_Data = $True
            $DisplayStatus = $status.Value
            break
        }
    }
    # Only applicable if data was retrieved from iDRAC
    if($No_Data -eq $False){
        # 
        foreach ($sensor in $Sense_Data.GetEnumerator()) {
            # If any temp reading goes over 70 celcius, raise an alert.
            if($sensor.Key -like '*Temp*'){
                # Extracting and casting temp reading to integer
                $ReadInt = Select-Reading -Read $sensor.Value.Reading
                if($ReadInt -gt $TmpLim){
                    $Alert = $True
                }
            # Will raise an alert if a fan has stopped.
            }elseif ($sensor.Key -like '*Fan*') {
                # Extracting and casting Fan RPM reading to integer
                $RPMInt = Select-Reading -Read $sensor.Value.Reading
                if($RPMInt -le 0){
                    $Alert = $True
                }
            
            }elseif ($sensor.Key -like '*Voltage*') {
                # Extracting and casting total system wattage usage into integer
                $VolInt = Select-Reading -Read $sensor.Value.Reading
                if($VolInt -le 0){
                    $Alert = $True
                }
            # Will raise an alert if power consumption exceeds set limit or falls to 0.
            }elseif ($sensor.Key -like '*Consumption*') {
                # Extracting and casting total system wattage usage into integer
                $ComInt = Select-Reading -Read $sensor.Value.Reading
                if(($ComInt -gt $WttLim) -or ($ComInt -eq 0)){
                    $Alert = $True
                }
            }
        }
        
        # Two different display strings are needed for the RMM console. One will be used to 
        # populate a UDF for a specific reading (like Fan or Temperature readings). While another
        # string will be used to provide information to the RMM monitor. The RMM monitor string will
        # contain all the readings.
        $FanString = ""
        $TempString = ""
        $PowerString = ""
        $VoltString = ""
        foreach ($sensor in $Sense_Data.GetEnumerator()) {
            if($sensor.Key -like '*Temp*'){
                $TempString += "$($sensor.Key): $($sensor.Value.Reading); "
                $DisplayStatus += "$($sensor.Key): $($sensor.Value.Reading); "
            }elseif ($sensor.Key -like '*Fan*') {
                $FanString += "$($sensor.Key): $($sensor.Value.Reading); "
                $DisplayStatus += "$($sensor.Key): $($sensor.Value.Reading); "
            }elseif ($sensor.Key -like '*Voltage*') {
                $VoltString += "$($sensor.Key): $($sensor.Value.Reading); "
                $DisplayStatus += "$($sensor.Key): $($sensor.Value.Reading); "
            }elseif ($sensor.Key -like '*Consumption*') {
                $PowerString += "$($sensor.Key): $($sensor.Value.Reading); "
                $DisplayStatus += "$($sensor.Key): $($sensor.Value.Reading); "
            }
        }
        Set-RMMStatus -Path $Path -Status "$FanString $(Get-Date)" -UDF $Fields["Fan"]
        Set-RMMStatus -Path $Path -Status "$TempString  $(Get-Date)" -UDF $Fields["Temp"]
        Set-RMMStatus -Path $Path -Status "$PowerString $(Get-Date)" -UDF $Fields["Power"]
        Set-RMMStatus -Path $Path -Status "$VoltString $(Get-Date)" -UDF $Fields["Voltage"]
    }

    # Checking and parsing storage/RAID data before passing on to RMM
    # Will continue to use the "Alert" variable as the storage status
    # is pulled from iDRAC.
    $No_Stor = $False
    $StorString = ""
    foreach ($stat in $Stor_Data.GetEnumerator()) {
        if($status.Key -eq "No_Data"){
            $No_Stor = $True
            $DisplayStatus += $stat.Value
            break
        }
    }
    # Checking if an alert needs to be raised and creating display string for storage status
    # after confirming above that data was retrieved.
    if($No_Stor -eq $False){
        foreach ($disk in $Stor_Data.GetEnumerator()) {
            if(($disk.Value.FailurePredicted) -or ($disk.Value.Health -ne "OK")){
                $Alert = $True
            }
            $StorString += "$($disk.Key): FailurePredicted=$($disk.Value.FailurePredicted),Health=$($disk.Value.Health); "
            $DisplayStatus += "$($disk.Key): FailurePredicted=$($disk.Value.FailurePredicted),Health=$($disk.Value.Health); "
        }
    }
    Set-RMMStatus -Path $Path -Status "$StorString $(Get-Date)" -UDF $Fields["Raid"]

    # If no alert is raised after checking OpenManage and iDrac.
    if(($Alert -eq $False) -and ($OM_Alert["Status"] -eq $False)){
        Write-Host '<-Start Result->'
        Write-Host "STATUS=$DisplayStatus $(Get-Date)"
        Write-Host '<-End Result->'
        #Exit 0
    # If an alert was raised after checking OpenManage data, but NO alearts were raised after checking iDRAC sensor data.
    }elseif(($Alert -eq $False) -and ($OM_Alert["Status"])){
        Write-Host '<-Start Result->'
        Write-Host "STATUS=WARNING! OpenManage Has Detected a bad status! $($OM_Alert["Message"]) $(Get-Date)"
        Write-Host '<-End Result->'
        #Exit 1
    # If an alert was raised after checking iDRAC sensor data data, but NO alearts were raised after checking OpenManage data.
    }elseif(($Alert) -and ($OM_Alert["Status"] -eq $False)){
        Write-Host '<-Start Result->'
        Write-Host "STATUS=WARNING! iDRAC sensor data has triggered an alert! $DisplayStatus $(Get-Date)"
        Write-Host '<-End Result->'
        #Exit 1
    # If an alert was raised after checking iDRAC sensor data and an alert was raised after checking OpenManage data.
    }elseif(($Alert) -and ($OM_Alert["Status"])){
        Write-Host '<-Start Result->'
        Write-Host "STATUS=WARNING! Alerts raised by both iDRAC and OpenManage $DisplayStatus || $($OM_Alert["Message"]) $(Get-Date)"
        Write-Host '<-End Result->'
        #Exit 1
    }else{
        Write-Host '<-Start Result->'
        Write-Host "STATUS=Unknown error. Check UDF output in RMM console."
        Write-Host '<-End Result->'
        #Exit 1
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
This function is mostly meant to confirm usable data was returned from the
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

$OpenData = Get-OpenMRep -OMDir $OpenM_Dir
$OM_Table = Convert-OMData -Data $OpenData
# When calling "Set-RMMStatus" in "Publish-OMData", the ouput is added to the returnable and the "Alert" hashtable needs to be selected
$OM_Returned = Publish-OMData -Data $OM_Table -UDF $OpenManageUDF -Path $RMM_Reg_Path
$OM_Alert = $OM_Returned[1]

# Fetching Storage Status Data
$RawStorData = Get-StorageInfo
$StorMap = Select-StorageData -StorData $RawStorData

$SensorData = Get-SensorInfo
$SensorMap = Convert-iDracData -Data $SensorData
Publish-MonitorData -Sense_Data $SensorMap -Stor_Data $StorMap -Path $RMM_Reg_Path -TmpLim $TempLimit -WttLim $WattLimit -OM_Alert $OM_Alert -Fields $DRAC_UDFS

# Variable Cleanup
Clear-Variable -Name "DRAC_IP"
Remove-Variable -Name DRAC_IP
Clear-Variable -Name "DRAC_UN"
Remove-Variable -Name DRAC_UN
Clear-Variable -Name "DRAC_Pass"
Remove-Variable -Name DRAC_Pass
[Environment]::SetEnvironmentVariable("Site_DRAC_UN",$null,"User")
Remove-Item Env:\Site_DRAC_IP
[Environment]::SetEnvironmentVariable("Site_DRAC_UN",$null,"User")
Remove-Item Env:\Site_DRAC_UN
[Environment]::SetEnvironmentVariable("Site_DRAC_PW",$null,"User")
Remove-Item Env:\Site_DRAC_PW