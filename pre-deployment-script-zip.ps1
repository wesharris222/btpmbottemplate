# Automated Bot Deployment Script - Uses settings.json
param(
    [string]$ParametersFile = "settings.json"
)

# Check if parameters file exists
if (-not (Test-Path $ParametersFile)) {
    Write-Error "Parameters file not found: $ParametersFile"
    exit 1
}

# Read parameters from file
$params = Get-Content $ParametersFile | ConvertFrom-Json
$BotName = $params.parameters.botName.value
$ResourceGroupName = $params.parameters.resourceGroupName.value
$Location = $params.parameters.location.value
$TenantId = $params.parameters.tenantId.value
$BeyondTrustBaseUrl = $params.parameters.beyondTrustBaseUrl.value
$BeyondTrustClientId = $params.parameters.beyondTrustClientId.value
$BeyondTrustClientSecret = $params.parameters.beyondTrustClientSecret.value

Write-Host "=== Automated Bot Deployment ===" -ForegroundColor Cyan
Write-Host "Bot Name: $BotName" -ForegroundColor Yellow
Write-Host "Resource Group: $ResourceGroupName" -ForegroundColor Yellow
Write-Host "Location: $Location" -ForegroundColor Yellow

# Step 0: Check and create Resource Group if needed
Write-Host "`n0. Checking Resource Group..." -ForegroundColor Green
$rgExists = az group exists --name $ResourceGroupName --output tsv

if ($rgExists -eq "false") {
    Write-Host "Resource Group doesn't exist. Creating..." -ForegroundColor Yellow
    az group create --name $ResourceGroupName --location $Location --output json | Out-Null
    Write-Host "[OK] Created Resource Group: $ResourceGroupName" -ForegroundColor Green
} else {
    Write-Host "[OK] Resource Group already exists: $ResourceGroupName" -ForegroundColor Green
}

# Step 1: Create Azure AD App Registration
Write-Host "`n1. Creating Azure AD App Registration..." -ForegroundColor Green
$appRegistration = az ad app create `
    --display-name $BotName `
    --sign-in-audience "AzureADMultipleOrgs" `
    --output json | ConvertFrom-Json

$appId = $appRegistration.appId
Write-Host "[OK] Created app registration: $appId" -ForegroundColor Green

# Step 2: Create Client Secret
Write-Host "`n2. Creating client secret..." -ForegroundColor Green
$secret = az ad app credential reset `
    --id $appId `
    --display-name "BotSecret" `
    --output json | ConvertFrom-Json

$appPassword = $secret.password
Write-Host "[OK] Created client secret" -ForegroundColor Green

# Step 3: Create/Update Parameters File for ARM Template
Write-Host "`n3. Creating deployment parameters..." -ForegroundColor Green
$parameters = @{
    "`$schema" = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
    "contentVersion" = "1.0.0.0"
    "parameters" = @{
        "botName" = @{"value" = $BotName}
        "location" = @{"value" = $Location}
        "microsoftAppId" = @{"value" = $appId}
        "microsoftAppPassword" = @{"value" = $appPassword}
        "microsoftAppTenantId" = @{"value" = $TenantId}
        "beyondTrustBaseUrl" = @{"value" = $BeyondTrustBaseUrl}
        "beyondTrustClientId" = @{"value" = $BeyondTrustClientId}
        "beyondTrustClientSecret" = @{"value" = $BeyondTrustClientSecret}
    }
}

$parametersJson = $parameters | ConvertTo-Json -Depth 10
$parametersFile = "deployment-params-auto.json"
$parametersJson | Out-File -FilePath $parametersFile -Encoding UTF8

Write-Host "[OK] Created parameters file: $parametersFile" -ForegroundColor Green

# Step 4: Deploy ARM Template
Write-Host "`n4. Deploying ARM template..." -ForegroundColor Green
Write-Host "This will take 5-10 minutes..." -ForegroundColor Yellow

# Run deployment and capture output as string first
$deploymentResult = az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file "azuredeploy-simple.json" `
    --parameters $parametersFile `
    --output json

