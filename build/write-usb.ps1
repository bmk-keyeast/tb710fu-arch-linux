# Write a raw disk image to one physical disk and verify by reading it back. Needs admin.
#   Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File write-usb.ps1
#     -Image C:\path\tb710fu-ssd.img -DiskNumber N -ExpectedSize <Get-Disk Size> -ExpectedSha <sha256>'
param(
	[Parameter(Mandatory)] [string]$Image,          # uncompressed .img
	[Parameter(Mandatory)] [int]$DiskNumber,        # Get-Disk number of the USB stick / SSD
	[Parameter(Mandatory)] [long]$ExpectedSize,     # exact Get-Disk Size, guards against the wrong disk
	[Parameter(Mandatory)] [string]$ExpectedSha,    # sha256 of the image (out/tb710fu-ssd.img.sha256)
	[string]$Log = "$env:TEMP\tb710fu-write-usb.log",
	[switch]$Quick                                  # skip the image hash and the readback (slow over \\wsl.localhost)
)
$ErrorActionPreference = "Stop"
Start-Transcript -Path $Log -Force | Out-Null
try {
	$d = Get-Disk -Number $DiskNumber
	if ($d.BusType -ne "USB" -or $d.Size -ne $ExpectedSize -or $d.IsBoot -or $d.IsSystem) {
		throw "disk $DiskNumber is not the expected USB disk ($($d.FriendlyName) $($d.BusType) $($d.Size))"
	}
	$imgLen = (Get-Item $Image).Length
	if ($imgLen -gt $d.Size -or $imgLen % 512) { throw "image size $imgLen does not fit / not sector aligned" }
	if (-not $Quick) {
		"image sha256 check..."
		if ((Get-FileHash $Image -Algorithm SHA256).Hash.ToLower() -ne $ExpectedSha.ToLower()) { throw "image hash mismatch" }
	}

	"clearing disk $DiskNumber ($($d.FriendlyName))"
	Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false

	$buf = New-Object byte[] (4MB)
	$src = [IO.File]::OpenRead($Image)
	$dst = New-Object IO.FileStream("\\.\PhysicalDrive$DiskNumber", [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
	$done = 0L; $t = [Diagnostics.Stopwatch]::StartNew()
	while (($n = $src.Read($buf, 0, $buf.Length)) -gt 0) {
		$dst.Write($buf, 0, $n); $done += $n
		if (($done / 4MB) % 128 -eq 0) { "{0:N0} / {1:N0} MiB  ({2:N1} MB/s)" -f ($done/1MB), ($imgLen/1MB), ($done/1MB/$t.Elapsed.TotalSeconds) }
	}
	$dst.Flush(); $src.Close()
	"written $done bytes in $([int]$t.Elapsed.TotalSeconds)s"
	if ($Quick) { $dst.Close(); Update-HostStorageCache; "DONE (not verified)"; return }
	"verifying..."

	$dst.Position = 0
	$sha = [Security.Cryptography.SHA256]::Create()
	$left = [long]$imgLen
	while ($left -gt 0) {
		$n = $dst.Read($buf, 0, [int][Math]::Min([long]$buf.Length, $left))
		$null = $sha.TransformBlock($buf, 0, $n, $null, 0); $left -= $n
	}
	$null = $sha.TransformFinalBlock($buf, 0, 0)
	$dst.Close()
	$got = ($sha.Hash | ForEach-Object { $_.ToString("x2") }) -join ""
	if ($got -ne $ExpectedSha.ToLower()) { throw "READBACK MISMATCH $got" }
	"READBACK OK $got"
	Update-HostStorageCache
	"DONE"
} catch {
	"FAILED: $_"
} finally {
	Stop-Transcript | Out-Null
}
