[CmdletBinding(DefaultParameterSetName="default")]
param (    
    [parameter(HelpMessage="Tenant ID value from Azure Stack active directory")]
    [Parameter(ParameterSetName="default", Mandatory=$true)]
    [Parameter(ParameterSetName="tenant", Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$AADTenantID,
    [parameter(HelpMessage="Administrative ARM endpoint")]
    [Parameter(ParameterSetName="default", Mandatory=$true)]
    [Parameter(ParameterSetName="tenant", Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$AdminArmEndpoint,   
    [parameter(HelpMessage="Service Administrator account credential from the Azure Stack active directory")]
    [Parameter(ParameterSetName="default", Mandatory=$true)]
    [Parameter(ParameterSetName="tenant", Mandatory=$true)]    
    [ValidateNotNullOrEmpty()]
    [pscredential]$ServiceAdminCredentials,
    [parameter(HelpMessage="Tenant ARM endpoint")]
    [Parameter(ParameterSetName="default", Mandatory=$false)]
    [Parameter(ParameterSetName="tenant", Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantArmEndpoint,    
    [parameter(HelpMessage="Tenant administrator account credentials from the Azure Stack active directory")] 
    [Parameter(ParameterSetName="default", Mandatory=$false)]
    [Parameter(ParameterSetName="tenant", Mandatory=$true)]
    [ValidateNotNullOrEmpty()]    
    [pscredential]$TenantAdminCredentials,
    [parameter(HelpMessage="Local path where the windows ISO is stored")]
    [Parameter(ParameterSetName="default", Mandatory=$true)]
    [Parameter(ParameterSetName="tenant", Mandatory=$true)]
    [ValidateScript({Test-Path -Path $_})]
    [ValidateNotNullOrEmpty()]
    [string]$WindowsISOPath, 
    [parameter(HelpMessage="Fully qualified domain name of the azure stack environment. Ex: contoso.com")]
    [Parameter(ParameterSetName="default", Mandatory=$false)]
    [Parameter(ParameterSetName="tenant", Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]$EnvironmentDomainFQDN,    
    [Parameter(ParameterSetName="default", Mandatory=$false)]
    [Parameter(ParameterSetName="tenant", Mandatory=$false)] 
    [ValidateNotNullOrEmpty()]
    [string]$TenantAdminObjectId = "", 
    [parameter(HelpMessage="Name of the Azure Stack environment to be deployed")]
    [Parameter(ParameterSetName="default", Mandatory=$false)]
    [Parameter(ParameterSetName="tenant", Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]$EnvironmentName = "AzureStackCanaryCloud",   
    [parameter(HelpMessage="Resource group under which all the utilities need to be placed")]
    [Parameter(ParameterSetName="default", Mandatory=$false)]
    [Parameter(ParameterSetName="tenant", Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]$CanaryUtilitiesRG = "ascanutrg" + [Random]::new().Next(1,999),
    [parameter(HelpMessage="Resource group under which the virtual machines need to be placed")]
    [Parameter(ParameterSetName="default", Mandatory=$false)]
    [Parameter(ParameterSetName="tenant", Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]$CanaryVMRG = "ascanvmrg" + [Random]::new().Next(1,999),
    [parameter(HelpMessage="Location where all the resource need to deployed and placed")]
    [Parameter(ParameterSetName="default", Mandatory=$false)]
    [Parameter(ParameterSetName="tenant", Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceLocation = "local",
    [parameter(HelpMessage="Flag to cleanup resources after exception")]
    [Parameter(ParameterSetName="default", Mandatory=$false)]
    [Parameter(ParameterSetName="tenant", Mandatory=$false)]
    [bool] $ContinueOnFailure = $false,
    [parameter(HelpMessage="Number of iterations for which Canary needs to be running in a loop (used in longhaul mode)")]
    [Parameter(ParameterSetName="default", Mandatory=$false)]
    [Parameter(ParameterSetName="tenant", Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [int]$NumberOfIterations = 1,
    [parameter(HelpMessage="Specifies whether Canary needs to clean up resources after each run (used in longhaul mode)")]
    [Parameter(ParameterSetName="default", Mandatory=$false)]
    [Parameter(ParameterSetName="tenant", Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [switch]$NoCleanup,
    [parameter(HelpMessage="Specifies the path for log files")]
    [Parameter(ParameterSetName="default", Mandatory=$false)]
    [Parameter(ParameterSetName="tenant", Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]$CanaryLogPath = $env:TMP + "\CanaryLogs$((Get-Date).ToString("-yyMMdd-hhmmss"))"
)

#Requires -Modules AzureRM
#Requires -RunAsAdministrator
Import-Module -Name $PSScriptRoot\Canary.Utilities.psm1 -Force
Import-Module -Name $PSScriptRoot\..\Connect\AzureStack.Connect.psm1 -Force
Import-Module -Name $PSScriptRoot\..\ComputeAdmin\AzureStack.ComputeAdmin.psm1 -Force

$storageAccName     = $CanaryUtilitiesRG + "sa"
$storageCtrName     = $CanaryUtilitiesRG + "sc"
$keyvaultName       = $CanaryUtilitiesRG + "kv"
$keyvaultCertName   = "ASCanaryVMCertificate"
$kvSecretName       = $keyvaultName.ToLowerInvariant() + "secret"
$VMAdminUserName    = "CanaryAdmin" 
$VMAdminUserPass    = "CanaryAdmin@123"
$canaryUtilPath     = Join-Path -Path $env:TEMP -ChildPath "CanaryUtilities$((Get-Date).ToString("-yyMMdd-hhmmss"))"

if(-not $EnvironmentDomainFQDN)
{
    $endptres = Invoke-RestMethod "${AdminArmEndpoint}/metadata/endpoints?api-version=1.0" -ErrorAction Stop 
    $EnvironmentDomainFQDN = $endptres.portalEndpoint
    $EnvironmentDomainFQDN = $EnvironmentDomainFQDN.Replace($EnvironmentDomainFQDN.Split(".")[0], "").TrimEnd("/").TrimStart(".") 
}

$runCount = 1
while ($runCount -le $NumberOfIterations)
{
    if (Test-Path -Path $canaryUtilPath)
    {
        Remove-Item -Path $canaryUtilPath -Force -Recurse 
    }
    New-Item -Path $canaryUtilPath -ItemType Directory

    #
    # Start Canary 
    #
    $CanaryLogFile      = $CanaryLogPath + "\Canary-Basic$((Get-Date).ToString("-yyMMdd-hhmmss")).log"

    Start-Scenario -Name 'Canary' -Type 'Basic' -LogFilename $CanaryLogFile -ContinueOnFailure $ContinueOnFailure

    $SvcAdminEnvironmentName = $EnvironmentName + "-SVCAdmin"
    $TntAdminEnvironmentName = $EnvironmentName + "-Tenant"

    Invoke-Usecase -Name 'CreateAdminAzureStackEnv' -Description "Create Azure Stack environment $SvcAdminEnvironmentName" -UsecaseBlock `
    {
        $asEndpoints = GetAzureStackEndpoints -EnvironmentDomainFQDN $EnvironmentDomainFQDN -ArmEndpoint $AdminArmEndpoint 
        Add-AzureRmEnvironment  -Name ($SvcAdminEnvironmentName) `
                                -ActiveDirectoryEndpoint ($asEndpoints.ActiveDirectoryEndpoint) `
                                -ActiveDirectoryServiceEndpointResourceId ($asEndpoints.ActiveDirectoryServiceEndpointResourceId) `
                                -ResourceManagerEndpoint ($asEndpoints.ResourceManagerEndpoint) `
                                -GalleryEndpoint ($asEndpoints.GalleryEndpoint) `
                                -GraphEndpoint ($asEndpoints.GraphEndpoint) `
                                -StorageEndpointSuffix ($asEndpoints.StorageEndpointSuffix) `
                                -AzureKeyVaultDnsSuffix ($asEndpoints.AzureKeyVaultDnsSuffix) `
                                -EnableAdfsAuthentication:$asEndpoints.ActiveDirectoryEndpoint.TrimEnd("/").EndsWith("/adfs", [System.StringComparison]::OrdinalIgnoreCase) `
                                -ErrorAction Stop
    }

    Invoke-Usecase -Name 'LoginToAzureStackEnvAsSvcAdmin' -Description "Login to $SvcAdminEnvironmentName as service administrator" -UsecaseBlock `
    {     
        Add-AzureRmAccount -EnvironmentName $SvcAdminEnvironmentName -Credential $ServiceAdminCredentials -TenantId $AADTenantID -ErrorAction Stop
    }

    Invoke-Usecase -Name 'SelectDefaultProviderSubscription' -Description "Select the Default Provider Subscription" -UsecaseBlock `
    {
        $defaultSubscription = Get-AzureRmSubscription -SubscriptionName "Default Provider Subscription" -ErrorAction Stop
        if ($defaultSubscription)
        {
            $defaultSubscription | Select-AzureRmSubscription
        }
    }

    if ($WindowsISOPath)
    {
        Invoke-Usecase -Name 'UploadWindows2016ImageToPIR' -Description "Uploads a windows server 2016 image to the PIR" -UsecaseBlock `
        {
            if (-not (Get-AzureRmVMImage -Location $ResourceLocation -PublisherName "MicrosoftWindowsServer" -Offer "WindowsServer" -Sku "2016-DataCenter-Core" -ErrorAction SilentlyContinue))
            {
                New-Server2016VMImage -ISOPath $WindowsISOPath -TenantId $AADTenantID -ArmEndpoint $AdminArmEndpoint -Version Core -AzureStackCredentials $ServiceAdminCredentials  
            }
        }
    }
    
    if ($TenantAdminCredentials)
    {
        $subscriptionRGName                 = "ascansubscrrg" + [Random]::new().Next(1,999)
        $tenantPlanName                     = "ascantenantplan" + [Random]::new().Next(1,999)        
        $tenantOfferName                    = "ascantenantoffer" + [Random]::new().Next(1,999)
        $tenantSubscriptionName             = "ascanarytenantsubscription" + [Random]::new().Next(1,999)            
        $canaryDefaultTenantSubscription    = "canarytenantdefaultsubscription"

        if (-not $TenantArmEndpoint)
        {
            throw [System.Exception] "Tenant ARM endpoint is required."
        }

        Invoke-Usecase -Name 'CreateTenantAzureStackEnv' -Description "Create Azure Stack environment $TntAdminEnvironmentName" -UsecaseBlock `
        {
            $asEndpoints = GetAzureStackEndpoints -EnvironmentDomainFQDN $EnvironmentDomainFQDN -ArmEndpoint $TenantArmEndpoint
            Add-AzureRmEnvironment  -Name ($TntAdminEnvironmentName) `
                                    -ActiveDirectoryEndpoint ($asEndpoints.ActiveDirectoryEndpoint) `
                                    -ActiveDirectoryServiceEndpointResourceId ($asEndpoints.ActiveDirectoryServiceEndpointResourceId) `
                                    -ResourceManagerEndpoint ($asEndpoints.ResourceManagerEndpoint) `
                                    -GalleryEndpoint ($asEndpoints.GalleryEndpoint) `
                                    -GraphEndpoint ($asEndpoints.GraphEndpoint) `
                                    -StorageEndpointSuffix ($asEndpoints.StorageEndpointSuffix) `
                                    -AzureKeyVaultDnsSuffix ($asEndpoints.AzureKeyVaultDnsSuffix) `
                                    -EnableAdfsAuthentication:$asEndpoints.ActiveDirectoryEndpoint.TrimEnd("/").EndsWith("/adfs", [System.StringComparison]::OrdinalIgnoreCase) `
                                    -ErrorAction Stop
        }
        Invoke-Usecase -Name 'CreateResourceGroupForTenantSubscription' -Description "Create a resource group $subscriptionRGName for the tenant subscription" -UsecaseBlock `
        {        
            if (Get-AzureRmResourceGroup -Name $subscriptionRGName -ErrorAction SilentlyContinue)
            {
                Remove-AzureRmResourceGroup -Name $subscriptionRGName -Force -ErrorAction Stop
            }
            New-AzureRmResourceGroup -Name $subscriptionRGName -Location $ResourceLocation -ErrorAction Stop 
        }

        Invoke-Usecase -Name 'CreateTenantPlan' -Description "Create a tenant plan" -UsecaseBlock `
        {      
            $asToken = NewAzureStackToken -AADTenantId $AADTenantId -EnvironmentDomainFQDN $EnvironmentDomainFQDN -Credentials $ServiceAdminCredentials -ArmEndPoint $AdminArmEndpoint
            $defaultSubscription = Get-AzureRmSubscription -SubscriptionName "Default Provider Subscription" -ErrorAction Stop            
            $asCanaryQuotas = NewAzureStackDefaultQuotas -ResourceLocation $ResourceLocation -SubscriptionId $defaultSubscription.SubscriptionId -AADTenantID $AADTenantID -EnvironmentDomainFQDN $EnvironmentDomainFQDN -Credentials $ServiceAdminCredentials -ArmEndPoint $AdminArmEndPoint
            New-AzureRMPlan -Name $tenantPlanName -DisplayName $tenantPlanName -ArmLocation $ResourceLocation -ResourceGroup $subscriptionRGName -SubscriptionId $defaultSubscription.SubscriptionId -AdminUri $AdminArmEndPoint -Token $asToken -QuotaIds $asCanaryQuotas -ErrorAction Stop
        }

        Invoke-Usecase -Name 'CreateTenantOffer' -Description "Create a tenant offer" -UsecaseBlock `
        {       
            if ($ascanaryPlan = Get-AzureRMPlan -Managed -ResourceGroup $subscriptionRGName | Where-Object Name -eq $tenantPlanName )
            {
                New-AzureRMOffer -Name $tenantOfferName -DisplayName $tenantOfferName -State Public -BasePlanIds @($ascanaryPlan.Id) -ArmLocation $ResourceLocation -ResourceGroup $subscriptionRGName -ErrorAction Stop
            }
        }

        Invoke-Usecase -Name 'CreateTenantDefaultManagedSubscription' -Description "Create a default managed subscription for the tenant" -UsecaseBlock `
        {       
            if (-not (Get-AzureRMManagedSubscription | Where-Object DisplayName -eq $canaryDefaultTenantSubscription))
            {
                $asCanaryOffer = Get-AzureRMOffer -Name $tenantOfferName -Managed -ResourceGroup $subscriptionRGName -ErrorAction Stop
                New-AzureRmManagedSubscription -Owner $TenantAdminCredentials.UserName -OfferId $asCanaryOffer.Id -DisplayName $canaryDefaultTenantSubscription -ErrorAction Stop  
            }   
            return $true
        }

        Invoke-Usecase -Name 'LoginToAzureStackEnvAsTenantAdmin' -Description "Login to $TntAdminEnvironmentName as tenant administrator" -UsecaseBlock `
        {     
            Add-AzureRmAccount -EnvironmentName $TntAdminEnvironmentName -Credential $TenantAdminCredentials -TenantId $AADTenantID -ErrorAction Stop
        }

        Invoke-Usecase -Name 'CreateTenantSubscription' -Description "Create a subcsription for the tenant and select it as the current subscription" -UsecaseBlock `
        {
            Set-AzureRmContext -SubscriptionName $canaryDefaultTenantSubscription
            $asCanaryOffer = Get-AzureRmOffer -Provider "Default" -ErrorAction Stop | Where-Object Name -eq $tenantOfferName
            $asTenantSubscription = New-AzureRmTenantSubscription -OfferId $asCanaryOffer.Id -DisplayName $tenantSubscriptionName -ErrorAction Stop
            if ($asTenantSubscription)
            {
                $asTenantSubscription | Select-AzureRmSubscription -ErrorAction Stop
            }           
        } 

        Invoke-Usecase -Name 'RegisterResourceProviders' -Description "Register resource providers" -UsecaseBlock `
        {
            Get-AzureRmResourceProvider -ListAvailable | Register-AzureRmResourceProvider -Force        
            $sleepTime = 0        
            while($true)
            {
                $sleepTime += 10
                Start-Sleep -Seconds  10
                $requiredRPs = Get-AzureRmResourceProvider -ListAvailable | Where-Object {$_.ProviderNamespace -in ("Microsoft.Storage", "Microsoft.Compute", "Microsoft.Network", "Microsoft.KeyVault")}
                $notRegistered = $requiredRPs | Where-Object {$_.RegistrationState -ne "Registered"}
                $registered = $requiredRPs | Where-Object {$_.RegistrationState -eq "Registered"}
                if (($sleepTime -ge 120) -and $notRegistered)
                {
                    Get-AzureRmResourceProvider | Format-Table
                    throw [System.Exception] "Resource providers did not get registered in time."
                }
                elseif ($registered.Count -eq $requiredRPs.Count)
                {
                    break
                }
            }
            Get-AzureRmResourceProvider | Format-Table             
        }         
    }

    Invoke-Usecase -Name 'CreateResourceGroupForUtilities' -Description "Create a resource group $CanaryUtilitiesRG for the placing the utility files" -UsecaseBlock `
    {        
        if (Get-AzureRmResourceGroup -Name $CanaryUtilitiesRG -ErrorAction SilentlyContinue)
        {
            Remove-AzureRmResourceGroup -Name $CanaryUtilitiesRG -Force -ErrorAction Stop
        }
        New-AzureRmResourceGroup -Name $CanaryUtilitiesRG -Location $ResourceLocation -ErrorAction Stop 
    }

    Invoke-Usecase -Name 'CreateStorageAccountForUtilities' -Description "Create a storage account for the placing the utility files" -UsecaseBlock `
    {      
        New-AzureRmStorageAccount -ResourceGroupName $CanaryUtilitiesRG -Name $storageAccName -Type Standard_LRS -Location $ResourceLocation -ErrorAction Stop
    }

    Invoke-Usecase -Name 'CreateStorageContainerForUtilities' -Description "Create a storage container for the placing the utility files" -UsecaseBlock `
    {        
        $asStorageAccountKey = Get-AzureRmStorageAccountKey -ResourceGroupName $CanaryUtilitiesRG -Name $storageAccName -ErrorAction Stop
        if ($asStorageAccountKey)
        {
            $storageAccountKey = $asStorageAccountKey.Key1
        }
        $asStorageContext = New-AzureStorageContext -StorageAccountName $storageAccName -StorageAccountKey $storageAccountKey -ErrorAction Stop
        if ($asStorageContext)
        {
            New-AzureStorageContainer -Name $storageCtrName -Permission Container -Context $asStorageContext -ErrorAction Stop   
        }
    }

    Invoke-Usecase -Name 'CreateDSCScriptResourceUtility' -Description "Create a DSC script resource that checks for internet connection" -UsecaseBlock `
    {      
        $dscScriptPath = Join-Path -Path $canaryUtilPath -ChildPath "DSCScriptResource"
        $dscScriptName = "ASCheckNetworkConnectivityUtil.ps1"
        NewAzureStackDSCScriptResource -DSCScriptResourceName $dscScriptName -DestinationPath $dscScriptPath
    }

    Invoke-Usecase -Name 'CreateCustomScriptResourceUtility' -Description "Create a custom script resource that checks for the presence of data disks" -UsecaseBlock `
    {      
        $customScriptPath = $canaryUtilPath
        $customScriptName = "ASCheckDataDiskUtil.ps1"
        NewAzureStackCustomScriptResource -CustomScriptResourceName $customScriptName -DestinationPath $customScriptPath
    }

    Invoke-Usecase -Name 'CreateDataDiskForVM' -Description "Create a data disk to be attached to the VMs" -UsecaseBlock `
    {      
        $vhdPath = Join-Path -Path $canaryUtilPath -Childpath "VMDataDisk.VHD"
        NewAzureStackDataVHD -FilePath $vhdPath -VHDSizeInGB 1
    }
        
    Invoke-Usecase -Name 'UploadUtilitiesToBlobStorage' -Description "Upload the canary utilities to the blob storage" -UsecaseBlock `
    {      
        $asStorageAccountKey = Get-AzureRmStorageAccountKey -ResourceGroupName $CanaryUtilitiesRG -Name $storageAccName -ErrorAction Stop
        if ($asStorageAccountKey)
        {
            $storageAccountKey = $asStorageAccountKey.Key1
        }
        $asStorageContext = New-AzureStorageContext -StorageAccountName $storageAccName -StorageAccountKey $storageAccountKey -ErrorAction Stop
        if ($asStorageContext)
        {
            $files = Get-ChildItem -Path $canaryUtilPath -File
            foreach ($file in $files)
            {
                if ($file.Extension -match "VHD")
                {
                    Set-AzureStorageBlobContent -Container $storageCtrName -File $file.FullName -BlobType Page -Context $asStorageContext -Force -ErrorAction Stop     
                }
                else 
                {
                    Set-AzureStorageBlobContent -Container $storageCtrName -File $file.FullName -Context $asStorageContext -Force -ErrorAction Stop             
                }
            }
        }
    }

    Invoke-Usecase -Name 'CreateKeyVaultStoreForCertSecret' -Description "Create a key vault store to put the certificate secret" -UsecaseBlock `
    {      
        if ($certExists = Get-ChildItem -Path "cert:\LocalMachine\My" | Where-Object Subject -Match $keyvaultCertName)
        {
            $certExists | Remove-Item -Force
        }
        New-SelfSignedCertificate -DnsName $keyvaultCertName -CertStoreLocation "cert:\LocalMachine\My" -ErrorAction Stop | Out-Null
        Add-Type -AssemblyName System.Web
        $certPasswordString = [System.Web.Security.Membership]::GeneratePassword(12,2)
        $certPassword = ConvertTo-SecureString -String $certPasswordString -AsPlainText -Force
        $kvCertificateName = $keyvaultCertName + ".pfx"
        $kvCertificatePath = "$env:TEMP\$kvCertificateName" 
        Get-ChildItem -Path "cert:\localMachine\my" | Where-Object Subject -Match $keyvaultCertName | Export-PfxCertificate -FilePath $kvCertificatePath -Password $certPassword | Out-Null
        $fileContentBytes     = get-content $kvCertificatePath -Encoding Byte
        $fileContentEncoded   = [System.Convert]::ToBase64String($fileContentBytes)
        $jsonObject = @"
        {
        "data": "$filecontentencoded",
        "dataType" :"pfx",
        "password": "$certPasswordString"
        }
"@ 
        $jsonObjectBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonObject)
        $jsonEncoded     = [System.Convert]::ToBase64String($jsonObjectBytes)
        New-AzureRmKeyVault -VaultName $keyvaultName -ResourceGroupName $CanaryUtilitiesRG -Location $ResourceLocation -sku standard -EnabledForDeployment -EnabledForTemplateDeployment -ErrorAction Stop | Out-Null
        if (-not [string]::IsNullOrWhiteSpace($TenantAdminObjectId)) 
        {
            Set-AzureRmKeyVaultAccessPolicy -VaultName $keyvaultName -ResourceGroupName $CanaryUtilitiesRG -ObjectId $TenantAdminObjectId -BypassObjectIdValidation -PermissionsToKeys all -PermissionsToSecrets all  
        }
        $kvSecret = ConvertTo-SecureString -String $jsonEncoded -AsPlainText -Force
        Set-AzureKeyVaultSecret -VaultName $keyvaultName -Name $kvSecretName -SecretValue $kvSecret -ErrorAction Stop
    }

    Invoke-Usecase -Name 'CreateResourceGroupForVMs' -Description "Create a resource group $CanaryVMRG for the placing the VMs and corresponding resources" -UsecaseBlock `
    {        
        if (Get-AzureRmResourceGroup -Name $CanaryVMRG -ErrorAction SilentlyContinue)
        {
            Remove-AzureRmResourceGroup -Name $CanaryVMRG -Force -ErrorAction Stop
        }
        New-AzureRmResourceGroup -Name $CanaryVMRG -Location $ResourceLocation -ErrorAction Stop 
    }

    Invoke-Usecase -Name 'DeployARMTemplate' -Description "Deploy ARM template to setup the virtual machines" -UsecaseBlock `
    {        
        $kvSecretId = (Get-AzureKeyVaultSecret -VaultName $keyVaultName -Name $kvSecretName -IncludeVersions -ErrorAction Stop).Id  
        $osVersion = ""
        if (Get-AzureRmVMImage -Location $ResourceLocation -PublisherName "MicrosoftWindowsServer" -Offer "WindowsServer" -Sku "2016-DataCenter-Core" -ErrorAction SilentlyContinue)
        {
            $osVersion = "2016-Datacenter-Core"
        }
        elseif (Get-AzureRmVMImage -Location $ResourceLocation -PublisherName "MicrosoftWindowsServer" -Offer "WindowsServer" -Sku "2012-R2-Datacenter" -ErrorAction SilentlyContinue)
        {
            $osVersion = "2012-R2-Datacenter"
        }
        $templateDeploymentName = "CanaryVMDeployment"
        $parameters = @{"VMAdminUserName"     = $VMAdminUserName;
                        "VMAdminUserPassword" = $VMAdminUserPass;
                        "ASCanaryUtilRG"      = $CanaryUtilitiesRG;
                        "ASCanaryUtilSA"      = $storageAccName;
                        "ASCanaryUtilSC"      = $storageCtrName;
                        "vaultName"           = $keyvaultName;
                        "windowsOSVersion"    = $osVersion;
                        "secretUrlWithVersion"= $kvSecretId}   
        $templateError = Test-AzureRmResourceGroupDeployment -ResourceGroupName $CanaryVMRG -TemplateFile .\azuredeploy.json -TemplateParameterObject $parameters
        if (-not $templateError)
        {
            New-AzureRmResourceGroupDeployment -Name $templateDeploymentName -ResourceGroupName $CanaryVMRG -TemplateFile .\azuredeploy.json -TemplateParameterObject $parameters -Verbose -ErrorAction Stop
        }
        else 
        {
            throw [System.Exception] "Template validation failed. `n$templateError"
        }
    }

    $canaryVMList = @()
    $canaryVMList = Invoke-Usecase -Name 'QueryTheVMsDeployed' -Description "Queries for the VMs that were deployed using the ARM template" -UsecaseBlock `
    {
        $canaryVMList = @()
        $vmList = Get-AzureRmVm -ResourceGroupName $CanaryVMRG -ErrorAction Stop
        foreach ($vm in $vmList)
        {
            $vmObject = New-Object -TypeName System.Object
            $vmIPConfig = @()
            $privateIP  = @()
            $publicIP   = @()
            $vmObject | Add-Member -Type NoteProperty -Name VMName -Value $vm.Name 
            foreach ($nic in $vm.NetworkInterfaceIds)
            {
                $vmIPConfig += (Get-AzureRmNetworkInterface -ResourceGroupName $CanaryVMRG | Where-Object Id -match $nic).IpConfigurations
            } 
            foreach ($ipConfig in $vmIPConfig)
            {
                if ($pvtIP = $ipConfig.PrivateIpAddress)
                {
                    $privateIP += $pvtIP
                }
                if ($pubIP = $ipConfig.PublicIPAddress)
                {
                    if ($pubIPId = $pubIP.Id)
                    {
                        $publicIP += (Get-AzureRmPublicIpAddress -ResourceGroupName $CanaryVMRG | Where-Object Id -eq $pubIPId).IpAddress 
                    }
                }
            }
            $vmObject | Add-Member -Type NoteProperty -Name VMPrivateIP -Value $privateIP -Force
            $vmObject | Add-Member -Type NoteProperty -Name VMPublicIP -Value $publicIP -Force
            $canaryVMList += $vmObject 
        }
        $canaryVMList
    }
    if ($canaryVMList)
    {   
        $canaryVMList | Format-Table -AutoSize    
        foreach($vm in $canaryVMList)
        {
            if ($vm.VMPublicIP)
            {
                $publicVMName = $vm.VMName
                $publicVMIP = $vm.VMPublicIP[0]
            }
            if ((-not ($vm.VMPublicIP)) -and ($vm.VMPrivateIP))
            {
                $privateVMName = $vm.VMName
                $privateVMIP = $vm.VMPrivateIP[0]
            }
        }        
    }

    Invoke-Usecase -Name 'CheckVMCommunicationPreVMReboot' -Description "Check if the VMs deployed can talk to each other before they are rebooted" -UsecaseBlock `
    {
        $vmUser = ".\$VMAdminUserName"
        $vmCreds = New-Object System.Management.Automation.PSCredential $vmUser, (ConvertTo-SecureString $VMAdminUserPass -AsPlainText -Force)
        $vmCommsScriptBlock = "Get-Childitem -Path `"cert:\LocalMachine\My`" | Where-Object Subject -Match $keyvaultCertName"
        if (($pubVMObject = Get-AzureRmVM -ResourceGroupName $CanaryVMRG -Name $publicVMName -ErrorAction Stop) -and ($pvtVMObject = Get-AzureRmVM -ResourceGroupName $CanaryVMRG -Name $privateVMName -ErrorAction Stop))
        {
            Set-item wsman:\localhost\Client\TrustedHosts -Value $publicVMIP -Force -Confirm:$false
            if ($publicVMSession = New-PSSession -ComputerName $publicVMIP -Credential $vmCreds -ErrorAction Stop)
            {
                Invoke-Command -Session $publicVMSession -Script{param ($privateIP) Set-item wsman:\localhost\Client\TrustedHosts -Value $privateIP -Force -Confirm:$false} -ArgumentList $privateVMIP | Out-Null
                $privateVMResponseFromRemoteSession = Invoke-Command -Session $publicVMSession -Script{param ($privateIP, $vmCreds, $scriptToRun) $privateSess = New-PSSession -ComputerName $privateIP -Credential $vmCreds; Invoke-Command -Session $privateSess -Script{param($script) Invoke-Expression $script} -ArgumentList $scriptToRun} -ArgumentList $privateVMIP, $vmCreds, $vmCommsScriptBlock
                if ($privateVMResponseFromRemoteSession)
                {
                    $publicVMSession | Remove-PSSession -Confirm:$false
                    $privateVMResponseFromRemoteSession
                }
                else 
                {
                    throw [System.Exception]"Public VM was not able to talk to the Private VM via the private IP"
                }
            }    
        }
    }

    Invoke-Usecase -Name 'AddDatadiskToVMWithPrivateIP' -Description "Add a data disk from utilities resource group to the VM with private IP" -UsecaseBlock `
    {
        Invoke-Usecase -Name 'StopDeallocateVMWithPrivateIPBeforeAddingDatadisk' -Description "Stop/Deallocate the VM with private IP before adding the data disk" -UsecaseBlock `
        {
            if ($vmObject = Get-AzureRmVM -ResourceGroupName $CanaryVMRG -Name $privateVMName -ErrorAction Stop)
            {
                $stopVM = $vmObject | Stop-AzureRmVM -Force -ErrorAction Stop
                if (($stopVM.StatusCode -eq "OK") -and ($stopVM.IsSuccessStatusCode))
                {
                    $vmStatus = (Get-AzureRmVM -ResourceGroupName $CanaryVMRG -Name $privateVMName -Status).Statuses
                    $powerState = ($vmStatus | Where-Object Code -match "PowerState").DisplayStatus
                    if (-not (($powerState -eq "VM stopped") -or ($powerState -eq "VM deallocated")))
                    {
                        throw [System.Exception]"Unexpected PowerState $powerState"
                    }
                }
                else
                {
                    throw [System.Exception]"Failed to stop the VM"
                }
            }
        }

        Invoke-Usecase -Name 'AddTheDataDiskToVMWithPrivateIP' -Description "Attach the data disk to VM with private IP" -UsecaseBlock `
        {
            $datadiskUri = GetAzureStackBlobUri -ResourceGroupName $CanaryUtilitiesRG -BlobContent "VMDataDisk.VHD" -StorageAccountName $storageAccName -StorageContainerName $storageCtrName
            if ($datadiskUri)
            {
                if ($vmObject = Get-AzureRmVM -ResourceGroupName $CanaryVMRG -Name $privateVMName -ErrorAction Stop)
                {
                    $destinationUri = Split-Path -Path $datadiskUri
                    $destinationUri = $destinationUri.Replace("\", "/") + "/VMDataDisk/VMDataDisk.vhd"
                    $vmObject | Add-AzureRmVMDataDisk -CreateOption fromImage -SourceImageUri $datadiskUri -Lun 1 -DiskSizeInGB 1 -Caching ReadWrite -VhdUri $destinationUri -ErrorAction Stop
                    Update-AzureRmVM -VM $vmObject -ResourceGroupName $CanaryVMRG -ErrorAction Stop
                }
            }
        } 

        Invoke-Usecase -Name 'StartVMWithPrivateIPAfterAddingDatadisk' -Description "Start the VM with private IP after adding data disk and updating the VM" -UsecaseBlock `
        {
            if ($vmObject = Get-AzureRmVM -ResourceGroupName $CanaryVMRG -Name $privateVMName -ErrorAction Stop)
            {
                $startVM = $vmObject | Start-AzureRmVM -ErrorAction Stop
                if (-not (($startVM.StatusCode -eq "OK") -and ($startVM.IsSuccessStatusCode)))
                {
                    throw [System.Exception]"Failed to start the VM $privateVMName"
                }
            }
        }
    }

    Invoke-Usecase -Name 'ApplyDataDiskCheckCustomScriptExtensionToVMWithPrivateIP' -Description "Apply custom script that checks for the presence of data disk on the VM with private IP" -UsecaseBlock `
    {
        Invoke-Usecase -Name 'CheckForExistingCustomScriptExtensionOnVMWithPrivateIP' -Description "Check for any existing custom script extensions on the VM with private IP" -UsecaseBlock `
        {
            if ($vmObject = Get-AzureRmVM -ResourceGroupName $CanaryVMRG -Name $privateVMName -ErrorAction Stop)
            {
                if ($existingCustomScriptExtension = $vmObject.Extensions | Where-Object VirtualMachineExtensionType -eq "CustomScriptExtension")
                {
                    Remove-AzureRmVMCustomScriptExtension -ResourceGroupName $CanaryVMRG -VMName $privateVMName -Name $existingCustomScriptExtension.Name -Force -ErrorAction Stop    
                }
            }
        }

        Invoke-Usecase -Name 'ApplyCustomScriptExtensionToVMWithPrivateIP' -Description "Apply the custom script extension to the VM with private IP" -UsecaseBlock `
        {
            $customScriptUri = GetAzureStackBlobUri -ResourceGroupName $CanaryUtilitiesRG -BlobContent "ASCheckDataDiskUtil.ps1" -StorageAccountName $storageAccName -StorageContainerName $storageCtrName
            if ($customScriptUri)
            {
                if ($vmObject = Get-AzureRmVM -ResourceGroupName $CanaryVMRG -Name $privateVMName -ErrorAction Stop)
                {
                    $vmObject | Set-AzureRmVMCustomScriptExtension -FileUri $CustomScriptUri -Run "ASCheckDataDiskUtil.ps1" -Name ([io.path]::GetFileNameWithoutExtension("ASCheckDataDiskUtil.ps1")) -VMName $privateVMName -TypeHandlerVersion "1.7" -ErrorAction Stop
                    Update-AzureRmVM -VM $vmObject -ResourceGroupName $CanaryVMRG -ErrorAction Stop 
                }
            }
        }
    }

    Invoke-Usecase -Name 'RestartVMWithPublicIP' -Description "Restart the VM which has a public IP address" -UsecaseBlock `
    {
        if ($vmObject = Get-AzureRmVM -ResourceGroupName $CanaryVMRG -Name $publicVMName -ErrorAction Stop)
        {
            $restartVM = $vmObject | Restart-AzureRmVM -ErrorAction Stop
            if (-not (($restartVM.StatusCode -eq "OK") -and ($restartVM.IsSuccessStatusCode)))
            {
                throw [System.Exception]"Failed to restart the VM $publicVMName"
            }
        }
    }

    Invoke-Usecase -Name 'StopDeallocateVMWithPrivateIP' -Description "Stop/Dellocate the VM with private IP" -UsecaseBlock `
    {
        if ($vmObject = Get-AzureRmVM -ResourceGroupName $CanaryVMRG -Name $privateVMName -ErrorAction Stop)
        {
            $stopVM = $vmObject | Stop-AzureRmVM -Force -ErrorAction Stop
            if (($stopVM.StatusCode -eq "OK") -and ($stopVM.IsSuccessStatusCode))
            {
                $vmStatus = (Get-AzureRmVM -ResourceGroupName $CanaryVMRG -Name $privateVMName -Status).Statuses
                $powerState = ($vmStatus | Where-Object Code -match "PowerState").DisplayStatus
                if (-not (($powerState -eq "VM stopped") -or ($powerState -eq "VM deallocated")))
                {
                    throw [System.Exception]"Unexpected PowerState $powerState"
                }
            }
            else 
            {
                throw [System.Exception]"Unexpected StatusCode/IsSuccessStatusCode: $stopVM.StatusCode/$stopVM.IsSuccessStatusCode"
            }  
        }
    }

    Invoke-Usecase -Name 'StartVMWithPrivateIP' -Description "Start the VM with private IP" -UsecaseBlock `
    {
        if ($vmObject = Get-AzureRmVM -ResourceGroupName $CanaryVMRG -Name $privateVMName -ErrorAction Stop)
        {
            $startVM = $vmObject | Start-AzureRmVM -ErrorAction Stop
            if (-not (($startVM.StatusCode -eq "OK") -and ($startVM.IsSuccessStatusCode)))
            {
                throw [System.Exception]"Failed to start the VM $privateVMName"   
            }
        }
    }

    Invoke-Usecase -Name 'CheckVMCommunicationPostVMReboot' -Description "Check if the VMs deployed can talk to each other after they are rebooted" -UsecaseBlock `
    {
        $vmUser = ".\$VMAdminUserName"
        $vmCreds = New-Object System.Management.Automation.PSCredential $vmUser, (ConvertTo-SecureString $VMAdminUserPass -AsPlainText -Force)
        $vmCommsScriptBlock = "hostname"
        if (($pubVMObject = Get-AzureRmVM -ResourceGroupName $CanaryVMRG -Name $publicVMName -ErrorAction Stop) -and ($pvtVMObject = Get-AzureRmVM -ResourceGroupName $CanaryVMRG -Name $privateVMName -ErrorAction Stop))
        {
            Set-item wsman:\localhost\Client\TrustedHosts -Value $publicVMIP -Force -Confirm:$false
            if ($publicVMSession = New-PSSession -ComputerName $publicVMIP -Credential $vmCreds -ErrorAction Stop)
            {
                Invoke-Command -Session $publicVMSession -Script{param ($privateIP) Set-item wsman:\localhost\Client\TrustedHosts -Value $privateIP -Force -Confirm:$false} -ArgumentList $privateVMIP | Out-Null
                $privateVMResponseFromRemoteSession = Invoke-Command -Session $publicVMSession -Script{param ($privateIP, $vmCreds, $scriptToRun) $privateSess = New-PSSession -ComputerName $privateIP -Credential $vmCreds; Invoke-Command -Session $privateSess -Script{param($script) Invoke-Expression $script} -ArgumentList $scriptToRun} -ArgumentList $privateVMIP, $vmCreds, $vmCommsScriptBlock
                if ($privateVMResponseFromRemoteSession)
                {
                    $publicVMSession | Remove-PSSession -Confirm:$false
                    $privateVMResponseFromRemoteSession
                }
                else 
                {
                    throw [System.Exception]"Public VM was not able to talk to the Private VM via the private IP"
                }
            }    
        }
    }

    if (-not $NoCleanup)
    {
        Invoke-Usecase -Name 'DeleteVMWithPrivateIP' -Description "Delete the VM with private IP" -UsecaseBlock `
        {
            if ($vmObject = Get-AzureRmVM -ResourceGroupName $CanaryVMRG -Name $privateVMName -ErrorAction Stop)
            {
                $deleteVM = $vmObject | Remove-AzureRmVM -Force -ErrorAction Stop
                if (-not (($deleteVM.StatusCode -eq "OK") -and ($deleteVM.IsSuccessStatusCode)))
                {
                    throw [System.Exception]"Failed to delete the VM $privateVMName"
                }
            }
        }

        Invoke-Usecase -Name 'DeleteVMResourceGroup' -Description "Delete the resource group that contains all the VMs and corresponding resources" -UsecaseBlock `
        {
            if ($removeRG = Get-AzureRmResourceGroup -Name $CanaryVMRG -ErrorAction Stop)
            {
                $removeRG | Remove-AzureRmResourceGroup -Force -ErrorAction Stop
            }
        }

        Invoke-Usecase -Name 'DeleteUtilitiesResourceGroup' -Description "Delete the resource group that contains all the utilities and corresponding resources" -UsecaseBlock `
        {
            if ($removeRG = Get-AzureRmResourceGroup -Name $CanaryUtilitiesRG -ErrorAction Stop)
            {
                $removeRG | Remove-AzureRmResourceGroup -Force -ErrorAction Stop
            }
        }

        if ($TenantAdminCredentials)
        {
            Invoke-Usecase -Name 'TenantRelatedcleanup' -Description "Remove all the tenant related stuff" -UsecaseBlock `
            {
                Invoke-Usecase -Name 'DeleteTenantSubscriptions' -Description "Remove all the tenant related subscriptions" -UsecaseBlock `
                {
                    if ($subs = Get-AzureRmTenantSubscription -ErrorAction Stop | Where-Object DisplayName -eq $tenantSubscriptionName)
                    {
                        Remove-AzureRmTenantSubscription -TargetSubscriptionId $subs.SubscriptionId -ErrorAction Stop
                    } 
                    if ($subs = Get-AzureRmTenantSubscription -ErrorAction Stop | Where-Object DisplayName -eq $canaryDefaultTenantSubscription)
                    {
                        Remove-AzureRmTenantSubscription -TargetSubscriptionId $subs.SubscriptionId -ErrorAction Stop
                    } 
                }

                Invoke-Usecase -Name 'LoginToAzureStackEnvAsSvcAdminForCleanup' -Description "Login to $SvcAdminEnvironmentName as service administrator to remove the subscription resource group" -UsecaseBlock `
                {     
                    Add-AzureRmAccount -EnvironmentName $SvcAdminEnvironmentName -Credential $ServiceAdminCredentials -TenantId $AADTenantID -ErrorAction Stop
                }

                Invoke-Usecase -Name 'DeleteSubscriptionResourceGroup' -Description "Delete the resource group that contains subscription resources" -UsecaseBlock `
                {
                    if ($removeRG = Get-AzureRmResourceGroup -Name $subscriptionRGName -ErrorAction Stop)
                    {
                        $removeRG | Remove-AzureRmResourceGroup -Force -ErrorAction Stop
                    }
                } 
            }   
        }
    }

    End-Scenario
    $runCount += 1
    Get-CanaryResult
}

if ($NumberOfIterations -gt 1)
{
    Get-CanaryLonghaulResult -LogPath $CanaryLogPath
}
