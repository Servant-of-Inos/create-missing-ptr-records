# Full script: Checks and creates PTR records for all A records in the forward zone.
# Automatic mode: No confirmations, all actions logged to CSV.
# Requirements: Import-Module DnsServer. Run as admin on Windows Server.

$ForwardZone = "domain.com"  # Forward zone name
$DNSServer = "dns-server.domain.com"  # DNS server FQDN
$CSVPath = "D:\DNS\DNS_PTR_Changes.csv"  # Path to CSV log file

# Function: Calculates dynamic TTL (remaining time until the end of the hour)
function Get-DynamicTTL {
    $Now = Get-Date
    $EndOfHour = $Now.AddHours(1).AddMinutes(-$Now.Minute).AddSeconds(-$Now.Second).AddMilliseconds(-$Now.Millisecond)
    $DynamicTTL = $EndOfHour - $Now
    return $DynamicTTL  # Returns TimeSpan, e.g., 00:37:00
}

# Function: Finds reverse zone for an IP (/24 > /16)
function Get-ReverseZoneForIP {
    param([string]$IP, [string]$Server)
    
    $octets = $IP -split '\.' | ForEach-Object { [int]$_ }
    if ($octets.Count -ne 4) { return $null }
    
    $candidates = @(
        @{Zone="$($octets[2]).$($octets[1]).$($octets[0]).in-addr.arpa"; Host="$($octets[3])"; Level=24},  # /24 zone
        @{Zone="$($octets[1]).$($octets[0]).in-addr.arpa"; Host="$($octets[3]).$($octets[2])"; Level=16}    # /16 zone
    )
    
    # Sort by specificity (/24 > /16)
    $sortedCandidates = $candidates | Sort-Object Level -Descending
    
    foreach ($cand in $sortedCandidates) {
        $zoneObj = Get-DnsServerZone -Name $cand.Zone -ComputerName $Server -ErrorAction SilentlyContinue
        if ($zoneObj) {
            return @{Zone = $cand.Zone; Host = $cand.Host; FullRevName = "$($cand.Host).$($cand.Zone)"}
        }
    }
    return $null  # No matching reverse zone found
}

# Create CSV headers if file doesn't exist
if (-not (Test-Path $CSVPath)) {
    $csvHeader = @("FQDN", "IP", "ReverseZone", "HostInZone", "Action", "Status", "ErrorMsg", "ScriptRunTime")
    $csvHeader | Out-File -FilePath $CSVPath -Encoding UTF8
}

# Get all A records from the forward zone (exclude SOA, NS, wildcard)
$A_Records = Get-DnsServerResourceRecord -ZoneName $ForwardZone -RRType A -ComputerName $DNSServer | 
             Where-Object { $_.HostName -ne '@' -and $_.HostName -ne '*' -and $_.RecordType -eq 'A' }

$processedCount = 0
$createdCount = 0
$skippedCount = 0
$errorCount = 0

Write-Host "Starting processing of $($A_Records.Count) A records in zone $ForwardZone..." -ForegroundColor Cyan
$startTime = Get-Date

