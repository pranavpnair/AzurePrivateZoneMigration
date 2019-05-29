
<#PSScriptInfo

.VERSION 1.3

.GUID 98d9382c-262f-49a3-8e73-2026f85e82b2

.AUTHOR prannair

.COMPANYNAME Microsoft

.COPYRIGHT (c) Microsoft Corporation.  All rights reserved.

#>

<# 

.DESCRIPTION 
The script migrates Private DNS zones from legacy model to the new model under a given Azure Subscription.

 <PARAMETERS>
 SubsciptionId: (Mandatory) Enter the subscription ID where the migration of Private DNS zones from legacy to new model needs to happen. 
 DumpPath: (Not Mandatory) Enter the dump location that this script will use to dump Private DNS zone data. 
 ResourceGroupName: (Not Mandatory) Enter the resource group containing the zones you wish to migrate.
 PrivateZoneName: (Not Mandatory) Enter the private zone you wish to migrate.
 Force: (Not Mandatory) Switch parameter, please use this is you have filed a support request and subscription limits have been already increased.

#> 

param(
    [Parameter(Mandatory=$true)] [ValidateNotNullOrEmpty()] [string] $SubscriptionId,
    [Parameter(Mandatory=$false)] [ValidateNotNullOrEmpty()] [string] $DumpPath = "$env:temp\PrivateZoneData",
    [Parameter(Mandatory=$false)] [ValidateNotNullOrEmpty()] [string] $ResourceGroupName,
    [Parameter(Mandatory=$false)] [ValidateNotNullOrEmpty()] [string] $PrivateZoneName,
    [Parameter(Mandatory=$false)] [switch] $Force
)

$ErrorActionPreference = "Stop"

Import-Module Az.Dns
Import-Module Az.PrivateDns

$helpmsg = '''
Y - Continue with only the next step of the operation.
A - Continue with all the steps of the operation.
N - Skip this operation and proceed with the next operation.
L - Skip this operation and all subsequent operations.
S - Pause the current pipeline.'''

$choice = @('L','l','a','A','n','N','y','Y')

function MigrateAllPrivateZones($privateZones)
{
    <#
    .SYNOPSIS
     Auxiliary function to migrate all Private DNS zones in a subscription.
    .PARAMETER privateZones
     Specifies the Private DNS zone list. 
    #>

    foreach($privateZone in $privateZones)
    {
        MigrateSinglePrivateZone($privateZone)
    }
}

function DeleteAllPrivateZones($privateZones)
{
    <#
    .SYNOPSIS
     Auxiliary function to delete all Private DNS zones in a subscription.
    .PARAMETER privateZones
     Specifies the Private DNS zone list. 
    #>

    foreach($privateZone in $privateZones)
    {
        DeleteSinglePrivateZone($privateZone)
    }
}

function CreateRecordConfig($recordSet)
{
    <#
    .SYNOPSIS
     Function that creates a record list of a particular type within a recordSet. Used to create RecordSets in the new Private DNS zone that will be created.
    .PARAMETER recordSet
     Specifies the recordSet that has the record data.
    #>

    $oldRecords = $recordSet.Records
    $newRecords = @()
    switch($recordSet.RecordType)
    {
        'A' { 
                foreach($oldrecord in $oldRecords)
                {
                    $newRecords += New-AzPrivateDnsRecordConfig -IPv4Address $oldRecord.IPv4Address
                }
                break
            }
        'AAAA' {
                foreach($oldrecord in $oldRecords)
                {
                    $newRecords += New-AzPrivateDnsRecordConfig -IPv6Address $oldRecord.IPv6Address
                }
                break
            }
        'MX' {
                foreach($oldrecord in $oldRecords)
                {
                    $newRecords += New-AzPrivateDnsRecordConfig -Exchange $oldRecord.Exchange -Preference $oldRecord.Preference
                }
                break
            }
        'PTR' {
                foreach($oldrecord in $oldRecords)
                {
                    $newRecords += New-AzPrivateDnsRecordConfig -Ptrdname $oldRecord.Ptrdname
                }
                break
            }
        'TXT' {
                foreach($oldrecord in $oldRecords)
                {
                    $newRecords += New-AzPrivateDnsRecordConfig -Value $oldRecord.Value
                }
                break
            }
        'SRV' {
                foreach($oldrecord in $oldRecords)
                {
                    $newRecords += New-AzPrivateDnsRecordConfig -Priority $oldRecord.Priority -Weight $oldRecord.Weight -Port $oldRecord.Port -Target $oldRecord.Target 
                }
                break
            }
        'CNAME' {
                foreach($oldrecord in $oldRecords)
                {
                    $newRecords += New-AzPrivateDnsRecordConfig -Cname $oldRecord.Cname
                }
                break
            }
    }

    return $newRecords
}

