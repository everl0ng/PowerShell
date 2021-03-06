<#
.SYNOPSIS
    Download BIOS package (regular package) matching computer model and manufacturer.

.DESCRIPTION
    This script will determine the model of the computer and manufacturer and then query the specified endpoint
    for ConfigMgr WebService for a list of Packages. It then sets the OSDDownloadDownloadPackages variable to include
    the PackageID property of a package matching the computer model. If multiple packages are detect, it will select
    most current one by the creation date of the packages.

.PARAMETER URI
    Set the URI for the ConfigMgr WebService.

.PARAMETER SecretKey
    Specify the known secret key for the ConfigMgr WebService.

.PARAMETER Filter
    Define a filter used when calling ConfigMgr WebService to only return objects matching the filter.

.EXAMPLE
    .\Invoke-CMDownloadBIOSPackage.ps1 -URI "http://CM01.domain.com/ConfigMgrWebService/ConfigMgr.asmx" -SecretKey "12345" -Filter "BIOS"

.NOTES
    FileName:    Invoke-CMDownloadBIOSPackage.ps1
    Author:      Nickolaj Andersen
    Contact:     @NickolajA
    Created:     2017-05-22
    Updated:     2017-05-22
    
    Version history:
    1.0.0 - (2017-05-22) Script created
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [parameter(Mandatory=$true, HelpMessage="Set the URI for the ConfigMgr WebService.")]
    [ValidateNotNullOrEmpty()]
    [string]$URI,

    [parameter(Mandatory=$true, HelpMessage="Specify the known secret key for the ConfigMgr WebService.")]
    [ValidateNotNullOrEmpty()]
    [string]$SecretKey,

    [parameter(Mandatory=$false, HelpMessage="Define a filter used when calling ConfigMgr WebService to only return objects matching the filter.")]
    [ValidateNotNullOrEmpty()]
    [string]$Filter = [System.String]::Empty
)
Begin {
    # Load Microsoft.SMS.TSEnvironment COM object
    try {
        $TSEnvironment = New-Object -ComObject Microsoft.SMS.TSEnvironment -ErrorAction Stop
    }
    catch [System.Exception] {
        Write-Warning -Message "Unable to construct Microsoft.SMS.TSEnvironment object" ; exit 1
    }
}
Process {
    # Functions
    function Write-CMLogEntry {
	    param(
		    [parameter(Mandatory=$true, HelpMessage="Value added to the log file.")]
		    [ValidateNotNullOrEmpty()]
		    [string]$Value,

		    [parameter(Mandatory=$true, HelpMessage="Severity for the log entry. 1 for Informational, 2 for Warning and 3 for Error.")]
		    [ValidateNotNullOrEmpty()]
            [ValidateSet("1", "2", "3")]
		    [string]$Severity,

		    [parameter(Mandatory=$false, HelpMessage="Name of the log file that the entry will written to.")]
		    [ValidateNotNullOrEmpty()]
		    [string]$FileName = "BIOSPackageDownload.log"
	    )
	    # Determine log file location
        $LogFilePath = Join-Path -Path $Script:TSEnvironment.Value("_SMSTSLogPath") -ChildPath $FileName

        # Construct time stamp for log entry
        $Time = -join @((Get-Date -Format "HH:mm:ss.fff"), "+", (Get-WmiObject -Class Win32_TimeZone | Select-Object -ExpandProperty Bias))

        # Construct date for log entry
        $Date = (Get-Date -Format "MM-dd-yyyy")

        # Construct context for log entry
        $Context = $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)

        # Construct final log entry
        $LogText = "<![LOG[$($Value)]LOG]!><time=""$($Time)"" date=""$($Date)"" component=""BIOSPackageDownloader"" context=""$($Context)"" type=""$($Severity)"" thread=""$($PID)"" file="""">"
	
	    # Add value to log file
        try {
	        Add-Content -Value $LogText -LiteralPath $LogFilePath -ErrorAction Stop
        }
        catch [System.Exception] {
            Write-Warning -Message "Unable to append log entry to BIOSPackageDownload.log file. Error message: $($_.Exception.Message)"
        }
    }

    # Write log file for script execution
    Write-CMLogEntry -Value "BIOS download package process initiated" -Severity 1

    # Determine manufacturer
    $ComputerManufacturer = (Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty Manufacturer).Trim()
    Write-CMLogEntry -Value "Manufacturer determined as: $($ComputerManufacturer)" -Severity 1

    # Determine manufacturer name and computer model
    switch -Wildcard ($ComputerManufacturer) {
        "*Dell*" {
            $ComputerManufacturer = "Dell"
            $ComputerModel = (Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty Model).Trim()
        }
    }
    Write-CMLogEntry -Value "Computer model determined as: $($ComputerModel)" -Severity 1
	
	# Get existing BIOS version
	$CurrentBIOSVersion = (Get-WmiObject -Class Win32_BIOS | Select-Object -ExpandProperty SMBIOSBIOSVersion).Trim()
	Write-CMLogEntry -Value "Current BIOS version determined as: $($CurrentBIOSVersion)" -Severity 1
	
    # Construct new web service proxy
    try {
        $WebService = New-WebServiceProxy -Uri $URI -ErrorAction Stop
    }
    catch [System.Exception] {
        Write-CMLogEntry -Value "Unable to establish a connection to ConfigMgr WebService. Error message: $($_.Exception.Message)" -Severity 3 ; exit 1
    }

    # Call web service for a list of packages
    try {
        $Packages = $WebService.GetCMPackage($SecretKey, "$($Filter)")
        Write-CMLogEntry -Value "Retrieved a total of $(($Packages | Measure-Object).Count) BIOS packages from web service" -Severity 1
    }
    catch [System.Exception] {
        Write-CMLogEntry -Value "An error occured while calling ConfigMgr WebService for a list of available packages. Error message: $($_.Exception.Message)" -Severity 3 ; exit 1
    }

    # Construct array list for matching packages
    $PackageList = New-Object -TypeName System.Collections.ArrayList

    # Set script error preference variable
    $ErrorActionPreference = "Stop"

    # Validate Dell system was detected
    if ($ComputerManufacturer -eq "Dell") {
        # Process packages returned from web service
        if ($Packages -ne $null) {
            # Add packages with matching criteria to list
            foreach ($Package in $Packages) {
                # Match model, manufacturer criteria
                if (($Package.PackageName -match $ComputerModel) -and ($ComputerManufacturer -match $Package.PackageManufacturer)) {                            
                        Write-CMLogEntry -Value "Match found for computer model and manufacturer: $($Package.PackageName) ($($Package.PackageID))" -Severity 1
                        $PackageList.Add($Package) | Out-Null
                    }
                    else {
                        Write-CMLogEntry -Value "Package does not meet computer model and manufacturer criteria: $($Package.PackageName) ($($Package.PackageID))" -Severity 2
                    }
                }

                # Process matching items in package list and set task sequence variable
                if ($PackageList -ne $null) {
                    # Determine the most current package from list
                    if ($PackageList.Count -eq 1) {
                        Write-CMLogEntry -Value "BIOS package list contains a single match, attempting to set task sequence variable" -Severity 1

                        # Attempt to set task sequence variable
                        try {
                            $TSEnvironment.Value("OSDDownloadDownloadPackages") = $($PackageList[0].PackageID)
                            Write-CMLogEntry -Value "Successfully set OSDDownloadDownloadPackages variable with PackageID: $($PackageList[0].PackageID)" -Severity 1
                        }
                        catch [System.Exception] {
                            Write-CMLogEntry -Value "An error occured while setting OSDDownloadDownloadPackages variable. Error message: $($_.Exception.Message)" -Severity 3 ; exit 1
                        }
                    }
                    elseif ($PackageList.Count -ge 2) {
                        Write-CMLogEntry -Value "BIOS package list contains multiple matches, attempting to set task sequence variable" -Severity 1

                        # Attempt to set task sequence variable
                        try {
                            $Package = $PackageList | Sort-Object -Property PackageCreated -Descending | Select-Object -First 1
                            $TSEnvironment.Value("OSDDownloadDownloadPackages") = $($Package[0].PackageID)
                            Write-CMLogEntry -Value "Successfully set OSDDownloadDownloadPackages variable with PackageID: $($Package[0].PackageID)" -Severity 1
                        }
                        catch [System.Exception] {
                            Write-CMLogEntry -Value "An error occured while setting OSDDownloadDownloadPackages variable. Error message: $($_.Exception.Message)" -Severity 3 ; exit 1
                        }
                    }
                    else {
                        Write-CMLogEntry -Value "Unable to determine a matching BIOS package from list since an unsupported count was returned from package list, bailing out" -Severity 2 ; exit 1
                    }
                }
                else {
                    Write-CMLogEntry -Value "Empty BIOS package list detected, bailing out" -Severity 2 ; exit 1
                }
            }
            else {
                Write-CMLogEntry -Value "BIOS package list returned from web service did not contain any objects matching the computer model and manufacturer, bailing out" -Severity 2 ; exit 1
            }
    }
    else {
        Write-CMLogEntry -Value "This script is supported on Dell systems only at this point, bailing out" -Severity 2 ; exit 1
    }
}