foreach ($Record in $A_Records) {
    $FQDN = if ($Record.HostName -eq '@') { $ForwardZone } else { "$($Record.HostName).$ForwardZone" }
    $IP = $Record.RecordData.IPv4Address.IPAddressToString
    $processedCount++
    
    # Log initial processing
    $logEntry = [PSCustomObject]@{
        FQDN = $FQDN
        IP = $IP
        ReverseZone = ""
        HostInZone = ""
        Action = "Processing"
        Status = "In Progress"
        ErrorMsg = ""
        ScriptRunTime = $startTime.ToString("yyyy-MM-dd HH:mm:ss")
    }
    $logEntry | Export-Csv -Path $CSVPath -NoTypeInformation -Append -Encoding UTF8
    
    # Find reverse zone for IP
    $revInfo = Get-ReverseZoneForIP -IP $IP -Server $DNSServer
    if (-not $revInfo) {
        $logEntry.ReverseZone = "NO ZONE FOUND"
        $logEntry.Action = "Skipped"
        $logEntry.Status = "Error"
        $logEntry.ErrorMsg = "No matching reverse zone (/24 or /16)"
        $logEntry | Export-Csv -Path $CSVPath -NoTypeInformation -Append -Encoding UTF8
        $errorCount++
        Write-Host "[$processedCount/$($A_Records.Count)] Skipped $FQDN ($IP): No reverse zone." -ForegroundColor Yellow
        continue
    }
    
    # Check for existing PTR in the reverse zone
    $existingPTR = Get-DnsServerResourceRecord -ZoneName $revInfo.Zone -Name $revInfo.Host -RRType Ptr -ComputerName $DNSServer -ErrorAction SilentlyContinue
    $PTR_Name = if ($existingPTR) { $existingPTR.RecordData.PtrDomainName.TrimEnd('.') } else { $null }
    
    $action = if (-not $PTR_Name) { "Created" } elseif ($PTR_Name -ne $FQDN) { "Updated (Mismatch)" } else { "Skipped (OK)" }
    
    if ($action -eq "Skipped (OK)") {
        $logEntry.ReverseZone = $revInfo.Zone
        $logEntry.HostInZone = $revInfo.Host
        $logEntry.Action = "Skipped"
        $logEntry.Status = "Success"
        $logEntry.ErrorMsg = "PTR already exists and matches"
        $logEntry | Export-Csv -Path $CSVPath -NoTypeInformation -Append -Encoding UTF8
        $skippedCount++
        Write-Host "[$processedCount/$($A_Records.Count)] OK $FQDN ($IP): PTR already correct." -ForegroundColor Green
        continue
    }
    
    # Create/Update PTR with dynamic TTL and Timestamp using dnscmd
    $DynamicTTL = Get-DynamicTTL
    $TTLSeconds = [math]::Ceiling($DynamicTTL.TotalSeconds)  # Round to whole seconds
    # For fixed TTL (3600 seconds), uncomment: $TTLSeconds = 3600
    
    $logEntry.ReverseZone = $revInfo.Zone
    $logEntry.HostInZone = $revInfo.Host
    
    try {
        # Remove old PTR if mismatch
        if ($PTR_Name) {
            Remove-DnsServerResourceRecord -ZoneName $revInfo.Zone -Name $revInfo.Host -RRType Ptr -ComputerName $DNSServer -Force
        }
        
        # Create new PTR using dnscmd
        $FQDNWithDot = "$FQDN."
        $cmd = "dnscmd $DNSServer /RecordAdd $($revInfo.Zone) $($revInfo.Host) /Aging $TTLSeconds PTR $FQDNWithDot"
        $dnscmdOutput = Invoke-Expression $cmd 2>&1
        if ($LASTEXITCODE -eq 0) {
            $logEntry.Action = $action
            $logEntry.Status = "Success"
            $logEntry.ErrorMsg = "PTR created/updated with TTL $DynamicTTL"
            $createdCount++
            Write-Host "[$processedCount/$($A_Records.Count)] ✅ $action $FQDN ($IP) in $($revInfo.Zone) ($($revInfo.Host))" -ForegroundColor Green
        } else {
            throw "dnscmd failed: $dnscmdOutput"
        }
    }
    catch {
        $logEntry.Action = "Error"
        $logEntry.Status = "Error"
        $logEntry.ErrorMsg = $_.Exception.Message
        $errorCount++
        Write-Host "[$processedCount/$($A_Records.Count)] ❌ Error for $FQDN ($IP): $($_.Exception.Message)" -ForegroundColor Red
    }
    
    # Update CSV log
    $logEntry | Export-Csv -Path $CSVPath -NoTypeInformation -Append -Encoding UTF8
}

$endTime = Get-Date
$duration = $endTime - $startTime

Write-Host "`nProcessing completed!" -ForegroundColor Cyan
Write-Host "Total records: $processedCount" -ForegroundColor White
Write-Host "Created/Updated: $createdCount" -ForegroundColor Green
Write-Host "Skipped (OK): $skippedCount" -ForegroundColor Gray
Write-Host "Errors: $errorCount" -ForegroundColor Red
Write-Host "Execution time: $duration" -ForegroundColor White
Write-Host "Log file: $CSVPath" -ForegroundColor Yellow
Write-Host "Open CSV in Excel to review or fix issues." -ForegroundColor Yellow

# Optional: Clear cache for all reverse zones
Write-Host "`nClear cache for all reverse zones? (Y/N) — manual confirmation for safety" -ForegroundColor Cyan
$clearCache = Read-Host
if ($clearCache -eq 'Y' -or $clearCache -eq 'y') {
    Get-DnsServerZone -ComputerName $DNSServer | Where-Object { $_.IsReverseLookupZone } | ForEach-Object { 
        Clear-DnsServerCache -ZoneName $_.ZoneName -ComputerName $DNSServer -ErrorAction SilentlyContinue
    }
    Write-Host "Cache cleared for all reverse zones." -ForegroundColor Green
}