# This script creates the given Service Connections to Azure DevOps, gives the service principal Contributor
# rights to the similarly named resource group, and applies any additional roles.

param(
  [Parameter(Mandatory = $true)][string]$pat,
  [Parameter(Mandatory = $true)][string]$json
)

function Add-ResourceGroup($location, $name) {
  az group create -g $name -l $location | out-null
}

function Update-AppRegistration($servicePrincipalId, $appName, $roles) {
  $app = az ad app show --id $servicePrincipalId | ConvertFrom-Json

  if (!$app) {
    Throw "Failed to get app registration for $servicePrincipalId"
  }

  Write-Host "Updating name of service principal $servicePrincipalId from $($app.displayName) to $appName"
  
  az ad app update --id $servicePrincipalId --display-name $appName  | out-null
  
  $sp = az ad sp list --display-name $appName | ConvertFrom-Json

  if ($sp) {
    foreach ($role in $roles) {
      Write-Host "Adding $($role.name) with scope $($role.scope) to $appName"

      az role assignment create --role $role.name --assignee-object-id $sp.id --assignee-principal-type ServicePrincipal --scope $role.scope | out-null
    }
  }
  else {
    Write-Host "Cannot find service principal with display name $appName"
  }

  return;
}

function Add-ServiceConnection($azureDevOps, $accesstoken, $appName, $scope) {
  $header = @{
    Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($accesstoken)")) 
  }
  $postHeaders = @{
    Authorization  = $header.Authorization
    "Content-Type" = 'application/json'
  }
  
  $getProjectIdsRequest = @{ Uri = "https://dev.azure.com/$($azureDevOps.organizationName)/_apis/projects?api-version=7.1-preview.4"; Headers = $header }
    
  $projectIds = Invoke-RestMethod @getProjectIdsRequest

  $projectId = $projectIds.value.where({ $_.name -eq $azureDevOps.projectName }).id

  $servicePrincipalId = Get-ServicePrincipalIdOfServiceConnection $azureDevOps $projectId $header $appName
  if ($servicePrincipalId) {
    Write-Host "Found service connection $appName with principal id $servicePrincipalId"

    $app = az ad app show --id $servicePrincipalId | ConvertFrom-Json
    if (!$app) {
      Throw "Failed to get app registration for $servicePrincipalId"
    }
     
    return $servicePrincipalId;
  }

  Write-Host "Creating service connection $appName with scope $scope"

  $subscription = az account show | ConvertFrom-Json

  $body = @{
    data                             = @{
      subscriptionId   = $subscription.id
      subscriptionName = $subscription.name
      environment      = $subscription.environmentName
      scopeLevel       = "Subscription"
      creationMode     = "Automatic"
    }
    authorization                    = @{
      parameters = @{
        scope                     = $scope
        tenantid                  = $subscription.tenantId
        serviceprincipalid        = ""
        authenticationType        = "spnKey"
        accessTokenFetchingMethod = "1"
      } 
      scheme     = "ServicePrincipal" 
    }
    name                             = $appName
    type                             = "AzureRM"
    url                              = "https://management.azure.com/"
    isShared                         = $False
    isReady                          = $True
    owner                            = "library"
    serviceEndpointProjectReferences = @(
      @{
        projectReference = @{
          id   = $projectId
          name = $azureDevOps.projectName
        }
        name             = $appName
      }
    )
  }

  $createConnectionRequest = @{ 
    Method  = 'POST'
    Uri     = "https://dev.azure.com/$($azureDevOps.organizationName)/_apis/serviceendpoint/endpoints?api-version=7.1-preview.4"
    Headers = $postHeaders
    Body    = $body | ConvertTo-Json -Depth 100
  }

  $connection = Invoke-RestMethod @createConnectionRequest

  Write-Host "Authorizing $appName $($connection.id) for everyone"
  
  $shareConnectionBody = @{
    resource     = @{
      id   = $connection.id
      type = "endpoint"
      name = ""
    }
    allPipelines = @{
      authorized = $True
    }
  }

  $shareConnectionRequest = @{ 
    Method  = 'PATCH'
    Uri     = "https://dev.azure.com/$($azureDevOps.organizationName)/$projectId/_apis/pipelines/pipelinePermissions/endpoint/$($connection.id)?api-version=5.1-preview.1" # dont ask why this api version is different
    Headers = $postHeaders
    Body    = $shareConnectionBody | ConvertTo-Json -Depth 100
  }

  Invoke-RestMethod @shareConnectionRequest | out-null

  while ($true) {
    Write-Host "Waiting until $appName settles in"
    
    Start-Sleep -Seconds 3

    $serviceConnectionId = Get-ServicePrincipalIdOfServiceConnection $azureDevOps $projectId $header $appName

    if ($serviceConnectionId) {
      Write-Host "$appName is settled in, wait for az cli to pickup principal"

      $app = az ad app show --id $serviceConnectionId | ConvertFrom-Json

      if ($app) {
        Write-Host "$appName found in az cli"
        
        return $serviceConnectionId
      }

      Write-Host "$appName not settled in az cli"
    }
  }
}

