function Get-JawsCredential {
  param (
    [Parameter(Mandatory = $false)]
    [string]$login = $null,
		
    [Parameter(Mandatory = $false)]
    [string]$password = $null
  )

  if (!$login) {
    $login = $env:JAWS_API_LOGIN
  }
  if (!$login) {
    throw "Please specify JawsDeploy api login via -login parameter or as an environment variable JAWS_API_LOGIN"
  }

  if (!$password) {
    $password = $env:JAWS_API_PASSWORD
  }
  if (!$password) {
    throw "Please specify JawsDeploy api password via -password parameter or as an environment variable JAWS_API_PASSWORD"
  }

  $securePassword = ConvertTo-SecureString -String $password -AsPlainText
  return [PSCredential]::new($login, $securePassword)
}

function Invoke-JawsApi {
  param (
    [Parameter(Mandatory = $false)]
    [string]$apiBaseUrl,
		
    [Parameter(Mandatory = $true)]
    [string]$endpoint,
		
    [Parameter(Mandatory = $false)]
    [string]$method = "POST",
		
    [Parameter(Mandatory = $false)]
    [object]$payload = $null,
		
    [Parameter(Mandatory = $false)]
    [pscredential]$credential = $null
  )

  if (!$credential) {
    $credential = Get-JawsCredential
  }

  if (!$apiBaseUrl) {
    $apiBaseUrl = $env:JAWS_API_BASE_URL
  }
  if (!$apiBaseUrl) {
    $apiBaseUrl = "https://app.jawsdeploy.net/api"
  }
	
  $endpoint = if (!$endpoint) { "" } else { $endpoint.TrimStart('/') }
  $contentType = $null

  if ([string]::Equals($method, "post", [System.StringComparison]::OrdinalIgnoreCase)) {
    $payload = $payload | ConvertTo-Json
    $contentType = "application/json"
  }
  $response = Invoke-RestMethod -Uri "$apiBaseUrl/$endpoint" -Authentication Basic -Credential $credential -Method $method -ContentType $contentType -Body $payload
  return $response
}

function New-JawsRelease {
  param (
    [Parameter(Mandatory = $false)]
    [pscredential]$credential = $null,
		
    [Parameter(Mandatory = $true)]
    [string]$projectId,
		
    [Parameter(Mandatory = $false)]
    [string]$version = $null
  )

  $payload = @{
    projectid = $projectId;
    version   = $version
  }

  return Invoke-JawsApi -endpoint "release" -payload $payload -credential $credential
}

function Invoke-JawsDeployRelease {
  param (
    [Parameter(Mandatory = $false)]
    [pscredential]$credential = $null,
		
    [Parameter(Mandatory = $true)]
    [string]$releaseId,
		
    [Parameter(Mandatory = $true)]
    [string]$environmentName
  )
	
  $payload = @{
    releaseId       = $releaseId;
    environmentName = $environmentName
  }

  return Invoke-JawsApi -endpoint "release/deploy" -payload $payload -credential $credential
}

function Start-JawsCheckDeploymentState {
  param (
    [Parameter(Mandatory = $false)]
    [pscredential]$credential = $null,
		
    [Parameter(Mandatory = $true)]
    [string]$deploymentId,
		
    [Parameter(Mandatory = $false)]
    [bool]$outputLogs = $true
  )
	
  $payload = @{
    deploymentId = $deploymentId;
    skipLogs     = $outputLogs -eq $false
  }
	
  do {
    $response = Invoke-JawsApi -method GET -endpoint deployment -payload $payload -credential $credential
    $complete = (($response.status.Status -eq "Completed") -or ($response.status.Status -eq "Failed") -or ($response.status.Status -eq "Cancelled"))
		
    if ($outputLogs -eq $true) {
      foreach ($log in $response.logs) {
        Write-JawsLog -log $log
      }
    }
		
    if ($complete -eq $false) {
      Start-Sleep -Seconds 3
      if ($outputLogs -eq $true) {
        $payload["getLogsAfter"] = $response.status.LastLogDateTick
      }
    }
    else {
      break
    }
  } while ($true)
	
  return $response
}

function Write-JawsLog {
  param (
    [pscustomobject]
    $log
  )

  $formatted = [string]::Format("[{1}] {2}", $log.CreatedUtc, $log.LogLevel, $log.Data)

  if ($log.LogLevel -eq "Error" -or $log.LogLevel -eq "Critical") {
    Write-Error $formatted
  }
  elseif ($log.LogLevel -eq "Warning") {
    Write-Warning $formatted
  }
  else {
    Write-Information $formatted -InformationAction Continue
  }
}

function Invoke-ReleaseAndDeployProject {
  param (
    [Parameter(Mandatory = $false)]
    [pscredential]$credential = $null,
		
    [Parameter(Mandatory = $true)]
    [string]$projectId,
		
    [Parameter(Mandatory = $false)]
    [string]$version = $null,

    [Parameter(Mandatory = $true)]
    [string]$environmentName
  )

  $release = New-JawsRelease -credential $credential -projectId $projectId -version $version
  $deployment = Invoke-JawsDeployRelease -credential $credential -releaseId $release.releaseId -environmentName $environmentName

  # TODO: support mutl-deployment calls
  $final = Start-JawsCheckDeploymentState -credential $credential -deploymentId $deployment.deploymentIds[0]
  return $final
}

function Invoke-PromoteRelease {
  param (
    [Parameter(Mandatory = $false)]
    [pscredential]$credential = $null,
		
    [Parameter(Mandatory = $true)]
    [string]$projectId,
		
    [Parameter(Mandatory = $false)]
    [string]$version = $null,

    [Parameter(Mandatory = $true)]
    [string]$environmentName
  )

  $payload = @{
    projectId       = $projectId;
    environmentName = $environmentName
  }

  if (!!$version) {
    $payload["version"] = $version
  }

  $deployment = Invoke-JawsApi -endpoint "release/promote" -payload $payload -credential $credential

  # TODO: support mutl-deployment calls
  $final = Start-JawsCheckDeploymentState -credential $credential -deploymentId $deployment.deploymentIds[0]
  return $final
}

function Test-JawsDeploymentResult($jawsResult) {
  if (!$jawsResult) {
    Write-Error "no response from Invoke-ReleaseAndDeployProject - expected final deployment status from Jaws api"
    exit 1
  }
  if (!$jawsResult.status) {
    Write-Error "response from Invoke-ReleaseAndDeployProject does not contain status"
    exit 1
  }
  if ($jawsResult.status.Status -ne "Completed") {
    Write-Error "deployment completed with status $($jawsResult.status.Status)"
    exit 1
  }
  if ($jawsResult.status.ErrorCount -gt 0) {
    Write-Error "deployment completed with $($jawsResult.status.ErrorCount) errors - failing this step"
    exit 1
  }
}