function CreateRecordSets($privateZone, $migratedZone)
{
    <#
    .SYNOPSIS
     Function to create record sets in a Private DNS zone.
    .PARAMETER privateZone
     Specifies the Private DNS zone under which the record sets will be created.
    #>

    Write-Host "Attempting migration of RecordSets in the Private DNS zone $($privateZone.Name)...`n"
    $recordSets = Get-AzDnsRecordSet -ZoneName $privateZone.Name -ResourceGroupName $privateZone.ResourceGroupName
    $fileName = "$($privateZone.ResourceGroupName)-$($privateZone.Name)-recordSets.txt"
    $recordSets | Out-File -FilePath "$DumpPath/$fileName"

    foreach($recordSet in $recordSets)
    {   
        $existingRecordSet = Get-AzPrivateDnsRecordSet -Zone $migratedZone -Name $recordSet.Name -RecordType $recordSet.RecordType.ToString() -ErrorVariable notPresent -ErrorAction SilentlyContinue
        if($recordSet.RecordType.ToString() -eq 'SOA')
        {
            $existingRecordSet.Metadata = $recordSet.Metadata
            $existingRecordSet.Ttl = $recordSet.Ttl
            $existingRecordSet.Records[0].Host = $recordSet.Records[0].Host
            $existingRecordSet.Records[0].Email = $recordSet.Records[0].Email
            $existingRecordSet.Records[0].SerialNumber = $recordSet.Records[0].SerialNumber
            $existingRecordSet.Records[0].RefreshTime = $recordSet.Records[0].RefreshTime
            $existingRecordSet.Records[0].RetryTime = $recordSet.Records[0].RetryTime
            $existingRecordSet.Records[0].ExpireTime = $recordSet.Records[0].ExpireTime
            $existingRecordSet.Records[0].MinimumTtl = $recordSet.Records[0].MinimumTtl
            Set-AzPrivateDnsRecordSet -RecordSet $existingRecordSet
            continue
        }

        if([string]::IsNullOrEmpty($notPresent))
        {
            do {
                Write-Host -ForegroundColor Yellow "RecordSet $($recordSet.Name) already exists in the Private DNS Zone. Do you still want to overwrite this recordset to match legacy data? [Y/N]`n"
                $input = Read-Host
                if($input -like 'N')
                {
                    continue
                }
                elseif($input -like 'Y')
                {
                    $existingRecordSet.Ttl = $recordSet.Ttl
                    $existingRecordSet.Metadata = $recordSet.Metadata
                    $existingRecordSet.Records = CreateRecordConfig $recordSet
                    Set-AzPrivateDnsRecordSet -RecordSet $existingRecordSet
                    Write-Host "Overwrite of RecordSet $($RecordSet.Name) was successful.`n"
                }

            } until($input -like 'Y' -or $input -like 'N')
        }
        else
        {
            $recordConfig = CreateRecordConfig $recordSet
            if($recordConfig)
            {
                New-AzPrivateDnsRecordSet -Name $recordSet.Name -Zone $migratedZone -RecordType $recordSet.RecordType.ToString() -Ttl $recordSet.Ttl -PrivateDnsRecord $recordConfig -Metadata $recordSet.Metadata
            }
            else
            {
                New-AzPrivateDnsRecordSet -Name $recordSet.Name -Zone $migratedZone -RecordType $recordSet.RecordType.ToString() -Ttl $recordSet.Ttl -Metadata $recordSet.Metadata
            }
            
            Write-Host "Created new RecordSet $($recordSet.Name) under Private DNS Zone $($migratedZone.Name)`n"
        }
    }
}