function Get-ServicePrincipalIdOfServiceConnection($azureDevOps, $projectId, $header, $name) {
  $getServiceConnectionRequest = @{ 
    Method  = "GET" 
    Uri     = "https://dev.azure.com/$($azureDevOps.organizationName)/$projectId/_apis/serviceendpoint/endpoints?endpointNames=$name&api-version=7.1-preview.4" 
    Headers = $header 
  }
  
  $serviceConnections = Invoke-RestMethod @getServiceConnectionRequest

  if ($serviceConnections.count -eq 1) {
    $principalId = $serviceConnections.value.authorization.parameters.serviceprincipalid;

    Write-Host "Found service connection with using principal id $principalId"

    return $principalId
  }
  else {
    Write-Host "Found $($serviceConnections.count) principals for $name"
  }
}

function Format-String($string, $tokenSources) {
  foreach ($tokenSource in $tokenSources) {
    foreach ($property in $tokenSource.PSObject.Properties) {
      $string = $string -replace "{$($property.Name)}", $property.Value
    }
  }
  return $string
}

$config = Get-Content -Path $json | ConvertFrom-Json

foreach ($serviceConnection in $config.serviceConnections) {
  foreach ($environment in $serviceConnection.environments) {

    Write-Host "Setting account to $($environment.subscriptionId)"

    az account set -s $environment.subscriptionId

    foreach ($region in $serviceConnection.regions) {
      $appName = Format-String $serviceConnection.name $region, $environment
    
      $scope = "/subscriptions/$($environment.subscriptionId)";
      if ($serviceConnection.scope -eq "resourcegroup") {
        $scope += "/resourcegroups/$appName"
      }
        
      $appRoles = @()
      foreach ($resourceGroup in $serviceConnection.resourceGroups.PSObject.Properties) {
        $resourceGroupName = Format-String $resourceGroup.Name $region, $environment, ([PSCustomObject]@{ name = $appName })

        Write-Host "Processing $appName"

        if ($resourceGroup.Name.Contains("{name}")) {
          $existingGroup = az group show -g $resourceGroupName | ConvertFrom-Json

          if ($existingGroup) {
            if ($existingGroup.location -eq $region.location) {
              Write-Host "Resource group $resourceGroupName exists"
            }
            else {
              Write-Host "WARNING: Resource group $resourceGroupName exists in $($existingGroup.location)"
            }
          }
          else {
            Write-Host "Creating resource group $resourceGroupName in $($region.location)"
          }

          Add-ResourceGroup $region.location $resourceGroupName
        }

        foreach ($role in $resourceGroup.Value) {
          $appRoles += @{ name = $role; scope = "/subscriptions/$($environment.subscriptionId)/resourceGroups/$resourceGroupName" }
        }

        Write-Host "--"
      }

      foreach ($role in $serviceConnection.subscription) {
        $appRoles += @{ name = $role; scope = "/subscriptions/$($environment.subscriptionId)" }
      }

      $serviceprincipalid = Add-ServiceConnection $config.azureDevOps $pat $appName $scope
      
      if (!$serviceprincipalid) {
        Throw "Failed to create service connection"
      }

      Write-Host "Updating $appName to have roles $($appRoles | ConvertTo-Json -Depth 10)"

      Update-AppRegistration $serviceprincipalid $appName $appRoles
    }
  }
}
