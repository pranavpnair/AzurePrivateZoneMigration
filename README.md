# MigratePrivateZones.ps1

Script migrates all Private DNS zones from old to new model. Virtual Network links from old model are replaced with VirtualNetworkLink 
subresource in Private DNS zones with link name as resourcegroupname-virtualnetworkname-link.


Usage instructions: 

Script needs Az.PrivateDns module. Please install this using the command 

Install-Module -Name Az.PrivateDns -AllowPrerelease -AllowClobber


Please run the script using the following command,

.\PrivateDnsMigrationScript.ps1 -SubscriptionId <string> [-DumpPath <string>] [ -Force]
Please note that DumpPath and Force are optional parameters.

Default DumpPath location: “%Temp%\PrivateZoneData\”
Force parameter is only used if the customer has filed a support request to increase subscription limits (for example increase number of private zones limit/number of recordset count limits in a zone), this support request has been processed and the customer re-runs the script. During this re-run, force parameter needs to be passed.

Examples: 
.\PrivateDnsMigrationScript.ps1 -SubscriptionId 56c5cf70-f5b3-4315-a275-7da7cc9c3512 -DumpPath "C:\PrivateZoneData" -Force
.\PrivateDnsMigrationScript.ps1 -SubscriptionId 56c5cf70-f5b3-4315-a275-7da7cc9c3512