function MigrateSinglePrivateZone($privateZone)
{
    <#
    .SYNOPSIS
     Function to migrate a single Private DNS zone from legacy to new model.
    .PARAMETER privateZones
     Specifies the Private DNS zone object to be migrated.
    #>

    Write-Host "Attempting to migrate Private DNS zone $($privateZone.Name) in resource group $($privateZone.ResourceGroupName)"
    $totalLinks = $privateZone.ResolutionVirtualNetworkIds.Count + $privateZone.RegistrationVirtualNetworkIds.Count
    if($privateZone.NumberOfRecordSets -gt 25000 -or $totalLinks -gt 1000 -or $privateZone.RegistrationVirtualNetworkIds.Count -gt 100)
    {
        if(!$Force.IsPresent)
        {
            Write-Error "Number of recordsets on this private zone = $($privateZone.NumberOfRecordSets). Total number of virtual network links on this private zone = $($totalLinks) .Number of registration virtual network Ids on this private zone = $($privateZone.ResolutionVirtualNetworkIds.Count). These values are higher than normal limits of 25000, 1000 and 100 respectively. Please file a support request to migrate subscription limits and re-run the script with Force parameter.`n"
            Exit
        }
        else 
        {
            Write-Warning "Number of recordsets on this private zone = $($privateZone.NumberOfRecordSets). Total number of virtual network links on this private zone = $($totalLinks) .Number of registration virtual network Ids on this private zone = $($privateZone.ResolutionVirtualNetworkIds.Count). These values are higher than normal limits of 25000, 1000 and 100 respectively. Force attempting migration...`n"  
        }
    }

    Write-Host "Attempting to migrate new Private DNS Zone $($privateZone.Name) and migrating corresponding RecordSets from the old model...`n"

    $migratedZone = Get-AzPrivateDnsZone -ResourceGroupName $privateZone.ResourceGroupName -Name $privateZone.Name -ErrorVariable notPresent -ErrorAction SilentlyContinue
    if($notPresent)
    {
        $migratedZone = New-AzPrivateDnsZone -Name $privateZone.Name -ResourceGroupName $privateZone.ResourceGroupName -Tag $privateZone.Tags
    }
    else
    {
        $tagCheck = Compare-Object $migratedZone.Tags $privateZone.Tags
        if($null -eq $tagCheck)
        {
            Write-Host "Private DNS Zone $($privateZone.Name) already exists.`n"
        }
        else 
        {
            do{
                Write-Host -ForegroundColor Yellow  "Private DNS Zone $($privateZone.Name) already exists but tags do not match with legacy zone. Do you want to overwrite the tags with legacy data? [Y/N]`n"
                $input = Read-Host
                if($input -like 'N')
                {
                    continue
                }
                elseif($input -like 'Y')
                {    
                    $migratedZone.Tags = $privateZone.Tags
                    Set-AzPrivateDnsZone -Zone $migratedZone
                }
            } until($input -like 'Y' -or $input -like 'N')

        }
    }

    CreateRecordSets $privateZone $migratedZone
    CreateVirtualNetworkLinks $privateZone
    Write-Host "Migration of Private DNS Zone $($privateZone.Name) and its RecordSets under resource group $($privateZone.ResourceGroup) completed successfully.`n"
}

function DeleteSinglePrivateZone($privateZone)
{
    <#
    .SYNOPSIS
     Function to delete a single Private DNS zone.
    .PARAMETER privateZone
     Specifies the Private DNS zone to be deleted.
    #>

    $privateZone = Get-AzDnsZone -Name $privateZone.Name -ResourceGroupName $privateZone.ResourceGroupName
    Remove-AzDnsZone -Zone $privateZone -Confirm:$false
    Write-Host "Successfully deleted Private DNS Zone $($privateZone.Name) after migration to new model.`n"
}

