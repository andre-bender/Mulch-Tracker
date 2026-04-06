# === KONFIGURATION ===
$source = Get-Location
$destination = "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\MulchTracker"
$allowedNames = @("*.lua", "*.toc")

try {
    # === CHECKS ===
    if (!(Test-Path $destination)) {
        Write-Host "Destination folder does not exist. Creating..." -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $destination -ErrorAction Stop | Out-Null
    }

    # === KOPIEREN ===

    Get-ChildItem -Path $source -File -Force | Where-Object {
        $item = $_
        $allowedNames | Where-Object { $item.Name -like $_ }
    } | Copy-Item -Destination $destination -Recurse -Force -ErrorAction Stop

    Write-Host "Done!" -ForegroundColor Green
}
catch {
    Write-Host "Copy failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}