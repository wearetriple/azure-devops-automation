# This script creates the given Service Connections to Azure DevOps, gives the service principal Contributor
# rights to the similarly named resource group, and applies any additional roles.

param(
  [Parameter(Mandatory = $true)][string]$pat
)

function Add-ResourceGroup($location, $name) {
  az group create -g $name -l $location | out-null
}

function Update-AppRegistration($servicePrincipalId, $appName, $roles) {
  $app = az ad app show --id $servicePrincipalId | ConvertFrom-Json

  if (!$app) {
    Write-Error "Failed to get app registration for $servicePrincipalId"
  }

  Write-Host "Updating name of service principal $servicePrincipalId from $($app.displayName) to $appName"
  
  az ad app update --id $servicePrincipalId --display-name $appName  | out-null

  foreach ($role in $roles) {
    Write-Host "Adding $($role.name) with scope $($role.scope) to $appName"

    az ad sp create-for-rbac -n $appName --role $role.name --scopes $role.scope  | out-null
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

  Invoke-RestMethod @createConnectionRequest  | out-null

  return Get-ServicePrincipalIdOfServiceConnection $azureDevOps $projectId $header $appName
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
}

function Format-String($string, $tokenSources) {
  foreach ($tokenSource in $tokenSources) {
    foreach ($property in $tokenSource.PSObject.Properties) {
      $string = $string -replace "{$($property.Name)}", $property.Value
    }
  }
  return $string
}

$config = Get-Content -Path config.json | ConvertFrom-Json

foreach ($serviceConnection in $config.serviceConnections) {
  foreach ($environment in $serviceConnection.environments) {

    az account set -s $environment.subscriptionId

    $scope = "/subscriptions/$($environment.subscriptionId)";
    if ($serviceConnection.scope -eq "resourcegroup") {
      $scope += "/resourcegroups/$appName"
    }
    
    foreach ($region in $serviceConnection.regions) {
      $appName = Format-String $serviceConnection.name $region, $environment

      $appRoles = @()
      foreach ($resourceGroup in $serviceConnection.resourceGroups.PSObject.Properties) {
        $resourceGroupName = Format-String $resourceGroup.Name $region, $environment, ([PSCustomObject]@{ name = $appName })

        if ($resourceGroup.Name.Contains("{name}")) {
          Write-Host "Creating resource group $resourceGroupName in $($region.location)"

          Add-ResourceGroup $region.location $resourceGroupName
        }

        foreach ($role in $resourceGroup.Value) {
          $appRoles += @{ name = $role; scope = "/subscriptions/$($environment.subscriptionId)/resourceGroups/$resourceGroupName" }
        }
      }

      foreach ($role in $serviceConnection.subscription) {
        $appRoles += @{ name = $role; scope = "/subscriptions/$($environment.subscriptionId)" }
      }

      $serviceprincipalid = Add-ServiceConnection $config.azureDevOps $pat $appName $scope
      
      if (!$serviceprincipalid) {
        Throw "Failed to create service connection"
      }

      Update-AppRegistration $serviceprincipalid $appName $appRoles
    }
  }
}