function CreateVirtualNetworkLinkName($vnetId)
{
    <#
    .SYNOPSIS
     Function that defines the name of a new virtual network link. Name format is <ResourceGroupName-Virtualnetwork-Link>.
    .PARAMETER vnetId
     Specifies the virtual network id that will be associated with the new virtual network link.
    .PARAMETER isRegistration
     Boolean that specifies if the virtual network link is registration or not.
    #>

    try 
    {
        $vnetId = $vnetId.ToLower()
        return $vnetId.Split('/')[4] + "-" + $vnetId.Split('/')[-1] + "-link" 
    }
    catch 
    {
        Write-Error "Exception while parsing virtual network id: $vnetId. Please check the virtual network id provided and try again.`n"
    }
}

function CreateVirtualNetworkLinks($privateZone)
{
    <#
    .SYNOPSIS
     Function to create virtual network links in a Private DNS zone.
    .PARAMETER privateZone
     Specifies the Private DNS zone under which the virtual network links will be created.
    #>

    Write-Host "Creating VirtualNetwork Links for all resolution and registration virtual networks in the private zone: $($privateZone.Name) under resource group $($privateZone.ResourceGroupName)"

    $registrationVnetIds = $privateZone.RegistrationVirtualNetworkIds
    foreach($vnetId in $registrationVnetIds)
    {
        $linkName = CreateVirtualNetworkLinkName $vnetId
        Write-Host "Creating Registration VirtualNetwork Link with link name: $linkName for the following virtual network:$vnetId ...`n"
        $existingVnetLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $privateZone.ResourceGroupName -Name $linkName -ZoneName $privateZone.Name -ErrorAction SilentlyContinue
        if($existingVnetLink)
        {
            if($existingVnetLink.RegistrationEnabled -eq $true -and $existingVnetLink.VirtualNetworkId -like $vnetId)
            {
                Write-Host "Virtual network Link $linkName is already present in the Private DNS Zone $($privateZone.Name).`n"
                continue
            }
            else
            {
                do{
                    Write-Output $existingVnetLink
                    Write-Host -ForegroundColor Yellow "Registration virtual network link with the same name already exists in this Private DNS zone, but it does not have the same properties as the link from legacy zone. Do you want to overwrite this virtual network link with legacy data?[Y/N]"
                    $confirm = Read-Host
                    if($confirm -like 'N')
                    {
                        continue
                    }
                    elseif($confirm -like 'Y')
                    {
                        $existingVnetLink.RegistrationEnabled = $true
                        $existingVnetLink.VirtualNetworkId = $vnetId
                        Set-AzPrivateDnsVirtualNetworkLink -InputObject $existingVnetLink
                        Write-Host "Overwrite of the virtual network link $($existingVnetLink.Name) was successful.`n"
                    }
                } until($confirm -like 'Y' -or $confirm -like 'N')
            }
        }
        else
        {
            New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $privateZone.ResourceGroupName -Name $linkName -ZoneName $privateZone.Name -VirtualNetworkId $vnetId -EnableRegistration
        }
    }

    $resolutionVnetIds = $privateZone.ResolutionVirtualNetworkIds
    foreach($vnetId in $resolutionVnetIds)
    {
        $linkName = CreateVirtualNetworkLinkName $vnetId
        Write-Host "Creating Resolution VirtualNetwork Link with link name: $linkName for the following virtual network:$vnetId...`n"
        $existingVnetLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $privateZone.ResourceGroupName -Name $linkName -ZoneName $privateZone.Name -ErrorAction SilentlyContinue
        if($existingVnetLink)
        {
            if($existingVnetLink.RegistrationEnabled -eq $false -and $existingVnetLink.VirtualNetworkId -like $vnetId)
            {
                Write-Host "Virtual network Link $linkName is already present in the Private DNS Zone $($privateZone.Name).`n"
                continue
            }
            else
            {
                do{
                    Write-Output $existingVnetLink
                    Write-Host -ForegroundColor Yellow "Resolution virtual network link with the same name already exists in this Private DNS zone, but it does not have the same properties as the link from legacy zone. Do you want to overwrite this virtual network link with legacy data?[Y/N]"
                    $confirm = Read-Host
                    if($confirm -like 'N')
                    {
                        continue
                    }
                    elseif($confirm -like 'Y')
                    {
                        $existingVnetLink.RegistrationEnabled = $false
                        $existingVnetLink.VirtualNetworkId = $vnetId
                        Set-AzPrivateDnsVirtualNetworkLink -InputObject $existingVnetLink
                        Write-Host "Overwrite of the virtual network link $($existingVnetLink.Name) was successful.`n"
                    }
                } until($confirm -like 'Y' -or $confirm -like 'N')
            }
        }
        else
        {
            New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $privateZone.ResourceGroupName -Name $linkName -ZoneName $privateZone.Name -VirtualNetworkId $vnetId
        }
    }

    Write-Host "VirtualNetwork Links successfully created for the Private DNS Zone.`n"
}

