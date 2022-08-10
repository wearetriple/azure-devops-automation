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

      if (!$appRegistration) {
         Write-Host "Creating new app registration for $appRegistrationName"

         $appRegistration = New-AzureADMSApplication `
            -DisplayName $appRegistrationName `
            -IdentifierUris "api://$appRegistrationName" `
            -SignInAudience "AzureADMyOrg" `
            -AppRoles @{ Id = "21111111-1111-1111-1111-111111111111"; DisplayName = "API"; AllowedMemberTypes = @("User", "Application"); Description = "API"; Value = "API" }

         $permissionScope = New-Object 'Microsoft.Open.MSGraph.Model.PermissionScope'
         $permissionScope.AdminConsentDescription = "Default"
         $permissionScope.adminConsentDisplayName = "Default"
         $permissionScope.Id = "31111111-1111-1111-1111-111111111111"
         $permissionScope.IsEnabled = $true
         $permissionScope.Type = "Admin"
         $permissionScope.Value = "Default"

         $appRegistration.Api.Oauth2PermissionScopes = New-Object 'System.Collections.Generic.List[Microsoft.Open.MSGraph.Model.PermissionScope]'
         $appRegistration.Api.Oauth2PermissionScopes.Add($permissionScope)

         Set-AzureADMSApplication -ObjectId $appRegistration.Id -Api $appRegistration.Api | out-null

         # add az cli as allowed app
         $preAuthorizedApplication1 = New-Object 'Microsoft.Open.MSGraph.Model.PreAuthorizedApplication'
         $preAuthorizedApplication1.AppId = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"
         $preAuthorizedApplication1.DelegatedPermissionIds = @("31111111-1111-1111-1111-111111111111")
            
         # add visual studio as allowed app
         $preAuthorizedApplication2 = New-Object 'Microsoft.Open.MSGraph.Model.PreAuthorizedApplication'
         $preAuthorizedApplication2.AppId = "872cd9fa-d31f-45e0-9eab-6e460a02d1f1"
         $preAuthorizedApplication2.DelegatedPermissionIds = @("31111111-1111-1111-1111-111111111111")

         $appRegistration.Api.PreAuthorizedApplications = New-Object 'System.Collections.Generic.List[Microsoft.Open.MSGraph.Model.PreAuthorizedApplication]'
         $appRegistration.Api.PreAuthorizedApplications.Add($preAuthorizedApplication1)
         $appRegistration.Api.PreAuthorizedApplications.Add($preAuthorizedApplication2)

         Set-AzureADMSApplication -ObjectId $appRegistration.Id -Api $appRegistration.Api | out-null

         Write-Host "Waiting on app registration $appRegistrationName to settle"
         
         Start-Sleep -Seconds 10

         # add the enterprise app to the app registration
         New-AzureADServicePrincipal -AccountEnabled $true -AppId $appRegistration.AppId

         Write-Host "Waiting on enterprise app $appRegistrationName to settle"
         
         Start-Sleep -Seconds 10
      }

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
