# AzurePrivateZoneMigration.ps1

Run the script by passing in subscription id as parameter.

Script migrates all Private DNS zones from old to new model. Virtual Network links from old model are replaced with VirtualNetworkLink 
subresource in Private DNS zones with link name as resourcegroupname-virtualnetworkname-link.