function VerifyDnsResolution($privateZone, $firstId, $restIds, $isRegistration)
{
    <#
    .SYNOPSIS
     Function to confirm verification of DNS resolution for virtual machines in the virtual networks that have been migrated from legacy to new model.
    .PARAMETER privateZone
     Specifies the Private DNS zone which contains the virtual network link.
    .PARAMETER firstId
     Specifies the virtual network ID of the virtual network for which DNS resolution is being verified.
    .PARAMETER restIds
     List of virtual network ID's other than firstId linked to the Private DNS zone.
    .PARAMETER isRegistration
     Boolean indicating if the virtual network link containing firstId is registration or not.
    #>

    $privateZone = Get-AzDnsZone -Name $privateZone.Name -ResourceGroupName $privateZone.ResourceGroupName

    do{
        Write-Host "Please wait for a few minutes and verify DNS resolution for all virtual machines in the virtual network $firstId. Does DNS resolution work as expected? [Y/N]`n"
        $confirm = Read-Host
        switch ($confirm.ToUpper())
        {
            'Y' { continue }
            'N' {
                    Write-Host "Reverting changes to legacy Private DNS zone $($privateZone.Name) under resource group $($privateZone.ResourceGroupName).`n"
                    $vnetIds = @()
                    $vnetIds += $firstId
                    $vnetIds += $restIds
                    if($isRegistration)
                    {
                        $privateZone.RegistrationVirtualNetworkIds = $vnetIds
                    }
                    else 
                    {
                        $privateZone.ResolutionVirtualNetworkIds = $vnetIds    
                    }

                    Set-AzDnsZone -Zone $privateZone
                    Write-Host "Please file a support request to migrate the virtual Network $firstId for the Private DNS Zone $($privateZone.Name).`n"
                    Exit
                }
        }
    } until($confirm -like 'Y' -or $confirm -like 'N')
}

function VerifyDnsResolutionAll($privateZone, $firstId, $restIds, $isRegistration)
{
    <#
    .SYNOPSIS
     Auxiliary function to confirm verification of DNS resolution for virtual machines in the virtual networks that have been migrated from legacy to new model.
    .PARAMETER privateZone
     Specifies the Private DNS zone which contains the virtual network link.
    .PARAMETER firstId
     Specifies the virtual network ID of the virtual network for which DNS resolution is being verified.
    .PARAMETER restIds
     List of virtual network ID's other than firstId linked to the Private DNS zone.
    .PARAMETER isRegistration
     Boolean indicating if the virtual network link containing firstId is registration or not.
    #>

    do{
        VerifyDnsResolution $privateZone $firstId $restIds $isRegistration
        $firstId , $restIds = $restIds
    } while($firstId)
}

