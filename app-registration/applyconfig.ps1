# This script assigns the given MSIs to the (trivial) API app role to the listed app registration. This allows code running with those MSIs (like function apps) to request access tokens for the given app registration.

param(
    [Parameter(Mandatory = $true)][string]$tenantId
)

Connect-AzureAD -TenantId $tenantId

$assignments = Get-Content -Path config.json | ConvertFrom-Json

$environments = @( @{ namePrefix = "test-"; environment = "T" }, @{ namePrefix = "acc-"; environment = "A" }, @{ namePrefix = ""; environment = "P" } )

foreach ($api in $assignments.psobject.properties.name) {
   foreach ($env in $environments) {

      $envPrefix = $env['namePrefix']

      $appRegistrationName = "$envPrefix$api"

      $appRegistration = Get-AzureADMSApplication -Filter "DisplayName eq '$appRegistrationName'"

      $appId = $appRegistration.AppId

      $enterpriseAppServicePrincipal = Get-AzureADServicePrincipal -filter "AppId eq '$appId'"
      
      $ObjectId = $enterpriseAppServicePrincipal.ObjectId

      $currentAppRoles = Get-AzureADServiceAppRoleAssignment -ObjectId $ObjectId

      foreach ($msiTemplate in $assignments.$api) {
         Write-Host "$appRegistrationName : $ObjectId"

         $msi = $msiTemplate.Replace("{ENV}", $env['environment'])

         $hasAppRole = $currentAppRoles | Where-Object { $_.PrincipalDisplayName -eq $msi } | Select-Object -first 1

         if ($hasAppRole) {
            Write-Host "msi: $msi"
            Write-Host "Assignment exists"
         }
         else {
            $AppRoleId = ($appRegistration.AppRoles | Where-Object { $_.DisplayName -eq "API" }).Id

            $msiServicePrincipal = Get-AzureADServicePrincipal -filter "DisplayName eq '$msi'"
            
            $MsiPrincipalId = $msiServicePrincipal.ObjectId
            
            Write-Host "$msi : $MsiPrincipalId"
            Write-Host "API: $AppRoleId"
            Write-Host "Adding assignment"

            New-AzureADServiceAppRoleAssignment -ObjectId $MsiPrincipalId -principalId $MsiPrincipalId -ResourceId $ObjectId -Id $AppRoleId
         }
         
         Write-Host "---"
      }
   }
}
