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