function RemoveVirtualNetworkFromPrivateZone($privateZone, $firstId, $restIds, $isRegistration)
{
    <#
    .SYNOPSIS
     Function to remove a virtual network link from a Private DNS zone in the legacy model.
    .PARAMETER privateZone
     Specifies the legacy Private DNS zone which contains the virtual network link.
    .PARAMETER firstId
     Specifies the virtual network ID of the virtual network that is being removed.
    .PARAMETER restIds
     List of virtual network ID's other than firstId linked to the legacy Private DNS zone.
    .PARAMETER isRegistration
     Boolean indicating if the virtual network firstId is registration or not.
    .OUTPUTS
     Returns 1 if Yes to All/No to All operations are chosen, 0 otherwise. 
    #>

    $privateZone = Get-AzDnsZone -Name $privateZone.Name -ResourceGroupName $privateZone.ResourceGroupName
    do {
        Write-Host -ForegroundColor Green "Do you want to remove the virtual network $firstId with auto-registration property $isRegistration from the legacy Private DNS Zone $($privateZone.Name)?"
        Write-Host -ForegroundColor Green "[Y] Yes  [A] Yes to All  [N] No  [L] No to All  [S] Suspend  [?] Help:`n"   
        $confirmation = Read-Host

        switch ($confirmation.ToUpper()) 
        {
            'L' { return 1 }
            'A' { 
                    if($isRegistration)
                    {
                        $privateZone.RegistrationVirtualNetworkIds = @()
                    }
                    else 
                    {
                        $privateZone.ResolutionVirtualNetworkIds = @()
                    }

                    Set-AzDnsZone -Zone $privateZone | Out-Null
                    VerifyDnsResolutionAll $privateZone $firstId $restIds $isRegistration
                    pause
                    return 1
                }
            'N' { break }
            'Y' {
                    if([string]::IsNullOrEmpty($restIds))
                    {
                        $restIds = @()
                    }

                    if($isRegistration)
                    {
                        $privateZone.RegistrationVirtualNetworkIds = $restIds
                    }
                    else
                    {
                        $privateZone.ResolutionVirtualNetworkIds = $restIds
                    }

                    Set-AzDnsZone -Zone $privateZone | Out-Null
                    VerifyDnsResolution $privateZone $firstId $restIds $isRegistration
                    pause
                    break 
                }
            'S' { 
                    pause;
                    break 
                }
            '?' { 
                    Write-Host $helpmsg;
                    break
                }
        }
    } until ($choice -contains $confirmation)

    return 0
}

# Create path to dump zone data.
if(!(Test-Path -Path $DumpPath))
{
    New-Item -ItemType directory -Path $DumpPath
    Write-Host "New folder created: $DumpPath. This path will be the dump location for Private DNS zone data.`n"
}
else
{
    Write-Host "Folder $DumpPath already exists.`n"
}

Start-Transcript -path "$DumpPath\transcript.txt" -append

Login-AzAccount -Subscription $SubscriptionId | Out-Null

if(![string]::IsNullOrEmpty($ResourceGroupName) -and ![string]::IsNullOrEmpty($PrivateZoneName))
{
    $legacyPrivateZones = Get-AzDnsZone -ResourceGroupName $ResourceGroupName -Name $PrivateZoneName | Where-Object { $_.ZoneType -eq "Private" }
}
elseif(![string]::IsNullOrEmpty($ResourceGroupName))
{
    $legacyPrivateZones = Get-AzDnsZone -ResourceGroupName $ResourceGroupName | Where-Object { $_.ZoneType -eq "Private" }
}
elseif(![string]::IsNullOrEmpty($PrivateZoneName))
{
    Write-Host "Private DNS zone name was provided but no resource group name was provided to the script. Please re-run the script with a resource group name.`n"
    Exit
}
else 
{
    $legacyPrivateZones = Get-AzDnsZone | Where-Object { $_.ZoneType -eq "Private" }
}

if($legacyPrivateZones.Count -eq 0)
{
    Write-Host "There are no legacy Private DNS zones in this subscription. Exiting...`n"
    Exit
}

if($legacyPrivateZones.Count -gt 1000)
{
    if(!$Force.IsPresent)
    {
        Write-Error "More than 1000 legacy Private DNS zones found. Please file a support request to migrate subscription limits and re-run the script with Force parameter.`n"
        Exit
    }
    else 
    {
        Write-Warning "More than 1000 legacy Private DNS zones found. Continuing with migration process as Force parameter is specified...`n"   
    }
}