# Check if deployment command succeeded
if ($LASTEXITCODE -eq 0) {
    # Parse the JSON result
    $deployment = $deploymentResult | ConvertFrom-Json
    
    if ($deployment.properties.provisioningState -eq "Succeeded") {
    Write-Host "[OK] Deployment completed successfully!" -ForegroundColor Green
    
    # Step 5: Clone repository and deploy code
    Write-Host "`n5. Cloning repository and deploying code..." -ForegroundColor Green
    
    # Create temporary directory for deployment
    $tempDir = Join-Path $env:TEMP "bot-deployment-$(Get-Date -Format 'yyyyMMddHHmmss')"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    
    try {
        # Clone the repository
        Write-Host "Cloning repository..." -ForegroundColor Yellow
        git clone https://github.com/wesharris222/btpmapprovalsbot $tempDir
        
        # Store icon paths before deployment
        $colorIconPath = Join-Path $tempDir "color.png"
        $outlineIconPath = Join-Path $tempDir "outline.png"
        $hasColorIcon = Test-Path $colorIconPath
        $hasOutlineIcon = Test-Path $outlineIconPath
        
        # Copy icons to a safe location before cleanup
        $iconTempDir = Join-Path $env:TEMP "bot-icons-temp"
        New-Item -ItemType Directory -Path $iconTempDir -Force | Out-Null
        if ($hasColorIcon) {
            Copy-Item $colorIconPath -Destination (Join-Path $iconTempDir "color.png")
        }
        if ($hasOutlineIcon) {
            Copy-Item $outlineIconPath -Destination (Join-Path $iconTempDir "outline.png")
        }
        
        # Deploy Function App
        Write-Host "`nDeploying Function App code..." -ForegroundColor Yellow
        $functionTempPath = Join-Path $tempDir "function-deploy"
        New-Item -ItemType Directory -Path $functionTempPath -Force | Out-Null
        
        # Copy function files - maintaining the structure
        # Copy the handleapproval folder
        $handleApprovalPath = Join-Path $functionTempPath "handleapproval"
        New-Item -ItemType Directory -Path $handleApprovalPath -Force | Out-Null
        Copy-Item "$tempDir\functions\handleapproval\*" $handleApprovalPath -Recurse
        
        # Copy root level function app files
        Copy-Item "$tempDir\functions\host.json" $functionTempPath
        Copy-Item "$tempDir\functions\package.json" $functionTempPath
        Copy-Item "$tempDir\functions\package-lock.json" $functionTempPath -ErrorAction SilentlyContinue
        
        # Note: We're not copying node_modules - Azure will run npm install
        
        # Create zip for function app
        $functionZipPath = Join-Path $tempDir "functionapp.zip"
        Compress-Archive -Path "$functionTempPath\*" -DestinationPath $functionZipPath -Force
        
        # Deploy to Function App
        az functionapp deployment source config-zip `
            -g $ResourceGroupName `
            -n $($deployment.properties.outputs.functionAppName.value) `
            --src $functionZipPath
        
        Write-Host "[OK] Function App code deployed" -ForegroundColor Green
        
        # Deploy Web App
        Write-Host "`nDeploying Web App code..." -ForegroundColor Yellow
        $webTempPath = Join-Path $tempDir "web-deploy"
        New-Item -ItemType Directory -Path $webTempPath -Force | Out-Null
        
        # Copy bot files (excluding functions folder)
        Copy-Item "$tempDir\*.js" $webTempPath
        Copy-Item "$tempDir\*.json" $webTempPath
        Copy-Item "$tempDir\web.config" $webTempPath -ErrorAction SilentlyContinue
        Copy-Item "$tempDir\*.png" $webTempPath -ErrorAction SilentlyContinue
        
        # Create zip for web app
        $webZipPath = Join-Path $tempDir "webapp.zip"
        Compress-Archive -Path "$webTempPath\*" -DestinationPath $webZipPath -Force
        
        # Deploy to Web App
        az webapp deployment source config-zip `
            --resource-group $ResourceGroupName `
            --name $($deployment.properties.outputs.webAppName.value) `
            --src $webZipPath
        
        Write-Host "[OK] Web App code deployed" -ForegroundColor Green
        
    } finally {
        # Cleanup temp directory
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    # Step 6: Get Function Key and update Web App
    Write-Host "`n6. Retrieving Function App key..." -ForegroundColor Green
    $functionAppName = $deployment.properties.outputs.functionAppName.value
    
    # Wait for function app to be ready
    Write-Host "Waiting 30 seconds for function app to be ready..." -ForegroundColor Yellow
    Start-Sleep -Seconds 30
    
    # Check deployment status first
    Write-Host "Checking Function App deployment status..." -ForegroundColor Yellow
    # Skip deployment status check as it's not needed for zip deployment
    
    # Check if functions are deployed
    Write-Host "Checking deployed functions..." -ForegroundColor Yellow
    try {
        $functions = az functionapp function list -g $ResourceGroupName -n $functionAppName -o json 2>$null | ConvertFrom-Json
        if ($functions.Count -eq 0) {
            Write-Host "[WARNING] No functions found in Function App. Deployment may still be in progress." -ForegroundColor Yellow
            Write-Host "Waiting an additional 3 minutes..." -ForegroundColor Yellow
            Start-Sleep -Seconds 180
            
            # Check again
            $functions = az functionapp function list -g $ResourceGroupName -n $functionAppName -o json 2>$null | ConvertFrom-Json
        }
        
        if ($functions.Count -gt 0) {
            Write-Host "Found $($functions.Count) function(s) deployed" -ForegroundColor Green
        }
    } catch {
        Write-Host "[WARNING] Could not check function status" -ForegroundColor Yellow
    }
    
    # Try to get function key
    try {
        $functionKey = az functionapp keys list `
            -g $ResourceGroupName `
            -n $functionAppName `
            --query "functionKeys.default" `
            -o tsv 2>$null
        
        if ($functionKey) {
            Write-Host "[OK] Retrieved function key" -ForegroundColor Green
            
            # Update Web App with function key
            Write-Host "`n6. Updating Web App with Function key..." -ForegroundColor Green
            az webapp config appsettings set `
                --resource-group $ResourceGroupName `
                --name $BotName `
                --settings "FUNCTIONAPP_KEY=$functionKey" | Out-Null
            
            Write-Host "[OK] Updated Web App settings" -ForegroundColor Green
        } else {
            Write-Host "[WARNING] Function key is empty. Function App may not be fully deployed." -ForegroundColor Yellow
            Write-Host "You can retrieve the key later with:" -ForegroundColor Yellow
            Write-Host "az functionapp keys list -g $ResourceGroupName -n $functionAppName --query `"functionKeys.default`" -o tsv" -ForegroundColor Cyan
        }
    } catch {
        Write-Host "[WARNING] Could not retrieve function key: $_" -ForegroundColor Yellow
        Write-Host "You can retrieve the key later with:" -ForegroundColor Yellow
        Write-Host "az functionapp keys list -g $ResourceGroupName -n $functionAppName --query `"functionKeys.default`" -o tsv" -ForegroundColor Cyan
    }
    
    # Step 7: Display Results
    Write-Host "`n=== Deployment Results ===" -ForegroundColor Cyan
    Write-Host "Bot ID: $appId" -ForegroundColor White
    Write-Host "Bot Endpoint: $($deployment.properties.outputs.botEndpoint.value)" -ForegroundColor White
    Write-Host "Function App: $($deployment.properties.outputs.functionAppName.value)" -ForegroundColor White
    Write-Host "Web App: $($deployment.properties.outputs.webAppName.value)" -ForegroundColor White
    
    # Step 8: Create Teams Manifest
    Write-Host "`n7. Creating Teams manifest..." -ForegroundColor Green
    $manifest = @{
        "`$schema" = "https://developer.microsoft.com/en-us/json-schemas/teams/v1.14/MicrosoftTeams.schema.json"
        "manifestVersion" = "1.14"
        "version" = "1.0.0"
        "id" = $appId
        "packageName" = "com.microsoft.teams.approvalbot"
        "developer" = @{
            "name" = "Approval Bot Team"
            "websiteUrl" = $deployment.properties.outputs.botEndpoint.value
            "privacyUrl" = "$($deployment.properties.outputs.botEndpoint.value)/privacy"
            "termsOfUseUrl" = "$($deployment.properties.outputs.botEndpoint.value)/termsofuse"
        }
        "name" = @{
            "short" = $BotName
            "full" = "$BotName - Approval Management"
        }
        "description" = @{
            "short" = "Manages approval requests for privileged access"
            "full" = "This bot helps manage and process approval requests for privileged access in a secure and efficient manner."
        }
        "icons" = @{
            "color" = "color.png"
            "outline" = "outline.png"
        }
        "accentColor" = "#FFFFFF"
        "bots" = @(
            @{
                "botId" = $appId
                "scopes" = @("team", "personal")
                "supportsFiles" = $false
                "isNotificationOnly" = $false
            }
        )
        "permissions" = @("messageTeamMembers")
        "validDomains" = @("$($deployment.properties.outputs.webAppName.value).azurewebsites.net")
    }
    
    # Save manifest.json in current directory
	$manifestJson = $manifest | ConvertTo-Json -Depth 10
	$manifestJson | Out-File -FilePath "manifest.json" -Encoding UTF8
	Write-Host "[OK] Created manifest.json" -ForegroundColor Green

	# Create Teams package zip if icons exist
	$iconTempDir = Join-Path $env:TEMP "bot-icons-temp"
	$colorIconExists = Test-Path (Join-Path $iconTempDir "color.png")
	$outlineIconExists = Test-Path (Join-Path $iconTempDir "outline.png")

	if ($colorIconExists -and $outlineIconExists) {
		# Create temp directory for package
		$packageTempDir = Join-Path $env:TEMP "teams-package-temp"
		New-Item -ItemType Directory -Path $packageTempDir -Force | Out-Null
		
		# Copy files to package directory
		Copy-Item "manifest.json" -Destination $packageTempDir
		Copy-Item (Join-Path $iconTempDir "color.png") -Destination $packageTempDir
		Copy-Item (Join-Path $iconTempDir "outline.png") -Destination $packageTempDir
		
		# Create zip in current directory
		$zipPath = "$BotName-teams-package.zip"
		if (Test-Path $zipPath) {
			Remove-Item $zipPath -Force
		}
		Compress-Archive -Path "$packageTempDir\*" -DestinationPath $zipPath -Force
		
		Write-Host "[OK] Created Teams package: $zipPath" -ForegroundColor Green
		
		# Cleanup
		Remove-Item -Path $packageTempDir -Recurse -Force -ErrorAction SilentlyContinue
		Remove-Item -Path $iconTempDir -Recurse -Force -ErrorAction SilentlyContinue
	} else {
		Write-Warning "Icon files not found. Teams package not created. Please add color.png and outline.png manually."
	}
    
    Write-Host "`n=== Next Steps ===" -ForegroundColor Cyan
    Write-Host "1. Enable Teams channel in Azure Portal for bot: $BotName" -ForegroundColor Yellow
    Write-Host "2. Upload the Teams app package to Microsoft Teams:" -ForegroundColor Yellow
    Write-Host "   - Use $BotName-teams-package.zip if created" -ForegroundColor Yellow
    Write-Host "   - Or use manifest.json with icon files manually" -ForegroundColor Yellow
    Write-Host "3. Add the bot to your team or chat" -ForegroundColor Yellow
    
    } else {
        Write-Error "Deployment failed with state: $($deployment.properties.provisioningState)"
        if ($deployment.properties.error) {
            Write-Error "Error details: $($deployment.properties.error.message)"
        }
        exit 1
    }
} else {
    Write-Error "Deployment command failed. Please check the error messages above."
    exit 1
}

# Cleanup temporary files
Remove-Item $parametersFile -Force -ErrorAction SilentlyContinue

Write-Host "`n[OK] Automated deployment completed!" -ForegroundColor Green