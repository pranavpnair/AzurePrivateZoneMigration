##############################################################################
## Copyright (c) Microsoft Corporation.  All rights reserved.
##############################################################################


param(
    [Parameter(Mandatory=$true)] [ValidateNotNullOrEmpty()] [string] $subscriptionId
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

function Assert-AreEqual($a,$b)
{
    if($a -eq $b)
    {
        return
    }

    Write-Error "Assertion Failed. $a is not equal to $b."
    Exit-PSSession
}

function MigrateAllPrivateZones($privateZones)
{
    foreach($privateZone in $privateZones)
    {
        MigrateSinglePrivateZone($privateZone)
    }
}

function DeleteAllPrivateZones($privateZones)
{
    foreach($privateZone in $privateZones)
    {
        DeleteSinglePrivateZone($privateZone)
    }
}


function CreateRecordConfig($recordSet)
{
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

function MigrateSinglePrivateZone($privateZone)
{
    if($privateZone.NumberOfRecordSets -gt 25000 -or $privateZone.ResolutionVirtualNetworkIds.Count -gt 100)
    {
        Write-Error "Number of recordsets on this private zone = $($privateZone.NumberOfRecordSets). Number of resolution virtual network Ids on this private zone = $($privateZone.ResolutionVirtualNetworkIds.Count). These values are higher than normal limits of 25000 and 100 respectively. Please file a support request to migrate limits and re-run the script with Force parameter."
        Exit-PSSession
    }

    #Out-File -FilePath .\privatezone.txt
    Write-Host "Attempting to create new Private DNS Zone $($privateZone.Name) and migrating corresponding RecordSets from the old model...`n"

    $migratedZone = Get-AzPrivateDnsZone -ResourceGroupName $privateZone.ResourceGroupName -Name $privateZone.Name -ErrorVariable notPresent -ErrorAction SilentlyContinue
    if($notPresent)
    {
        $migratedZone = New-AzPrivateDnsZone -Name $privateZone.Name -ResourceGroupName $privateZone.ResourceGroupName
    }
    else
    {
        Write-Host "Private DNS Zone $($privateZone.Name) already exists. Attempting migration of RecordSets...`n"
    }

    $recordSets = Get-AzDnsRecordSet -ZoneName $privateZone.Name -ResourceGroupName $privateZone.ResourceGroupName
    foreach($recordSet in $recordSets)
    {   
        if($recordSet.RecordType.ToString() -eq 'SOA')
        {
            continue
        }

        Get-AzPrivateDnsRecordSet -Zone $migratedZone -Name $recordSet.Name -RecordType $recordSet.RecordType.ToString() -ErrorVariable notPresent -ErrorAction SilentlyContinue
        if([string]::IsNullOrEmpty($notPresent))
        {
            Write-Host "RecordSet $($recordSet.Name) already exists in the Private DNS Zone.`n"
            continue
        }

        $recordConfig = CreateRecordConfig $recordSet
        New-AzPrivateDnsRecordSet -Name $recordSet.Name -Zone $migratedZone -RecordType $recordSet.RecordType.ToString() -Ttl $recordSet.Ttl -PrivateDnsRecord $recordConfig
        Write-Host "Created new RecordSet $($recordSet.Name) under Private DNS Zone $($migratedZone.Name)`n"
    }

    CreateVirtualNetworkLinks $privateZone
    Write-Host "Migration of Private DNS Zone $($privateZone.Name) and its RecordSets under resource group $($privateZone.ResourceGroup) completed successfully.`n"
}

function DeleteSinglePrivateZone($privateZone)
{
    Remove-AzDnsZone -Zone $privateZone -Confirm:$false
    Write-Host "Successfully delete Private DNS Zone $($privateZone.Name) after migration to new model."
}

function CreateVirtualNetworkLinks($privateZone)
{
    Write-Host "Creating VirtualNetwork Links for all resolution and registration virtual networks in the private zone:"
    Write-Output $privateZone

    $registrationVnetIds = $privateZone.RegistrationVirtualNetworkIds
    foreach($vnetId in $registrationVnetIds)
    {
        $linkName = $vnetId.Split('/')[4]+ "-" + $vnetId.Split('/')[-1] + "-Link" 
        Write-Host "Creating Registration VirtualNetwork Link with link name: $linkName for the following virtual network:$vnetId...`n"
        Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $privateZone.ResourceGroupName -Name $linkName -ZoneName $privateZone.Name -ErrorVariable notPresent -ErrorAction SilentlyContinue | Out-Null
        if([string]::IsNullOrEmpty($notPresent))
        {
            Write-Host "VirtualNetwork Link $linkName is already present in the Private DNS Zone $($privateZone.Name).`n"
            continue
        }

        New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $privateZone.ResourceGroupName -Name $linkName -ZoneName $privateZone.Name -VirtualNetworkId $vnetId -EnableRegistration
    }

    $resolutionVnetIds = $privateZone.ResolutionVirtualNetworkIds
    foreach($vnetId in $resolutionVnetIds)
    {
        $linkName = $vnetId.Split('/')[-1] + "-Link" 
        Write-Host "Creating Resolution VirtualNetwork Link with link name: $linkName for the following virtual network:$vnetId...`n"
        Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $privateZone.ResourceGroupName -Name $linkName -ZoneName $privateZone.Name -ErrorVariable notPresent -ErrorAction SilentlyContinue | Out-Null
        if([string]::IsNullOrEmpty($notPresent))
        {
            Write-Host "VirtualNetwork Link $linkName is already present in the Private DNS Zone $($privateZone.Name).`n"
            continue
        }

        New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $privateZone.ResourceGroupName -Name $linkName -ZoneName $privateZone.Name -VirtualNetworkId $vnetId
    }

    Write-Host "VirtualNetwork Links successfully created for the Private DNS Zone.`n"
}

function VerifyDnsResolution($privateZone, $firstId, $restIds, $isRegistration)
{
    $privateZone = Get-AzDnsZone -Name $privateZone.Name -ResourceGroupName $privateZone.ResourceGroupName

    do{
        Write-Host "Please wait for a few minutes and verify DNS resolution for all virtual machines that were previously present in the virtual network $firstId. Does DNS resolution work as expected? [Y/N]`n"
        $confirm = Read-Host
        switch ($confirm.ToUpper())
        {
            'Y' { continue }
            'N' {
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
                    Exit-PSSession
                }
        }
    } until($confirm.ToUpper() -eq 'Y' -or $confirm.ToUpper() -eq 'N')
}


function RemoveVirtualNetworkFromPrivateZone($privateZone, $firstId, $restIds, $isRegistration)
{
    $privateZone = Get-AzDnsZone -Name $privateZone.Name -ResourceGroupName $privateZone.ResourceGroupName

    do {
        Write-Host -ForegroundColor Green "Do you want to remove the following virtual network from the Private DNS Zone $($privateZone.Name)?"
        Write-Output $firstId
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
                    VerifyDnsResolution $privateZone $firstId $restIds $isRegistration
                    pause
                    break loop3
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


mkdir "ZoneData"
Login-AzAccount -Subscription $subscriptionId | Out-Null
$privateZones = Get-AzDnsZone | Where-Object {$_.ZoneType -eq "Private"}

if($privateZones.Count -gt 1000)
{
    Write-Error "More than 1000 Private Zones found. Please file a support request to migrate limits and re-run the script with Force parameter."
    Exit-PSSession
}

Write-Host "Found $($privateZones.Count) Private DNS Zones in the subscription $subscriptionId`n"

#migrate phase
Write-Host "Migrating existing Private DNS zones to the new model...`n"

:loop1 foreach($privateZone in $privateZones)
{
    do 
    {
        Write-Host -ForegroundColor Green "Do you want to migrate the following privatezone?"
        Write-Output $privateZone
        Write-Host -ForegroundColor Green "[Y] Yes  [A] Yes to All  [N] No  [L] No to All  [S] Suspend  [?] Help:`n"
        $confirmation = Read-Host

        switch ($confirmation.ToUpper()) 
        {
            'L' { break loop1 ; break }
            'A' { MigrateAllPrivateZones $privateZones ; break loop1 }
            'N' { break }
            'Y' { MigrateSinglePrivateZone $privateZone ; break }
            'S' { pause }
            '?' {Write-Host $helpmsg ; break}
        }
    } until ($choice -contains $confirmation)
}


#switch phase
Write-Host "Attempting to switch DNS resolution to the new model...`n"

:loop2 foreach($privateZone in $privateZones)
{
    $fileName = "$($privatezone.ResourceGroupName)-$($privatezone.Name)-switch.txt"
    Out-File -FilePath "ZoneData/$fileName"
    Write-Host "Switching DNS resolution for the Private DNS Zone $($privateZone.Name) with the following properties:"
    Write-Output $privateZone
    $resolutionVnetIds = $privateZone.ResolutionVirtualNetworkIds
    $firstId , $restIds = $resolutionVnetIds
    while(!($null -eq $firstId))
    {
        $name = $firstId.Split('/')[-1] + "-Link"
        $resolutionVnetLink = Get-AzPrivateDnsVirtualNetworkLink -Name $name -ZoneName $privateZone.Name -ResourceGroupName $privateZone.ResourceGroupName
        Assert-AreEqual  $resolutionVnetLink.VirtualNetworkId $firstId
        Assert-AreEqual $resolutionVnetLink.RegistrationEnabled $false
        Assert-AreEqual $resolutionVnetLink.ProvisioningState "Succeeded"

        if(RemoveVirtualNetworkFromPrivateZone $privateZone $firstId $restIds $false)
        {
            break loop2
        }

        $firstId , $restIds = $restIds
    }

    $registrationVnetIds = $privateZone.RegistrationVirtualNetworkIds
    $firstId , $restIds = $registrationVnetIds
    while(!($null -eq $firstId))
    {
        $name = $firstId.Split('/')[-1] + "-Link"
        $registrationVnetLink = Get-AzPrivateDnsVirtualNetworkLink -Name $name -ZoneName $privateZone.Name -ResourceGroupName $privateZone.ResourceGroupName
        Assert-AreEqual  $registrationVnetLink.VirtualNetworkId $firstId
        Assert-AreEqual $registrationVnetLink.RegistrationEnabled $true
        Assert-AreEqual $registrationVnetLink.ProvisioningState "Succeeded"
        Assert-AreEqual $registrationVnetLink.VirtualNetworkLinkState "Completed"

        if(RemoveVirtualNetworkFromPrivateZone $privateZone $firstId $restIds $true)
        {
            break loop2
        }

        $firstId , $restIds = $restIds
    }
}


#cleanup
Write-Host "Entering cleanup phase to remove all Private DNS Zones post migration and DNS resolution switch...`n"

:loop3 foreach($privateZone in $privateZones)
{
    $privateZone = Get-AzDnsZone -Name $privateZone.Name -ResourceGroupName $privateZone.ResourceGroupName
    if($privateZone.RegistrationVirtualNetworkIds.Count -gt 0 -or $privateZone.ResolutionVirtualNetworkIds.Count -gt 0)
    {
        Write-Error "Found $($privateZone.RegistrationVirtualNetworkIds.Count) Registration Virtual Networks and $($privateZone.ResolutionVirtualNetworkIds.Count) Resolution Virtual Networks in the private zone. Please migrate all virtual networks before this private zone can be removed.`n"
        continue
    }

    $fileName = "$($privatezone.ResourceGroupName)-$($privatezone.Name)-cleanup.txt"
    Out-File -FilePath "ZoneData/$fileName"
    $migratedZone = Get-AzPrivateDnsZone -Name $privateZone.Name -ResourceGroupName $privateZone.ResourceGroupName
    Assert-AreEqual $migratedZone.NumberOfRecordSets $privateZone.NumberOfRecordSets
    
    do {
        Write-Host -ForegroundColor Yellow "Are you sure you want to delete the Private DNS zone?"
        Write-Output $privateZone
        Write-Host -ForegroundColor Yellow "This action is irreversible and will cause all the corresponding record sets to be deleted as well. Please note that this zone has already been migrated to the new model and DNS resolution has been switched to use the virtual network links resource model.`n[Y] Yes  [A] Yes to All  [N] No  [L] No to All  [S] Suspend  [?] Help:`n"
        
        $confirmation = Read-Host
        switch ($confirmation.ToUpper()) 
        {
            'L' { Exit-PSSession }
            'A' { DeleteAllPrivateZones $privateZones ; break loop3 }
            'N' { break }
            'Y' { DeleteSinglePrivateZone $privateZone ; break }
            'S' { pause }
            '?' {Write-Host $helpmsg ; break}
        }
    } until ($choice -contains $confirmation)
}