Write-Host "Found $($legacyPrivateZones.Count) legacy Private DNS Zones in the subscription $SubscriptionId`n"

# Migrate phase.
Write-Host "Migrating legacy Private DNS zones to the new model...`n"

:loop1 foreach($legacyPrivateZone in $legacyPrivateZones)
{
    do 
    {
        Write-Host -ForegroundColor Green "Do you want to migrate the following legacy privatezone?"
        Write-Output $legacyPrivateZone
        Write-Host -ForegroundColor Green "[Y] Yes  [A] Yes to All  [N] No  [L] No to All  [S] Suspend  [?] Help:`n"
        $confirmation = Read-Host

        switch ($confirmation.ToUpper()) 
        {
            'L' { break loop1 ; break }
            'A' { MigrateAllPrivateZones $legacyPrivateZones ; break loop1 }
            'N' { break }
            'Y' { MigrateSinglePrivateZone $legacyPrivateZone ; break }
            'S' { pause }
            '?' { Write-Host $helpmsg ; break }
        }
    } until ($choice -contains $confirmation)
}


# Switch phase
Write-Host "Attempting to switch DNS resolution to the new model...`n"

foreach($legacyPrivateZone in $legacyPrivateZones)
{
    $fileName = "$($legacyPrivateZone.ResourceGroupName)-$($legacyPrivateZone.Name)-switch.txt"
    $legacyPrivateZone | Out-File -FilePath "$DumpPath/$fileName"
    Write-Host "Switching DNS resolution for the Private DNS Zone $($legacyPrivateZone.Name) with the following properties:"
    Write-Output $legacyPrivateZone
    $resolutionVnetIds = $legacyPrivateZone.ResolutionVirtualNetworkIds
    $firstId , $restIds = $resolutionVnetIds
    :loop2 while($firstId)
    {
        $name = CreateVirtualNetworkLinkName $firstId
        $resolutionVnetLink = Get-AzPrivateDnsVirtualNetworkLink -Name $name -ZoneName $legacyPrivateZone.Name -ResourceGroupName $legacyPrivateZone.ResourceGroupName
        if(!($resolutionVnetLink.VirtualNetworkId -like $firstId))
        {
            Write-Host "Virtual Network Ids associated to the resolution virtual network link $($resolutionVnetLink.Name) from legacy and new Private DNS zone do not match. $($resolutionVnetLink.VirtualNetworkId) did not match $($firstId).`n"
            Exit
        }

        if($resolutionVnetLink.RegistrationEnabled -eq $true)
        {
            Write-Host "The virtual network link $($resolutionVnetLink.Name) under the Private DNS zone $($legacyPrivateZone.Name) was expected to be a resolution link, but was unexpectedly found to be auto-registration enabled.`n"
            Exit
        }

        if($resolutionVnetLink.ProvisioningState -ne "Succeeded")
        {
            Write-Host "The resolution virtual network link $($resolutionVnetLink.Name) under the Private DNS zone $($legacyPrivateZone.Name) is not in a Succeeded provisioning state as was expected.`n"
            Exit
        }

        if(RemoveVirtualNetworkFromPrivateZone $legacyPrivateZone $firstId $restIds $false)
        {
            break loop2
        }

        $firstId , $restIds = $restIds
    }

    $registrationVnetIds = $legacyPrivateZone.RegistrationVirtualNetworkIds
    $firstId , $restIds = $registrationVnetIds
    :loop3 while($firstId)
    {
        $name = CreateVirtualNetworkLinkName $firstId
        $registrationVnetLink = Get-AzPrivateDnsVirtualNetworkLink -Name $name -ZoneName $legacyPrivateZone.Name -ResourceGroupName $legacyPrivateZone.ResourceGroupName
        if(!($registrationVnetLink.VirtualNetworkId -like $firstId))
        {
            Write-Host "Virtual Network Ids associated to the registration virtual network link $($registrationVnetLink.Name) from legacy and new Private DNS zone do not match. $($registrationVnetLink.VirtualNetworkId) did not match $($firstId).`n"
            Exit
        }

        if($registrationVnetLink.RegistrationEnabled -eq $false)
        {
            Write-Host "The virtual network link $($registrationVnetLink.Name) under the Private DNS zone $($legacyPrivateZone.Name) was expected to be a registration link, but was found to be resolution instead.`n"
            Exit
        }

        if($registrationVnetLink.ProvisioningState -ne "Succeeded")
        {
            Write-Host "The registration virtual network link $($registrationVnetLink.Name) under the Private DNS zone $($legacyPrivateZone.Name) is not in a Succeeded provisioning state as was expected.`n"
            Exit
        }

        if($registrationVnetLink.VirtualNetworkLinkState -ne "Completed")
        {
            $elapsedTime = 0
            do
            {
                Start-Sleep -s 10
                $elapsedTime += 10
                $registrationVnetLink = Get-AzPrivateDnsVirtualNetworkLink -Name $name -ZoneName $legacyPrivateZone.Name -ResourceGroupName $legacyPrivateZone.ResourceGroupName
            } while($registrationVnetLink.VirtualNetworkLinkState -ne "Completed" -and $elapsedTime -lt 300)

            if($registrationVnetLink.VirtualNetworkLinkState -ne "Completed")
            {
                Write-Host "The registration virtual network link $($registrationVnetLink.Name) under the Private DNS zone $($legacyPrivateZone.Name) was not in a Completed link state as was expected.`n"
                Exit
            }
        }

        if(RemoveVirtualNetworkFromPrivateZone $legacyPrivateZone $firstId $restIds $true)
        {
            break loop3
        }

        $firstId , $restIds = $restIds
    }
}


