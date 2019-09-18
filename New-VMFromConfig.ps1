param([string]$config)
if(!$config){Write-Host "Enter Config File (Server Name)"; $config = Read-Host}

#read configs from xml 
if(!([xml]$vmconfig = Get-Content ".\Configs\$config.config")){Write-host "Can't find Server config, stopping..."; Break;}
$VM = $VMConfig.VM

if(!([xml]$DCConfig = Get-Content ".\Configs\datacenters.config")){Write-host "Can't find DC config, stopping..."; Break;}
$DC = $DCConfig.Datacenters.Datacenter | Where-Object {$_.Name -eq $VM.Datacenter}

if(!($cred = get-credential -Message "Domain Admin with Suffix. ex. admin@domain.local")){Write-host "No cred, stopping..."; Break;}
if(!($VIServer = connect-viserver $DC.IP -Credential $cred)){Write-host "Can't connect to VMWare Server, stopping..."; Break;}


#what VM Host should it use, if not defined by vmconfig, use dcconfig default
if($VM.Host -ne "default" -and $VM.Host){$VMHost = Get-VMHost $VM.Host}
else{$ResourcePool = Get-Cluster $DC.Cluster | Get-ResourcePool -Name Resources}
#what datastore should it use, if not defined by vmconfig, use lease used
if(@($VM.HardDisks.Disk)[0].Datastore -eq "default"){@($VM.HardDisks.Disk)[0].Datastore = $DC.Defaults.Datastore}

#pull the appropriate template.
$Template = Get-Template -Server $VIServer -Name ($DC.Template.$($VM.OSVersion))

#get folder
$VMFolder = Get-Folder -Name $VM.VMFolder -Location $DC.Name

#Create OSCustomizationSpec for joining domain and configuring IP
$OSCust = New-OSCustomizationSpec -Name "domain.local" -OSType Windows -Description "This spec adds a computer to the domain." -FullName "domain.local Domain Join" -Domain "domain.local" -DomainCredentials $cred -OrgName "Local Org" -TimeZone "Pacific" -ChangeSid -Type NonPersistent
Get-OSCustomizationNicMapping –OSCustomizationSpec "domain.local" | where {$_.Position –eq 1} | Set-OSCustomizationNicMapping -IpMode UseStaticIP -IpAddress $VM.Network.IP -SubnetMask $VM.Network.Subnet -DefaultGateway $VM.Network.Gateway -Dns $($VM.Network.PrimaryDNS), $($VM.Network.SecondaryDNS)

#check for vmware folder
if(!$VM.VMFolder){$VM.VMFolder = "Staging"}

#create vm
    if(New-VM -Name $VM.Name -Template $Template -ResourcePool $ResourcePool -VMHost $VMHost -Datastore @($VM.HardDisks.Disk)[0].Datastore -DiskStorageFormat @($VM.HardDisks.Disk)[0].Format -OSCustomizationSpec $OSCust -Location $VMFolder -confirm){

        #update vm hardware
        Set-VM $VM.Name -MemoryGB $VM.MemoryGB -NumCPU $VM.NumCPU -Confirm:$false
        Get-HardDisk $VM.Name | Set-HardDisk -CapacityGB @($VM.HardDisks.Disk)[0].DiskGB -Confirm:$false

        
        if($VM.HardDisks.Disk.Count -gt 0){
            foreach($Disk in ($VM.HardDisks.Disk | Slect-Object -Skip 1)){New-HardDisk $VM.Name -CapacityGB $Disk.DiskGB -Datastore $Disk.Datastore -StorageFormat $Disk.Format -confirm:$false}
        }

        #pre-create the ad object so it joins the domain in the correct OU (change to staging OU, or let xml define)
        if(!$VM.OU){$VM.OU = "Staging"}
        New-ADComputer -Name $VM.Name -DNSHostName "$($VM.Name).domain.local" -Path "OU=$($VM.OU),OU=03 - Servers,OU=domain,DC=domain,DC=local" -Server $DC.PrimaryDC -Credential $cred

        #power on and wait for domain join
        Start-VM $VM.Name        
        Start-Sleep -s 5; Write-Host "Waiting for Boot and OS Customization." -NoNewline                                                                                           
        While(!(Get-VIEvent -Entity $VM.Name | Where-Object { $_.GetType().Name -eq "CustomizationSucceeded"})){
            Start-Sleep -s 5;Write-Host "." -NoNewLine
        }
        Start-Sleep -s 30

        #extend disk
        Invoke-VMScript -VM $VM.Name -ScriptType Powershell -ScriptText{
            $Size = Get-PartitionSupportedSize -DriveLetter C
            Resize-Partition -DriveLetter C -Size $Size.SizeMax
            Get-Partition -DriveLetter C
            
            if((Get-Disk | Measure-Object | ForEach-Object Count) -gt 1){
                foreach($Disk in (Get-Disk | Select-Object -Skip 1)){
                    $Disk | Set-Disk -IsOffline $false
                    $Disk | Set-Disk -IsReadOnly $false
                    $Disk | Initialize-Disk -PartitionStyle MBR
                    New-Partition -DiskNumber $Disk.DiskNumber -UseMaximumSize -IsActive -DriveLetter (ls function:[e-z]: -n | ?{ !(Test-Path $_) } | Select-Object -First 1).TrimEnd(':') | Format-Volume -FileSystem NTFS
                }
            }
        }

        #update vmtools
        Update-Tools $VM.Name -NoReboot -ErrorAction SilentlyContinue

        #Restart-VMGuest $VM.Name
        Write-Output "Complete!"

    }
   

#close our session
$OSCust | Remove-OSCustomizationSpec -Confirm:$false
$VIServer = $null
#Disconnect-VIServer -Confirm:$false
