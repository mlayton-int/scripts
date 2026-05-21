#Set-ExecutionPolicy Bypass

# Required PS Modules
$modules = "Microsoft.Graph", "Microsoft.Graph.Beta"
# Output path for JSON files
$ExportPath = "C:\Temp"

# Check if required modules are installed
Write-Host "Checking if required PS modules are installed.."
foreach ($item in $modules) {
    if (Get-Module -ListAvailable -Name $item) {
        Write-Host "$item module is installed" -ForegroundColor Green
    }
    # Y/N Prompt for installing missing modules
    else {
        Write-Host "$item module does not appear to be installed" -ForegroundColor Red
        $choice = Read-Host "Would you like to install $item now? (y/n)"
        
        if ($choice -eq "y") {
            
            try {
                Install-Module -Name $item -AllowClobber -Force -Scope CurrentUser
            }
            catch {
               Write-Host "Error while trying to install module $item $($_.Exception.Message)" -ForegroundColor Red
            }
        }

        elseif ($choice -eq "n") {
            Write-Host "Skipping installation.."
        }

        else {
            Write-Host "Invalid selection. Skipping installation.." -ForegroundColor Red
        }
        
    }
}

# Check if the output folder exists
if (-not (Test-Path -Path $ExportPath -PathType Container)) {
    # Folder doesn't exist, create it
    Write-Host "Output folder $ExportPath does not exist" -ForegroundColor Yellow
    New-Item -Path $ExportPath -ItemType Directory -Force -Confirm | Out-Null
}

else {
    Write-Host "Output folder exists" -ForegroundColor Green
}

# Sign into MS Admin Center for company to export from, and connect to Microsoft Graph API
Connect-MgGraph -Scopes 'Policy.Read.All'

# Export path for CA policies
$ExportPath = "C:\temp\"

try {
    # Retrieve all conditional access policies from Microsoft Graph API
    $AllPolicies = Get-MgIdentityConditionalAccessPolicy -All

    if ($AllPolicies.Count -eq 0) {
        Write-Host "There are no CA policies found to export." -ForegroundColor Yellow
    }
    else {
        # Iterate through each policy
        foreach ($Policy in $AllPolicies) {
            try {
                # Get the display name of the policy
                $PolicyName = $Policy.DisplayName
            
                # Convert the policy object to JSON with a depth of 6
                $PolicyJSON = $Policy | ConvertTo-Json -Depth 6
            
                # Write the JSON to a file in the export path
                $PolicyJSON | Out-File "$ExportPath\$PolicyName.json" -Force
            
                # Print a success message for the policy backup
                Write-Host "Successfully backed up CA policy: $($PolicyName)" -ForegroundColor Green
            }
            catch {
                # Print an error message for the policy backup
                Write-Host "Error occurred while backing up CA policy: $($Policy.DisplayName). $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
}
catch {
    # Print a generic error message
    Write-Host "Error occurred: $($_.Exception.Message)" -ForegroundColor Red
}

# Open File Explorer at the specified file path
Invoke-Item -Path $ExportPath