# Cleanup phase.
Write-Host "Entering cleanup phase to remove all legacy Private DNS Zones post migration and DNS resolution switch...`n"

foreach($legacyPrivateZone in $legacyPrivateZones)
{
    $legacyPrivateZone = Get-AzDnsZone -Name $legacyPrivateZone.Name -ResourceGroupName $legacyPrivateZone.ResourceGroupName
    if($legacyPrivateZone.RegistrationVirtualNetworkIds.Count -gt 0 -or $legacyPrivateZone.ResolutionVirtualNetworkIds.Count -gt 0)
    {
        Write-Error "Found $($legacyPrivateZone.RegistrationVirtualNetworkIds.Count) Registration Virtual Networks and $($legacyPrivateZone.ResolutionVirtualNetworkIds.Count) Resolution Virtual Networks in the private zone $($legacyPrivateZone.Name). Please migrate all virtual networks before this private zone can be removed.`n"
        continue
    }

    $fileName = "$($legacyPrivatezone.ResourceGroupName)-$($legacyPrivatezone.Name)-cleanup.txt"
    $legacyPrivateZone | Out-File -FilePath "$DumpPath/$fileName"
    $migratedZone = Get-AzPrivateDnsZone -Name $legacyPrivateZone.Name -ResourceGroupName $legacyPrivateZone.ResourceGroupName
    if($migratedZone.NumberOfRecordSets -ne $legacyPrivateZone.NumberOfRecordSets)
    {
        Write-Host "Number of recordSets in legacy and new Private DNS zone $($legacyPrivatezone.Name) are not equal.`n"
        Exit
    }
    
    do {
        Write-Host -ForegroundColor Yellow "Are you sure you want to delete the legacy Private DNS zone?"
        Write-Output $legacyPrivateZone
        Write-Host -ForegroundColor Yellow "This action is irreversible and will cause all the corresponding record sets to be deleted as well. Please note that this zone has already been migrated to the new model and DNS resolution has been switched to use the virtual network links resource model.`n[Y] Yes  [N] No  [L] No to All  [S] Suspend  [?] Help:`n"
        
        $confirmation = Read-Host
        switch ($confirmation.ToUpper()) 
        {
            'L' { Exit }
            'N' { break }
            'Y' { DeleteSinglePrivateZone $legacyPrivateZone ; break }
            'S' { pause }
            '?' { Write-Host $helpmsg ; break }
        }
    } until ($choice -contains $confirmation)
}

Stop-Transcript
