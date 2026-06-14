Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Load .NET assembly required for fast ZIP extraction and Anti ZIP-Bomb measures
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Check if ADB is available. If not, prompt the user to download and configure it.
$adbExists = Get-Command "adb.exe" -ErrorAction SilentlyContinue
if (-not $adbExists) {
    $msgResult = [System.Windows.Forms.MessageBox]::Show("The 'adb.exe' binary was not found in the system PATH.`n`nWould you like this tool to automatically download Android Platform Tools from Google and configure it for you?", "ADB Not Found", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    
    if ($msgResult -eq [System.Windows.Forms.DialogResult]::Yes) {
        $dlForm = New-Object System.Windows.Forms.Form
        $dlForm.Text = "Installation Process"
        $dlForm.Size = New-Object System.Drawing.Size(350, 120)
        $dlForm.StartPosition = "CenterScreen"
        $dlForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $dlForm.ControlBox = $false
        
        $dlLabel = New-Object System.Windows.Forms.Label
        $dlLabel.Text = "Downloading Android Platform Tools...`nPlease wait, this may take a minute."
        $dlLabel.Location = New-Object System.Drawing.Point(20, 25)
        $dlLabel.AutoSize = $true
        $dlForm.Controls.Add($dlLabel)
        
        $dlForm.Show()
        [System.Windows.Forms.Application]::DoEvents()
        
        try {
            $installDir = Join-Path $env:LOCALAPPDATA "Android"
            $platformToolsDir = Join-Path $installDir "platform-tools"
            $zipPath = Join-Path $env:TEMP "platform-tools.zip"
            $url = "https://dl.google.com/android/repository/platform-tools-latest-windows.zip"
            
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
            
            if (-not (Test-Path $installDir)) { New-Item -ItemType Directory -Path $installDir -Force | Out-Null }
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $installDir)
            
            $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
            if ($userPath -notmatch [regex]::Escape($platformToolsDir)) {
                $newPath = $userPath + ";$platformToolsDir"
                [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
                $env:PATH += ";$platformToolsDir"
            }
            
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            $dlForm.Close()
            $dlForm.Dispose()
            [void][System.Windows.Forms.MessageBox]::Show("Android Platform Tools successfully installed! The application will now start.", "Installation Success", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } catch {
            $dlForm.Close()
            $dlForm.Dispose()
            [void][System.Windows.Forms.MessageBox]::Show("Failed to download or install ADB: $($_.Exception.Message)`n`nPlease install it manually and restart the application.", "Download Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            exit
        }
    } else {
        exit
    }
}

# Import Windows APIs for custom dark mode title bar rendering.
try {
    if (-not ("ChihafuyuDwmApi" -as [type])) {
        $dwmCode = @'
        using System;
        using System.Runtime.InteropServices;
        public class ChihafuyuDwmApi {
            [DllImport("dwmapi.dll")]
            public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

            [DllImport("user32.dll")]
            public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
        }
'@
        Add-Type -TypeDefinition $dwmCode -ErrorAction Stop
    }
} catch {
    Write-Debug "Failed to initialize DWM API. Custom dark title bar rendering will be disabled."
}

# Force the window title bar to match the dark theme.
function Set-TitleBarTheme($targetForm, [bool]$IsDark) {
    try {
        if ($null -ne $targetForm -and $targetForm.Handle -ne [System.IntPtr]::Zero) {
            [int]$val = if ($IsDark) { 1 } else { 0 }
            $handle = $targetForm.Handle
            
            [ChihafuyuDwmApi]::DwmSetWindowAttribute($handle, 20, [ref]$val, 4) | Out-Null
            [ChihafuyuDwmApi]::DwmSetWindowAttribute($handle, 19, [ref]$val, 4) | Out-Null
            
            [ChihafuyuDwmApi]::SendMessage($handle, 0x0086, [IntPtr]0, [IntPtr]::Zero) | Out-Null
            [ChihafuyuDwmApi]::SendMessage($handle, 0x0086, [IntPtr]1, [IntPtr]::Zero) | Out-Null
        }
    } catch {
        Write-Debug "Title bar theme application failed."
    }
}

# Enable double buffering to prevent UI flickering during updates.
function Enable-DoubleBuffer($control) {
    try {
        $prop = $control.GetType().GetProperty("DoubleBuffered", [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)
        if ($null -ne $prop) { $prop.SetValue($control, $true) }
    } catch {
        Write-Debug "Double buffering activation failed."
    }
}

# Regex patterns for identifying Wi-Fi devices.
$script:PATTERN_WIFI_DEVICE = "\._adb-tls-connect\._tcp"
$script:PATTERN_IP_PORT = "\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}:\d+\b"

# Global variables for the Logcat viewer.
$global:activeLogcatForm = $null
$global:logcatProcess = $null
$script:logFile = ""
$script:logStream = $null
$script:logReader = $null
$script:logTimer = $null
$script:searchDebounceTimer = $null

# Clean up Logcat resources to prevent memory leaks and orphaned processes.
function Invoke-LogcatCleanup {
    if ($null -ne $script:searchDebounceTimer) { 
        $script:searchDebounceTimer.Stop()
        $script:searchDebounceTimer.Dispose()
        $script:searchDebounceTimer = $null
    }
    if ($null -ne $script:logTimer) { 
        $script:logTimer.Stop()
        $script:logTimer.Dispose()
        $script:logTimer = $null
    }
    if ($null -ne $script:logReader) { 
        try { $script:logReader.Dispose() } catch { }
        $script:logReader = $null 
    }
    if ($null -ne $script:logStream) { 
        try { $script:logStream.Dispose() } catch { }
        $script:logStream = $null 
    }
    if ($null -ne $global:logcatProcess -and -not $global:logcatProcess.HasExited) {
        Start-Process "taskkill.exe" -ArgumentList "/F /T /PID $($global:logcatProcess.Id)" -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
        try { $global:logcatProcess.Dispose() } catch { }
        $global:logcatProcess = $null
    }
    
    if (-not [string]::IsNullOrWhiteSpace($script:logFile)) {
        if (Test-Path $script:logFile -ErrorAction SilentlyContinue) { 
            Remove-Item $script:logFile -Force -ErrorAction SilentlyContinue 
        }
    }
}

# Main application setup.
$form = New-Object System.Windows.Forms.Form
$form.Text = "APK Installer & Uninstaller" 
$form.Size = New-Object System.Drawing.Size(520,640) 
$form.MinimumSize = New-Object System.Drawing.Size(520,640) 
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable 
$form.MaximizeBox = $true 
$form.StartPosition = "CenterScreen"
Enable-DoubleBuffer $form

$form.Add_HandleCreated({
    Set-TitleBarTheme $form $false
})

$menuStrip = New-Object System.Windows.Forms.MenuStrip

# Menu strip configuration.
$menuFile = New-Object System.Windows.Forms.ToolStripMenuItem("File")
$menuExit = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")
$menuExit.Add_Click({ $form.Close() })
[void]$menuFile.DropDownItems.Add($menuExit)

$menuSettings = New-Object System.Windows.Forms.ToolStripMenuItem("Settings")
$menuSource = New-Object System.Windows.Forms.ToolStripMenuItem("Source Connection")

$menuUsb = New-Object System.Windows.Forms.ToolStripMenuItem("USB Cable")
$menuUsb.Checked = $true 

$menuWifi = New-Object System.Windows.Forms.ToolStripMenuItem("Wireless (Local Wi-Fi)")
$menuWifi.Checked = $false

# Run ADB commands and capture the output safely using the bulletproof batch file architecture.
function Run-AdbCommand($arguments) {
    $tempGuid = [Guid]::NewGuid().ToString("N")
    $tmpBat = Join-Path ([System.IO.Path]::GetTempPath()) "adb_cmd_$tempGuid.bat"
    $tmpOut = Join-Path ([System.IO.Path]::GetTempPath()) "adb_out_$tempGuid.txt"
    $tmpErr = Join-Path ([System.IO.Path]::GetTempPath()) "adb_err_$tempGuid.txt"
    
    $resultOut = ""
    $resultErr = ""
    $proc = $null
    
    try {
        $batContent = "adb.exe $arguments > `"$tmpOut`" 2> `"$tmpErr`""
        Set-Content -Path $tmpBat -Value $batContent -Encoding Ascii
        
        $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$tmpBat`"" -WindowStyle Hidden -PassThru -ErrorAction Stop
        
        if ($null -ne $proc) {
            while (-not $proc.HasExited) {
                # This DoEvents loop is the heartbeat of the GUI. It prevents the app from freezing.
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 50
            }
        } else {
            Start-Sleep -Seconds 1
        }
        
        if (Test-Path $tmpOut) { $resultOut = [string](Get-Content $tmpOut -Raw -ErrorAction SilentlyContinue) }
        if (Test-Path $tmpErr) { $resultErr = [string](Get-Content $tmpErr -Raw -ErrorAction SilentlyContinue) }
    }
    catch {
        Write-Debug "ADB Process execution failed."
    }
    finally {
        if ($null -ne $proc) { 
            try { 
                if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
                $proc.Dispose() 
            } catch { }
        }
        if (Test-Path $tmpBat) { Remove-Item $tmpBat -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tmpOut) { Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tmpErr) { Remove-Item $tmpErr -Force -ErrorAction SilentlyContinue }
    }
    
    $result = @($resultOut, $resultErr).Where({ -not [string]::IsNullOrWhiteSpace($_) }) -join "`r`n"
    return $result.Trim()
}

# Find the currently connected device based on the selected mode (USB or Wi-Fi).
function Get-TargetDevice([bool]$IsWifiMode) {
    $devicesOut = Run-AdbCommand "devices"
    [string[]]$allLines = $devicesOut -split "`r?`n"
    [string[]]$validDevices = $allLines | Where-Object { $_ -match "`tdevice$" }
    
    if ($IsWifiMode) {
        $wifiDevs = @($validDevices | Where-Object { $_ -match $script:PATTERN_WIFI_DEVICE -or $_ -match $script:PATTERN_IP_PORT })
        if ($wifiDevs.Count -gt 0) { return ($wifiDevs[0] -split "`t")[0].Trim() }
    } else {
        $usbDevs = @($validDevices | Where-Object { $_ -notmatch $script:PATTERN_WIFI_DEVICE -and $_ -notmatch $script:PATTERN_IP_PORT })
        if ($usbDevs.Count -gt 0) { return ($usbDevs[0] -split "`t")[0].Trim() }
    }
    return ""
}

$menuUsb.Add_Click({
    if (-not $menuUsb.Checked) {
        $menuUsb.Checked = $true
        $menuWifi.Checked = $false
        Write-Log "--------------------------------"
        Write-Log "Switched to USB Cable mode."
        Write-Log "Disconnecting active wireless sessions..."
        $discResult = Run-AdbCommand "disconnect"
        Write-Log $discResult
    }
})

$menuWifi.Add_Click({
    Write-Log "--------------------------------"
    Write-Log "Switching to Wireless Mode..."
    Write-Log "Scanning network via mDNS (please wait 5 seconds)..."

    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    Run-AdbCommand "devices" | Out-Null
    Start-Sleep -Seconds 5

    $targetDev = Get-TargetDevice $true
    $autoDetected = -not [string]::IsNullOrEmpty($targetDev)

    $form.Cursor = [System.Windows.Forms.Cursors]::Default

    if ($autoDetected) {
        $menuUsb.Checked = $false
        $menuWifi.Checked = $true
        Write-Log "Success: Auto-detected wireless device -> $targetDev"
        [void][System.Windows.Forms.MessageBox]::Show("Wireless device automatically detected!`n`nDevice ID: $targetDev`n`nNo manual IP input is needed.", "mDNS Discovery Successful", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    } else {
        Write-Log "Notice: Auto-discovery failed or delayed."
        Write-Log "Launching Manual IP Fallback dialog..."

        $wifiForm = New-Object System.Windows.Forms.Form
        $wifiForm.Text = "Connect Wi-Fi Debugging"
        $wifiForm.Size = New-Object System.Drawing.Size(430, 200)
        $wifiForm.StartPosition = "CenterParent"
        $wifiForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $wifiForm.MaximizeBox = $false
        $wifiForm.MinimizeBox = $false
        Enable-DoubleBuffer $wifiForm

        $wifiForm.Add_HandleCreated({
            Set-TitleBarTheme $wifiForm $chkDarkMode.Checked
        })

        if ($chkDarkMode.Checked) {
            $wifiForm.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
            $wifiForm.ForeColor = [System.Drawing.Color]::White
        }

        $lblWifi = New-Object System.Windows.Forms.Label
        $lblWifi.Text = "Auto-discovery failed. Enter IP:Port manually, or click Retry to scan again.`nIf your device has never been connected to this computer before, click 'Pair Device'."
        $lblWifi.Location = New-Object System.Drawing.Point(20, 15)
        $lblWifi.Size = New-Object System.Drawing.Size(380, 50)
        $wifiForm.Controls.Add($lblWifi)

        $txtWifi = New-Object System.Windows.Forms.TextBox
        $txtWifi.Location = New-Object System.Drawing.Point(20, 70)
        $txtWifi.Size = New-Object System.Drawing.Size(370, 20)
        if ($chkDarkMode.Checked) {
            $txtWifi.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
            $txtWifi.ForeColor = [System.Drawing.Color]::White
        }
        $wifiForm.Controls.Add($txtWifi)

        $btnRetry = New-Object System.Windows.Forms.Button
        $btnRetry.Text = "Retry"
        $btnRetry.Location = New-Object System.Drawing.Point(20, 105)
        $btnRetry.Size = New-Object System.Drawing.Size(100, 28)
        
        $btnPair = New-Object System.Windows.Forms.Button
        $btnPair.Text = "Pair Device"
        $btnPair.Location = New-Object System.Drawing.Point(130, 105)
        $btnPair.Size = New-Object System.Drawing.Size(120, 28)

        $btnOk = New-Object System.Windows.Forms.Button
        $btnOk.Text = "Connect"
        $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $btnOk.Location = New-Object System.Drawing.Point(260, 105)
        $btnOk.Size = New-Object System.Drawing.Size(130, 28)
        
        if ($chkDarkMode.Checked) {
            $flatBtns = @($btnRetry, $btnPair, $btnOk)
            foreach ($b in $flatBtns) {
                $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
                $b.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 65)
                $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
                $b.ForeColor = [System.Drawing.Color]::White
            }
        }
        
        $wifiForm.Controls.AddRange(@($btnRetry, $btnPair, $btnOk))
        $wifiForm.AcceptButton = $btnOk

        # Display the pairing dialog for Android 11+ wireless debugging.
        $btnPair.Add_Click({
            $pairForm = New-Object System.Windows.Forms.Form
            $pairForm.Text = "Pair New Device"
            $pairForm.Size = New-Object System.Drawing.Size(360, 230)
            $pairForm.StartPosition = "CenterParent"
            $pairForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
            $pairForm.MaximizeBox = $false
            $pairForm.MinimizeBox = $false
            Enable-DoubleBuffer $pairForm

            $pairForm.Add_HandleCreated({
                Set-TitleBarTheme $pairForm $chkDarkMode.Checked
            })

            if ($chkDarkMode.Checked) {
                $pairForm.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
                $pairForm.ForeColor = [System.Drawing.Color]::White
            }

            $lblPairDesc = New-Object System.Windows.Forms.Label
            $lblPairDesc.Text = "Enter the Pairing IP:Port and the 6-digit code`nshown on your Android device."
            $lblPairDesc.Location = New-Object System.Drawing.Point(20, 15)
            $lblPairDesc.Size = New-Object System.Drawing.Size(300, 35)
            $pairForm.Controls.Add($lblPairDesc)

            $lblPairIp = New-Object System.Windows.Forms.Label
            $lblPairIp.Text = "Pairing IP:Port"
            $lblPairIp.Location = New-Object System.Drawing.Point(20, 60)
            $lblPairIp.Size = New-Object System.Drawing.Size(100, 20)
            $pairForm.Controls.Add($lblPairIp)

            $txtPairIp = New-Object System.Windows.Forms.TextBox
            $txtPairIp.Location = New-Object System.Drawing.Point(120, 58)
            $txtPairIp.Size = New-Object System.Drawing.Size(200, 20)

            $lblPairCode = New-Object System.Windows.Forms.Label
            $lblPairCode.Text = "6-Digit Code"
            $lblPairCode.Location = New-Object System.Drawing.Point(20, 95)
            $lblPairCode.Size = New-Object System.Drawing.Size(100, 20)
            $pairForm.Controls.Add($lblPairCode)

            $txtPairCode = New-Object System.Windows.Forms.TextBox
            $txtPairCode.Location = New-Object System.Drawing.Point(120, 93)
            $txtPairCode.Size = New-Object System.Drawing.Size(200, 20)

            if ($chkDarkMode.Checked) {
                $txtPairIp.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
                $txtPairIp.ForeColor = [System.Drawing.Color]::White
                $txtPairCode.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
                $txtPairCode.ForeColor = [System.Drawing.Color]::White
            }
            
            $pairForm.Controls.AddRange(@($txtPairIp, $txtPairCode))

            $btnExecutePair = New-Object System.Windows.Forms.Button
            $btnExecutePair.Text = "Execute Pair"
            $btnExecutePair.Location = New-Object System.Drawing.Point(190, 140)
            $btnExecutePair.Size = New-Object System.Drawing.Size(130, 28)

            if ($chkDarkMode.Checked) {
                $btnExecutePair.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
                $btnExecutePair.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 65)
                $btnExecutePair.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
                $btnExecutePair.ForeColor = [System.Drawing.Color]::White
            }

            $btnExecutePair.Add_Click({
                $ip = $txtPairIp.Text.Trim()
                $code = $txtPairCode.Text.Trim()

                if ([string]::IsNullOrWhiteSpace($ip) -or [string]::IsNullOrWhiteSpace($code)) {
                    [void][System.Windows.Forms.MessageBox]::Show("Please enter both the IP:Port and the pairing code.", "Input Required", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                    return
                }

                $pairForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
                $btnExecutePair.Enabled = $false

                Write-Log "Attempting to pair with $ip using code $code..."
                $pairResult = Run-AdbCommand "pair $ip $code"
                Write-Log "Pairing Result: $pairResult"

                $pairForm.Cursor = [System.Windows.Forms.Cursors]::Default
                $btnExecutePair.Enabled = $true

                if ($pairResult -match "Successfully paired") {
                    [void][System.Windows.Forms.MessageBox]::Show("Device paired successfully!`n`nYou can now close this window and enter the Connection IP:Port in the main dialog to connect.", "Pairing Successful", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
                    $pairForm.Close()
                } else {
                    [void][System.Windows.Forms.MessageBox]::Show("Pairing failed. Please verify the IP, Port, and Code are correct and the device is on the same network.`n`nADB Output:`n$pairResult", "Pairing Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
                }
            })

            $pairForm.Controls.Add($btnExecutePair)
            $pairForm.AcceptButton = $btnExecutePair

            [void]$pairForm.ShowDialog()
            $pairForm.Dispose()
        })

        $btnRetry.Add_Click({
            $wifiForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $btnRetry.Enabled = $false
            $btnPair.Enabled = $false
            $btnOk.Enabled = $false
            $txtWifi.Enabled = $false

            Write-Log "Retrying mDNS auto-discovery (wait 5 seconds)..."
            Run-AdbCommand "devices" | Out-Null
            Start-Sleep -Seconds 5 

            $retryDev = Get-TargetDevice $true
            $retryDetected = -not [string]::IsNullOrEmpty($retryDev)

            $wifiForm.Cursor = [System.Windows.Forms.Cursors]::Default

            if ($retryDetected) {
                $menuUsb.Checked = $false
                $menuWifi.Checked = $true
                Write-Log "Success: Auto-detected wireless device on retry -> $retryDev"
                [void][System.Windows.Forms.MessageBox]::Show("Device successfully detected on retry!`n`nDevice ID: $retryDev", "Discovery Successful", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
                
                $wifiForm.DialogResult = [System.Windows.Forms.DialogResult]::Ignore
                $wifiForm.Close()
            } else {
                Write-Log "Retry failed. Device still not found."
                $btnRetry.Enabled = $true
                $btnPair.Enabled = $true
                $btnOk.Enabled = $true
                $txtWifi.Enabled = $true
                [void][System.Windows.Forms.MessageBox]::Show("Still cannot find the device automatically.`n`nPlease ensure your Android device and PC are on the same network and Wireless Debugging is currently active.", "Retry Failed", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            }
        })

        try {
            if ($wifiForm.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $ipAddress = $txtWifi.Text.Trim()
                if (-not [string]::IsNullOrWhiteSpace($ipAddress)) {
                    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
                    Write-Log "Connecting to $ipAddress..."
                    $connResult = Run-AdbCommand "connect $ipAddress"
                    Write-Log "Result: $connResult"
                    $form.Cursor = [System.Windows.Forms.Cursors]::Default
                    
                    if ($connResult -match "connected" -or $connResult -match "already connected") {
                        $menuUsb.Checked = $false
                        $menuWifi.Checked = $true
                        Write-Log "Success: Switched to Wireless mode manually."
                    } else {
                        [void][System.Windows.Forms.MessageBox]::Show("Failed to connect to $ipAddress. Please check your network and ensure Wireless Debugging is active.`n`nIf this is a new device, click 'Pair Device' first.", "Connection Failed", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                    }
                }
            }
        }
        finally {
            $wifiForm.Dispose()
        }
    }
})

[void]$menuSource.DropDownItems.Add($menuUsb)
[void]$menuSource.DropDownItems.Add($menuWifi)
[void]$menuSettings.DropDownItems.Add($menuSource)

# Tools menu.
$menuTools = New-Object System.Windows.Forms.ToolStripMenuItem("Tools")
$menuLogcat = New-Object System.Windows.Forms.ToolStripMenuItem("Capture Logcat")

$menuLogcat.Add_Click({

    # Ensure only one Logcat window is open at a time.
    if ($null -ne $global:activeLogcatForm -and -not $global:activeLogcatForm.IsDisposed) {
        if ($global:activeLogcatForm.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
            $global:activeLogcatForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        }
        $global:activeLogcatForm.BringToFront()
        return
    }
    
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $targetDev = Get-TargetDevice $menuWifi.Checked
    $form.Cursor = [System.Windows.Forms.Cursors]::Default

    if ([string]::IsNullOrEmpty($targetDev)) {
        $modeStr = if ($menuWifi.Checked) { "Wireless" } else { "USB Cable" }
        [void][System.Windows.Forms.MessageBox]::Show("No active $modeStr device detected! Please connect your device or switch modes in the Settings menu.", "Device Not Found", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    
    # Lock in the device ID so it remains consistent while reading logs.
    $script:targetDevLocked = $targetDev

    $global:activeLogcatForm = New-Object System.Windows.Forms.Form
    $global:activeLogcatForm.Text = "Logcat Viewer - Device: $script:targetDevLocked"
    $global:activeLogcatForm.Size = New-Object System.Drawing.Size(880, 500)
    $global:activeLogcatForm.StartPosition = "CenterScreen"
    $global:activeLogcatForm.MinimumSize = New-Object System.Drawing.Size(880, 400)
    Enable-DoubleBuffer $global:activeLogcatForm

    $global:activeLogcatForm.Add_HandleCreated({
        Set-TitleBarTheme $global:activeLogcatForm $chkDarkMode.Checked
    })

    # Adjust layout coordinates and set manual height for the Search box for perfect alignment.
    $script:cmbLevel = New-Object System.Windows.Forms.ComboBox
    $script:cmbLevel.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $script:cmbLevel.Items.AddRange(@("Verbose (*:V)", "Debug (*:D)", "Info (*:I)", "Warning (*:W)", "Error (*:E)", "Fatal (*:F)"))
    $script:cmbLevel.SelectedIndex = 0
    $script:cmbLevel.Location = New-Object System.Drawing.Point(10, 15)
    $script:cmbLevel.Size = New-Object System.Drawing.Size(110, 25)

    $script:chkCrash = New-Object System.Windows.Forms.CheckBox
    $script:chkCrash.Text = "Detect App Crashes Only (AndroidRuntime)"
    $script:chkCrash.AutoSize = $true
    $script:chkCrash.Location = New-Object System.Drawing.Point(125, 18)

    $script:lblSearch = New-Object System.Windows.Forms.Label
    $script:lblSearch.Text = "Search:"
    $script:lblSearch.AutoSize = $true
    $script:lblSearch.Location = New-Object System.Drawing.Point(375, 20)

    $script:txtSearchLog = New-Object System.Windows.Forms.TextBox
    $script:txtSearchLog.AutoSize = $false # Disable auto-size to force a 25px height.
    $script:txtSearchLog.Location = New-Object System.Drawing.Point(425, 15)
    $script:txtSearchLog.Size = New-Object System.Drawing.Size(105, 25)
    
    $script:ttSearch = New-Object System.Windows.Forms.ToolTip
    $script:ttSearch.SetToolTip($script:txtSearchLog, "Type to search and highlight keywords in the log")

    $script:btnStartLogcat = New-Object System.Windows.Forms.Button
    $script:btnStartLogcat.Text = "Start Capture"
    $script:btnStartLogcat.Location = New-Object System.Drawing.Point(540, 15)
    $script:btnStartLogcat.Size = New-Object System.Drawing.Size(85, 25)

    $script:btnStopLogcat = New-Object System.Windows.Forms.Button
    $script:btnStopLogcat.Text = "Stop"
    $script:btnStopLogcat.Location = New-Object System.Drawing.Point(630, 15)
    $script:btnStopLogcat.Size = New-Object System.Drawing.Size(60, 25)
    $script:btnStopLogcat.Enabled = $false

    $script:btnClearLogcat = New-Object System.Windows.Forms.Button
    $script:btnClearLogcat.Text = "Clear"
    $script:btnClearLogcat.Location = New-Object System.Drawing.Point(695, 15)
    $script:btnClearLogcat.Size = New-Object System.Drawing.Size(55, 25)

    $script:btnExportLogcat = New-Object System.Windows.Forms.Button
    $script:btnExportLogcat.Text = "Export Logcat"
    $script:btnExportLogcat.Location = New-Object System.Drawing.Point(755, 15)
    $script:btnExportLogcat.Size = New-Object System.Drawing.Size(95, 25)

    $script:rtbLogs = New-Object System.Windows.Forms.RichTextBox
    $script:rtbLogs.Location = New-Object System.Drawing.Point(10, 50)
    $script:rtbLogs.Size = New-Object System.Drawing.Size(840, 395)
    $script:rtbLogs.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $script:rtbLogs.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:rtbLogs.ReadOnly = $true
    $script:rtbLogs.WordWrap = $false
    $script:rtbLogs.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::ForcedBoth

    if ($chkDarkMode.Checked) {
        $global:activeLogcatForm.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
        $global:activeLogcatForm.ForeColor = [System.Drawing.Color]::White
        $script:chkCrash.ForeColor = [System.Drawing.Color]::White
        $script:lblSearch.ForeColor = [System.Drawing.Color]::White
        
        $script:txtSearchLog.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
        $script:txtSearchLog.ForeColor = [System.Drawing.Color]::White
        
        $script:rtbLogs.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
        $script:rtbLogs.ForeColor = [System.Drawing.Color]::LightGray

        $script:cmbLevel.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
        $script:cmbLevel.ForeColor = [System.Drawing.Color]::White

        $flatBtns = @($script:btnStartLogcat, $script:btnStopLogcat, $script:btnClearLogcat, $script:btnExportLogcat)
        foreach ($btn in $flatBtns) {
            $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $btn.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 65)
            $btn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
            $btn.ForeColor = [System.Drawing.Color]::White
        }
    } else {
        $script:lblSearch.ForeColor = [System.Drawing.SystemColors]::ControlText
    }

    $global:activeLogcatForm.Controls.AddRange(@($script:cmbLevel, $script:chkCrash, $script:lblSearch, $script:txtSearchLog, $script:btnStartLogcat, $script:btnStopLogcat, $script:btnClearLogcat, $script:btnExportLogcat, $script:rtbLogs))

    # Create a debounce timer to prevent the app from freezing while the user is typing.
    $script:searchDebounceTimer = New-Object System.Windows.Forms.Timer
    $script:searchDebounceTimer.Interval = 600
    
    $script:searchDebounceTimer.Add_Tick({
        $script:searchDebounceTimer.Stop()
        $keyword = $script:txtSearchLog.Text
        
        $script:rtbLogs.SuspendLayout()
        $savedStart = $script:rtbLogs.SelectionStart
        $savedLength = $script:rtbLogs.SelectionLength
        
        # Clear existing highlights quickly
        $script:rtbLogs.SelectAll()
        if ($chkDarkMode.Checked) {
            $script:rtbLogs.SelectionBackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
            $script:rtbLogs.SelectionColor = [System.Drawing.Color]::LightGray
        } else {
            $script:rtbLogs.SelectionBackColor = [System.Drawing.SystemColors]::Window
            $script:rtbLogs.SelectionColor = [System.Drawing.SystemColors]::WindowText
        }
        
        if (-not [string]::IsNullOrWhiteSpace($keyword)) {
            $idx = 0
            $matchCount = 0
            # Limit highlight processing to 1000 items to guarantee the UI never freezes on massive log buffers.
            while ($idx -lt $script:rtbLogs.TextLength -and $matchCount -lt 1000) {
                $found = $script:rtbLogs.Find($keyword, $idx, [System.Windows.Forms.RichTextBoxFinds]::None)
                if ($found -ne -1) {
                    $script:rtbLogs.SelectionStart = $found
                    $script:rtbLogs.SelectionLength = $keyword.Length
                    
                    if ($chkDarkMode.Checked) {
                        $script:rtbLogs.SelectionBackColor = [System.Drawing.Color]::DodgerBlue
                        $script:rtbLogs.SelectionColor = [System.Drawing.Color]::White
                    } else {
                        $script:rtbLogs.SelectionBackColor = [System.Drawing.Color]::Yellow
                        $script:rtbLogs.SelectionColor = [System.Drawing.Color]::Black
                    }
                    
                    $idx = $found + $keyword.Length
                    $matchCount++
                } else {
                    break
                }
            }
        }
        
        $script:rtbLogs.SelectionStart = $savedStart
        $script:rtbLogs.SelectionLength = $savedLength
        $script:rtbLogs.ResumeLayout()
    })

    # Reset the timer on every keystroke. Search only begins when the user stops typing.
    $script:txtSearchLog.Add_TextChanged({
        if ($null -ne $script:searchDebounceTimer) {
            $script:searchDebounceTimer.Stop()
            $script:searchDebounceTimer.Start()
        }
    })

    $script:btnStartLogcat.Add_Click({
        # Lock the buttons immediately to prevent concurrent execution and app crashes.
        $script:btnStartLogcat.Enabled = $false
        $script:cmbLevel.Enabled = $false
        $script:chkCrash.Enabled = $false
        $script:txtSearchLog.Enabled = $false

        $script:rtbLogs.Clear()
        $script:rtbLogs.AppendText("Initializing ADB Logcat stream...`n")
        
        Run-AdbCommand "-s `"$($script:targetDevLocked)`" logcat -c" | Out-Null
        
        $levelParam = "*:V"
        switch ($script:cmbLevel.SelectedIndex) {
            0 { $levelParam = "*:V" }
            1 { $levelParam = "*:D" }
            2 { $levelParam = "*:I" }
            3 { $levelParam = "*:W" }
            4 { $levelParam = "*:E" }
            5 { $levelParam = "*:F" }
        }

        $argList = @("-s", $script:targetDevLocked, "logcat")

        if ($script:chkCrash.Checked) {
            $argList += "AndroidRuntime:E"
            $argList += "*:S"
            $script:rtbLogs.AppendText("Mode: App Crash Detection (AndroidRuntime)`n")
        } else {
            $argList += $levelParam
            $script:rtbLogs.AppendText("Mode: Standard Stream (Filter: $levelParam)`n")
        }
        $script:rtbLogs.AppendText("------------------------------------------------`n")

        Invoke-LogcatCleanup

        $tempGuid = [Guid]::NewGuid().ToString("N").Substring(0,8)
        $script:logFile = Join-Path ([System.IO.Path]::GetTempPath()) "adb_logcat_proxy_$tempGuid.log"

        try {
            # Since logcat spawns an endless stream, we must STILL use native Start-Process here 
            # (bypassing the .bat file) to properly pipe the output to our $script:logFile stream reader.
            # We don't use -Wait here, so it safely runs in the background.
            $global:logcatProcess = Start-Process -FilePath "adb.exe" -ArgumentList $argList -RedirectStandardOutput $script:logFile -WindowStyle Hidden -PassThru -ErrorAction Stop
            
            $waitTicks = 0
            while (-not (Test-Path $script:logFile -ErrorAction SilentlyContinue) -and $waitTicks -lt 15) {
                Start-Sleep -Milliseconds 100
                $waitTicks++
            }
            
            if (Test-Path $script:logFile -ErrorAction SilentlyContinue) {
                $script:logStream = New-Object System.IO.FileStream($script:logFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                $script:logReader = New-Object System.IO.StreamReader($script:logStream, [System.Text.Encoding]::Default, $true)
                
                $script:logTimer = New-Object System.Windows.Forms.Timer
                $script:logTimer.Interval = 200

                $script:logTimer.Add_Tick({
                    if ($null -ne $script:logReader) {
                        $newLogs = New-Object System.Text.StringBuilder
                        $readCount = 0
                        
                        while (($line = $script:logReader.ReadLine()) -ne $null -and $readCount -lt 2000) {
                            $cleanLine = $line.Replace("`0", "")
                            [void]$newLogs.AppendLine($cleanLine)
                            $readCount++
                        }

                        if ($newLogs.Length -gt 0) {
                            # Limit the log text length to prevent OutOfMemory exceptions.
                            if ($script:rtbLogs.TextLength -gt 500000) {
                                $script:rtbLogs.Clear()
                                $script:rtbLogs.AppendText("--- BUFFER CLEARED TO PREVENT MEMORY OVERLOAD ---`n")
                            }
                            
                            $script:rtbLogs.SuspendLayout()
                            $startIndex = $script:rtbLogs.TextLength
                            $script:rtbLogs.AppendText($newLogs.ToString())
                            
                            # Scans only the newly appended text to apply active highlights efficiently.
                            $keyword = $script:txtSearchLog.Text
                            if (-not [string]::IsNullOrWhiteSpace($keyword)) {
                                $idx = $startIndex
                                $matchCount = 0
                                while ($idx -lt $script:rtbLogs.TextLength -and $matchCount -lt 50) {
                                    $found = $script:rtbLogs.Find($keyword, $idx, [System.Windows.Forms.RichTextBoxFinds]::None)
                                    if ($found -ne -1) {
                                        $script:rtbLogs.SelectionStart = $found
                                        $script:rtbLogs.SelectionLength = $keyword.Length
                                        if ($chkDarkMode.Checked) {
                                            $script:rtbLogs.SelectionBackColor = [System.Drawing.Color]::DodgerBlue
                                            $script:rtbLogs.SelectionColor = [System.Drawing.Color]::White
                                        } else {
                                            $script:rtbLogs.SelectionBackColor = [System.Drawing.Color]::Yellow
                                            $script:rtbLogs.SelectionColor = [System.Drawing.Color]::Black
                                        }
                                        $idx = $found + $keyword.Length
                                        $matchCount++
                                    } else {
                                        break
                                    }
                                }
                            }
                            
                            $script:rtbLogs.SelectionStart = $script:rtbLogs.Text.Length
                            $script:rtbLogs.ScrollToCaret()
                            $script:rtbLogs.ResumeLayout()
                        }
                    }
                })

                $script:logTimer.Start()
                $script:btnStopLogcat.Enabled = $true
                $script:txtSearchLog.Enabled = $true
            } else {
                $script:rtbLogs.AppendText("`nError: Failed to locate proxy file stream.")
                $script:btnStartLogcat.Enabled = $true
                $script:cmbLevel.Enabled = $true
                $script:chkCrash.Enabled = $true
                $script:txtSearchLog.Enabled = $true
            }
        } catch {
            $script:rtbLogs.AppendText("`nError starting adb process: $_")
            $script:btnStartLogcat.Enabled = $true
            $script:cmbLevel.Enabled = $true
            $script:chkCrash.Enabled = $true
            $script:txtSearchLog.Enabled = $true
        }
    })

    $script:btnStopLogcat.Add_Click({
        Invoke-LogcatCleanup
        
        $script:rtbLogs.AppendText("`n------------------------------------------------`n")
        $script:rtbLogs.AppendText("Logcat capture stopped.`n")
        $script:rtbLogs.SelectionStart = $script:rtbLogs.Text.Length
        $script:rtbLogs.ScrollToCaret()
        
        $script:btnStartLogcat.Enabled = $true
        $script:cmbLevel.Enabled = $true
        $script:chkCrash.Enabled = $true
        $script:btnStopLogcat.Enabled = $false
    })

    $script:btnClearLogcat.Add_Click({
        $script:rtbLogs.Clear()
    })

    $script:btnExportLogcat.Add_Click({
        if ([string]::IsNullOrWhiteSpace($script:rtbLogs.Text)) {
            [void][System.Windows.Forms.MessageBox]::Show("The logcat buffer is empty.", "Information", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }

        $sfd = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.FileName = "logcat_$([DateTime]::Now.ToString('yyyyMMdd_HHmmss')).txt"
        $sfd.Filter = "Text Files (*.txt)|*.txt|Log Files (*.log)|*.log|All Files (*.*)|*.*"
        
        if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Set-Content -Path $sfd.FileName -Value $script:rtbLogs.Text -Encoding UTF8 -ErrorAction SilentlyContinue
            [void][System.Windows.Forms.MessageBox]::Show("Logcat saved successfully!", "Success", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        }
        $sfd.Dispose()
    })

    # Ensure proper cleanup when the user closes the Logcat window.
    $global:activeLogcatForm.Add_FormClosing({
        Invoke-LogcatCleanup
    })

    $global:activeLogcatForm.Add_FormClosed({
        if ($null -ne $script:searchDebounceTimer) {
            $script:searchDebounceTimer.Stop()
            $script:searchDebounceTimer.Dispose()
            $script:searchDebounceTimer = $null
        }
        $global:activeLogcatForm.Dispose()
        $global:activeLogcatForm = $null
    })

    $global:activeLogcatForm.Show()
})

[void]$menuTools.DropDownItems.Add($menuLogcat)

# =======================================================================================
# NEW FEATURE: PULL APPS (Extract installed apps/games from device to PC)
# =======================================================================================
$menuPullApp = New-Object System.Windows.Forms.ToolStripMenuItem("Pull Apps")

$menuPullApp.Add_Click({
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $targetDev = Get-TargetDevice $menuWifi.Checked
    $form.Cursor = [System.Windows.Forms.Cursors]::Default

    if ([string]::IsNullOrEmpty($targetDev)) {
        $modeStr = if ($menuWifi.Checked) { "Wireless" } else { "USB Cable" }
        [void][System.Windows.Forms.MessageBox]::Show("No active $modeStr device detected! Please connect your device or switch modes in the Settings menu.", "Device Not Found", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    $script:targetDevLocked = $targetDev

    $pullForm = New-Object System.Windows.Forms.Form
    $pullForm.Text = "Pull Apps to PC - Device: $script:targetDevLocked"
    $pullForm.Size = New-Object System.Drawing.Size(460, 560)
    $pullForm.StartPosition = "CenterParent"
    $pullForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $pullForm.MaximizeBox = $false
    $pullForm.MinimizeBox = $false
    Enable-DoubleBuffer $pullForm

    $pullForm.Add_HandleCreated({
        Set-TitleBarTheme $pullForm $chkDarkMode.Checked
    })

    if ($chkDarkMode.Checked) {
        $pullForm.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
        $pullForm.ForeColor = [System.Drawing.Color]::White
    }

    $lblDest = New-Object System.Windows.Forms.Label
    $lblDest.Text = "Destination Folder (Where to save the apps):"
    $lblDest.Location = New-Object System.Drawing.Point(20, 15)
    $lblDest.Size = New-Object System.Drawing.Size(400, 20)
    $pullForm.Controls.Add($lblDest)

    $txtDest = New-Object System.Windows.Forms.TextBox
    # Adjusting layout constraints down a bit to prevent window frame text clipping
    $txtDest.Location = New-Object System.Drawing.Point(20, 42)
    $txtDest.Size = New-Object System.Drawing.Size(320, 20)
    if ($chkDarkMode.Checked) {
        $txtDest.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
        $txtDest.ForeColor = [System.Drawing.Color]::White
    }
    $pullForm.Controls.Add($txtDest)

    $btnBrowseDest = New-Object System.Windows.Forms.Button
    $btnBrowseDest.Text = "Browse"
    # Align browse button smoothly with the shifted destination text box
    $btnBrowseDest.Location = New-Object System.Drawing.Point(345, 40)
    $btnBrowseDest.Size = New-Object System.Drawing.Size(75, 24)
    $pullForm.Controls.Add($btnBrowseDest)

    $grpFilter = New-Object System.Windows.Forms.GroupBox
    $grpFilter.Text = "App Filter"
    $grpFilter.Location = New-Object System.Drawing.Point(20, 80)
    $grpFilter.Size = New-Object System.Drawing.Size(400, 55)
    if ($chkDarkMode.Checked) { $grpFilter.ForeColor = [System.Drawing.Color]::White }
    $pullForm.Controls.Add($grpFilter)

    $radUser = New-Object System.Windows.Forms.RadioButton
    $radUser.Text = "User Apps"
    $radUser.Location = New-Object System.Drawing.Point(10, 20)
    $radUser.AutoSize = $true
    $radUser.Checked = $true
    $grpFilter.Controls.Add($radUser)

    $radSystem = New-Object System.Windows.Forms.RadioButton
    $radSystem.Text = "System Apps"
    $radSystem.Location = New-Object System.Drawing.Point(100, 20)
    $radSystem.AutoSize = $true
    $grpFilter.Controls.Add($radSystem)

    $radAll = New-Object System.Windows.Forms.RadioButton
    $radAll.Text = "All Apps"
    $radAll.Location = New-Object System.Drawing.Point(200, 20)
    $radAll.AutoSize = $true
    $grpFilter.Controls.Add($radAll)

    $btnLoadApps = New-Object System.Windows.Forms.Button
    $btnLoadApps.Text = "Load List"
    $btnLoadApps.Location = New-Object System.Drawing.Point(280, 18)
    $btnLoadApps.Size = New-Object System.Drawing.Size(110, 25)
    $grpFilter.Controls.Add($btnLoadApps)

    $listPull = New-Object System.Windows.Forms.CheckedListBox
    $listPull.Location = New-Object System.Drawing.Point(20, 150)
    $listPull.Size = New-Object System.Drawing.Size(400, 195)
    $listPull.HorizontalScrollbar = $true
    $listPull.CheckOnClick = $true
    if ($chkDarkMode.Checked) {
        $listPull.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
        $listPull.ForeColor = [System.Drawing.Color]::White
    }
    $pullForm.Controls.Add($listPull)

    $lblManual = New-Object System.Windows.Forms.Label
    $lblManual.Text = "Or type exact Package Name manually (e.g., com.facebook.katana):"
    $lblManual.Location = New-Object System.Drawing.Point(20, 360)
    $lblManual.Size = New-Object System.Drawing.Size(400, 20)
    $pullForm.Controls.Add($lblManual)

    $txtManualPkg = New-Object System.Windows.Forms.TextBox
    $txtManualPkg.Location = New-Object System.Drawing.Point(20, 385)
    $txtManualPkg.Size = New-Object System.Drawing.Size(400, 20)
    if ($chkDarkMode.Checked) {
        $txtManualPkg.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
        $txtManualPkg.ForeColor = [System.Drawing.Color]::White
    }
    $pullForm.Controls.Add($txtManualPkg)

    $btnExecutePull = New-Object System.Windows.Forms.Button
    $btnExecutePull.Text = "Pull Selected App(s)"
    $btnExecutePull.Location = New-Object System.Drawing.Point(20, 425)
    $btnExecutePull.Size = New-Object System.Drawing.Size(400, 35)
    $pullForm.Controls.Add($btnExecutePull)

    $lblPullStatus = New-Object System.Windows.Forms.Label
    $lblPullStatus.Text = "Status: Ready."
    $lblPullStatus.Location = New-Object System.Drawing.Point(20, 475)
    $lblPullStatus.Size = New-Object System.Drawing.Size(400, 40)
    $pullForm.Controls.Add($lblPullStatus)

    if ($chkDarkMode.Checked) {
        $flatBtns = @($btnBrowseDest, $btnLoadApps, $btnExecutePull)
        foreach ($b in $flatBtns) {
            $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $b.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 65)
            $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
            $b.ForeColor = [System.Drawing.Color]::White
        }
    }

    $btnBrowseDest.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "Select a folder to save the extracted apps"
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtDest.Text = $fbd.SelectedPath
        }
        $fbd.Dispose()
    })

    $btnLoadApps.Add_Click({
        $listPull.Items.Clear()
        $pullForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $btnLoadApps.Enabled = $false
        $lblPullStatus.Text = "Status: Fetching packages from device..."
        [System.Windows.Forms.Application]::DoEvents()

        $flag = ""
        if ($radUser.Checked) { $flag = "-3" }
        elseif ($radSystem.Checked) { $flag = "-s" }

        $rawOutput = Run-AdbCommand "-s `"$script:targetDevLocked`" shell pm list packages $flag"
        $packages = @($rawOutput -split "`r?`n" | Where-Object { $_ -match "^package:" } | ForEach-Object { $_.Replace("package:","").Trim() } | Sort-Object -Unique)
        
        foreach ($p in $packages) {
            [void]$listPull.Items.Add($p, $false)
        }

        $lblPullStatus.Text = "Status: Found $($packages.Count) apps."
        $btnLoadApps.Enabled = $true
        $pullForm.Cursor = [System.Windows.Forms.Cursors]::Default
    })

    $btnExecutePull.Add_Click({
        if ([string]::IsNullOrWhiteSpace($txtDest.Text)) {
            [void][System.Windows.Forms.MessageBox]::Show("Please select a destination folder first.", "Warning", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        if (-not (Test-Path $txtDest.Text)) {
            [void][System.Windows.Forms.MessageBox]::Show("Destination folder does not exist.", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            return
        }

        $packagesToPull = @()
        foreach ($item in $listPull.CheckedItems) { $packagesToPull += $item }
        if (-not [string]::IsNullOrWhiteSpace($txtManualPkg.Text)) {
            $pkgInput = $txtManualPkg.Text.Trim()
            if ($packagesToPull -notcontains $pkgInput) { $packagesToPull += $pkgInput }
        }

        if ($packagesToPull.Count -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show("Please select or type at least one package to pull.", "Warning", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }

        $pullForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $btnExecutePull.Enabled = $false
        $btnLoadApps.Enabled = $false
        $btnBrowseDest.Enabled = $false
        $txtManualPkg.Enabled = $false
        $listPull.Enabled = $false

        $tempDir = ""

        try {
            foreach ($pkg in $packagesToPull) {
                $lblPullStatus.Text = "Status: Locating paths for $pkg..."
                [System.Windows.Forms.Application]::DoEvents()

                $rawPaths = Run-AdbCommand "-s `"$script:targetDevLocked`" shell pm path `"$pkg`""
                $paths = @($rawPaths -split "`r?`n" | Where-Object { $_ -match "^package:" } | ForEach-Object { $_.Substring(8).Trim() })

                if ($paths.Count -eq 0) {
                    $lblPullStatus.Text = "Status: $pkg not found on device. Skipping."
                    [System.Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Seconds 1
                    continue
                }

                $tempDir = Join-Path $txtDest.Text "temp_$pkg"
                if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
                New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

                # Pull all APK parts
                $lblPullStatus.Text = "Status: Pulling APK(s) for $pkg..."
                [System.Windows.Forms.Application]::DoEvents()
                foreach ($p in $paths) {
                    Run-AdbCommand "-s `"$script:targetDevLocked`" pull `"$p`" `"$tempDir`"" | Out-Null
                }

                # Check if this app has an OBB directory
                $lblPullStatus.Text = "Status: Checking OBB data for $pkg..."
                [System.Windows.Forms.Application]::DoEvents()
                $hasObb = $false
                
                $obbCheck = Run-AdbCommand "-s `"$script:targetDevLocked`" shell ls `"/sdcard/Android/obb/$pkg`""
                if ($obbCheck -notmatch "No such file" -and $obbCheck -notmatch "Permission denied") {
                    $checkDir = Run-AdbCommand "-s `"$script:targetDevLocked`" shell `"if [ -d /sdcard/Android/obb/$pkg ]; then echo 1; else echo 0; fi`""
                    if ($checkDir.Trim() -eq "1") {
                        $hasObb = $true
                        $lblPullStatus.Text = "Status: Pulling OBB data for $pkg (This might take a while)..."
                        [System.Windows.Forms.Application]::DoEvents()
                        
                        $obbDest = Join-Path $tempDir "Android\obb"
                        New-Item -ItemType Directory -Path $obbDest -Force | Out-Null
                        Run-AdbCommand "-s `"$script:targetDevLocked`" pull `"/sdcard/Android/obb/$pkg`" `"$obbDest`"" | Out-Null
                    }
                }

                $lblPullStatus.Text = "Status: Packaging $pkg..."
                [System.Windows.Forms.Application]::DoEvents()

                if ($paths.Count -eq 1 -and -not $hasObb) {
                    # Standard single APK. Move it out and rename it cleanly.
                    $apkFile = Get-ChildItem -Path $tempDir -Filter *.apk | Select-Object -First 1
                    if ($null -ne $apkFile) {
                        Move-Item -Path $apkFile.FullName -Destination (Join-Path $txtDest.Text "$pkg.apk") -Force
                    }
                } else {
                    # Bundle it up into a neat little .apks or .xapk
                    $ext = if ($hasObb) { ".xapk" } else { ".apks" }
                    $archivePath = Join-Path $txtDest.Text "$pkg$ext"
                    if (Test-Path $archivePath) { Remove-Item $archivePath -Force -ErrorAction SilentlyContinue }
                    
                    # Compress-Archive natively rejects third-party extensions like .apks/.xapk directly.
                    # We compress to a temporary .zip first, then safely rename/move it.
                    $tempZipPath = Join-Path ([System.IO.Path]::GetTempPath()) "bundle_archive_$([Guid]::NewGuid().ToString('N')).zip"
                    Compress-Archive -Path "$tempDir\*" -DestinationPath $tempZipPath -Force
                    Move-Item -Path $tempZipPath -Destination $archivePath -Force
                }

                # Clean up the localized mess right away
                if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
            }

            $lblPullStatus.Text = "Status: All selected apps successfully pulled!"
            [System.Media.SystemSounds]::Exclamation.Play()
            [void][System.Windows.Forms.MessageBox]::Show("Pull complete! Check your destination folder.", "Success", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)

        } catch {
            $lblPullStatus.Text = "Status: Error occurred during pull."
            [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        } finally {
            # Ensure the directory gets wiped regardless of crashes or unexpected runtime exceptions.
            if (-not [string]::IsNullOrEmpty($tempDir) -and (Test-Path $tempDir)) { 
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue 
            }

            # Safety first: Terminate ADB server interface lock immediately if logcat streaming is inactive.
            if ($null -eq $global:logcatProcess -or $global:logcatProcess.HasExited) {
                Write-Log "Releasing ADB interface lock after App Pull operation..."
                Start-Process -FilePath "adb.exe" -ArgumentList "kill-server" -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
            }

            $pullForm.Cursor = [System.Windows.Forms.Cursors]::Default
            $btnExecutePull.Enabled = $true
            $btnLoadApps.Enabled = $true
            $btnBrowseDest.Enabled = $true
            $txtManualPkg.Enabled = $true
            $listPull.Enabled = $true
        }
    })

    [void]$pullForm.ShowDialog()
    $pullForm.Dispose()
})

[void]$menuTools.DropDownItems.Add($menuPullApp)
# =======================================================================================


# Help menu configuration.
$menuHelp = New-Object System.Windows.Forms.ToolStripMenuItem("Help")
$menuAbout = New-Object System.Windows.Forms.ToolStripMenuItem("About")

[void]$menuHelp.DropDownItems.Add($menuAbout)
[void]$menuStrip.Items.Add($menuFile)
[void]$menuStrip.Items.Add($menuSettings)
[void]$menuStrip.Items.Add($menuTools)
[void]$menuStrip.Items.Add($menuHelp)

$form.Controls.Add($menuStrip)
$form.MainMenuStrip = $menuStrip

$list = New-Object System.Windows.Forms.CheckedListBox
$list.Size = New-Object System.Drawing.Size(480,200)
$list.Location = New-Object System.Drawing.Point(10,35)
$list.HorizontalScrollbar = $true
$list.AllowDrop = $true
$list.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
Enable-DoubleBuffer $list
$form.Controls.Add($list)

$tlpTopButtons = New-Object System.Windows.Forms.TableLayoutPanel
$tlpTopButtons.ColumnCount = 5
$tlpTopButtons.RowCount = 1
$tlpTopButtons.Location = New-Object System.Drawing.Point(10, 240)
$tlpTopButtons.Size = New-Object System.Drawing.Size(480, 28)
$tlpTopButtons.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
Enable-DoubleBuffer $tlpTopButtons

[void]$tlpTopButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 20)))
[void]$tlpTopButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 20)))
[void]$tlpTopButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 20)))
[void]$tlpTopButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 20)))
[void]$tlpTopButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 20)))
$form.Controls.Add($tlpTopButtons)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "Browse App"
$btnBrowse.Dock = [System.Windows.Forms.DockStyle]::Fill
$btnBrowse.Margin = New-Object System.Windows.Forms.Padding(0, 0, 4, 0)
$tlpTopButtons.Controls.Add($btnBrowse, 0, 0)

$btnSelectAll = New-Object System.Windows.Forms.Button
$btnSelectAll.Text = "Select All"
$btnSelectAll.Dock = [System.Windows.Forms.DockStyle]::Fill
$btnSelectAll.Margin = New-Object System.Windows.Forms.Padding(0, 0, 4, 0)
$tlpTopButtons.Controls.Add($btnSelectAll, 1, 0)

$btnUnselectAll = New-Object System.Windows.Forms.Button
$btnUnselectAll.Text = "Unselect All"
$btnUnselectAll.Dock = [System.Windows.Forms.DockStyle]::Fill
$btnUnselectAll.Margin = New-Object System.Windows.Forms.Padding(0, 0, 4, 0)
$tlpTopButtons.Controls.Add($btnUnselectAll, 2, 0)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Refresh List"
$btnRefresh.Dock = [System.Windows.Forms.DockStyle]::Fill
$btnRefresh.Margin = New-Object System.Windows.Forms.Padding(0, 0, 4, 0)
$tlpTopButtons.Controls.Add($btnRefresh, 3, 0)

$btnRemove = New-Object System.Windows.Forms.Button
$btnRemove.Text = "Remove App"
$btnRemove.Dock = [System.Windows.Forms.DockStyle]::Fill
$btnRemove.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 0)
$tlpTopButtons.Controls.Add($btnRemove, 4, 0)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Size = New-Object System.Drawing.Size(480,20)
$progress.Location = New-Object System.Drawing.Point(10,275)
$progress.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$progress.Minimum = 0
$progress.Maximum = 100
$form.Controls.Add($progress)

$log = New-Object System.Windows.Forms.TextBox
$log.Multiline = $true
$log.ScrollBars = "Vertical"
$log.Size = New-Object System.Drawing.Size(480,100)
$log.Location = New-Object System.Drawing.Point(10,305)
$log.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($log)

$btnClearLog = New-Object System.Windows.Forms.Button
$btnClearLog.Text = "Clear Logs"
$btnClearLog.Size = New-Object System.Drawing.Size(95,25)
$btnClearLog.Location = New-Object System.Drawing.Point(10,410)
$btnClearLog.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$form.Controls.Add($btnClearLog)

$btnExportLog = New-Object System.Windows.Forms.Button
$btnExportLog.Text = "Export Log"
$btnExportLog.Size = New-Object System.Drawing.Size(95,25)
$btnExportLog.Location = New-Object System.Drawing.Point(115,410)
$btnExportLog.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$form.Controls.Add($btnExportLog)

$chkDarkMode = New-Object System.Windows.Forms.CheckBox
$chkDarkMode.Text = "Dark Mode"
$chkDarkMode.AutoSize = $false
$chkDarkMode.Size = New-Object System.Drawing.Size(85, 25)
$chkDarkMode.Location = New-Object System.Drawing.Point(405, 410)
$chkDarkMode.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($chkDarkMode)

$grpSource = New-Object System.Windows.Forms.GroupBox
$grpSource.Text = "Installer Source (Fake Source)"
$grpSource.Size = New-Object System.Drawing.Size(480,55)
$grpSource.Location = New-Object System.Drawing.Point(10,450)
$grpSource.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($grpSource)

$radPlayStore = New-Object System.Windows.Forms.RadioButton
$radPlayStore.Text = "Play Store"
$radPlayStore.Location = New-Object System.Drawing.Point(10,20)
$radPlayStore.AutoSize = $true
$radPlayStore.Checked = $true 
$grpSource.Controls.Add($radPlayStore)

$radAurora = New-Object System.Windows.Forms.RadioButton
$radAurora.Text = "Aurora Store"
$radAurora.Location = New-Object System.Drawing.Point(90,20)
$radAurora.AutoSize = $true
$grpSource.Controls.Add($radAurora)

# Configures spatial coordinates for the F-Droid Basic radio control.
$radFdroid = New-Object System.Windows.Forms.RadioButton
$radFdroid.Text = "F-Droid Basic"
$radFdroid.Location = New-Object System.Drawing.Point(180,20)
$radFdroid.AutoSize = $true
$grpSource.Controls.Add($radFdroid)

$radCustom = New-Object System.Windows.Forms.RadioButton
$radCustom.Text = "Custom:"
$radCustom.Location = New-Object System.Drawing.Point(275,20)
$radCustom.AutoSize = $true
$grpSource.Controls.Add($radCustom)

# Set up a directory in AppData to save the user's custom fake installer name.
$processName = [System.Diagnostics.Process]::GetCurrentProcess().ProcessName
$cfgFolder = Join-Path $env:APPDATA $processName

if (-not (Test-Path $cfgFolder)) {
    New-Item -Path $cfgFolder -ItemType Directory -Force | Out-Null
}

$cfgPath = Join-Path $cfgFolder "custom_source.txt"

$txtCustomSource = New-Object System.Windows.Forms.TextBox
$txtCustomSource.Location = New-Object System.Drawing.Point(340,19)
$txtCustomSource.Size = New-Object System.Drawing.Size(100,20)
$txtCustomSource.Enabled = $false 
$txtCustomSource.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

if (Test-Path $cfgPath) {
    $savedSource = Get-Content -Path $cfgPath | Select-Object -First 1
    if ($null -ne $savedSource) {
        $txtCustomSource.Text = $savedSource.Trim()
    }
}
$grpSource.Controls.Add($txtCustomSource)

$txtCustomSource.Add_TextChanged({
    Set-Content -Path $cfgPath -Value $txtCustomSource.Text.Trim() -Encoding UTF8 -Force -ErrorAction SilentlyContinue
})

$btnClearCustom = New-Object System.Windows.Forms.Button
$btnClearCustom.Text = "X"
$btnClearCustom.Size = New-Object System.Drawing.Size(25,22)
$btnClearCustom.Location = New-Object System.Drawing.Point(445,18)
$btnClearCustom.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$btnClearCustom.Enabled = $false
$grpSource.Controls.Add($btnClearCustom)

$btnClearCustom.Add_Click({
    $txtCustomSource.Clear()
    if (Test-Path $cfgPath) {
        Remove-Item -Path $cfgPath -Force -ErrorAction SilentlyContinue
    }
})

$radCustom.Add_CheckedChanged({
    $txtCustomSource.Enabled = $radCustom.Checked
    $btnClearCustom.Enabled = $radCustom.Checked
})

$chkReinstall = New-Object System.Windows.Forms.CheckBox
$chkReinstall.Text = "Reinstall App(s) (use '-r' flag to keep data)"
$chkReinstall.AutoSize = $true
$chkReinstall.Location = New-Object System.Drawing.Point(10,515)
$chkReinstall.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$chkReinstall.Checked = $true
$form.Controls.Add($chkReinstall)

$tlpBottomButtons = New-Object System.Windows.Forms.TableLayoutPanel
$tlpBottomButtons.ColumnCount = 2
$tlpBottomButtons.RowCount = 1
$tlpBottomButtons.Location = New-Object System.Drawing.Point(10, 550)
$tlpBottomButtons.Size = New-Object System.Drawing.Size(480, 35)
$tlpBottomButtons.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
Enable-DoubleBuffer $tlpBottomButtons

[void]$tlpBottomButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$tlpBottomButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
$form.Controls.Add($tlpBottomButtons)

$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Text = "Install Selected"
$btnInstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$btnInstall.Margin = New-Object System.Windows.Forms.Padding(0, 0, 5, 0)
$tlpBottomButtons.Controls.Add($btnInstall, 0, 0)

$btnUninstall = New-Object System.Windows.Forms.Button
$btnUninstall.Text = "Uninstall App"
$btnUninstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$btnUninstall.Margin = New-Object System.Windows.Forms.Padding(5, 0, 0, 0)
$tlpBottomButtons.Controls.Add($btnUninstall, 1, 0)

$script:apkMap = @{}

function Apply-Theme([bool]$IsDark) {
    
    $form.SuspendLayout()
    Set-TitleBarTheme $form $IsDark
    
    if ($IsDark) {
        $bgMain = [System.Drawing.Color]::FromArgb(32, 32, 32)
        $bgControl = [System.Drawing.Color]::FromArgb(45, 45, 48)
        $fgText = [System.Drawing.Color]::White
        $btnStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnBorder = [System.Drawing.Color]::FromArgb(80, 80, 80)
        
        $menuStrip.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::System
        $menuStrip.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
        $menuStrip.ForeColor = [System.Drawing.Color]::White
        
        $menuFile.DropDown.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
        $menuFile.DropDown.ForeColor = [System.Drawing.Color]::White
        $menuSettings.DropDown.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
        $menuSettings.DropDown.ForeColor = [System.Drawing.Color]::White
        $menuSource.DropDown.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
        $menuSource.DropDown.ForeColor = [System.Drawing.Color]::White
        $menuTools.DropDown.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
        $menuTools.DropDown.ForeColor = [System.Drawing.Color]::White
        $menuHelp.DropDown.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
        $menuHelp.DropDown.ForeColor = [System.Drawing.Color]::White
    } else {
        $bgMain = [System.Drawing.SystemColors]::Control
        $bgControl = [System.Drawing.SystemColors]::Window
        $fgText = [System.Drawing.SystemColors]::ControlText
        $btnStyle = [System.Windows.Forms.FlatStyle]::Standard
        $btnBorder = [System.Drawing.SystemColors]::ControlDark
        
        $menuStrip.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::ManagerRenderMode
        $menuStrip.BackColor = [System.Drawing.SystemColors]::Control
        $menuStrip.ForeColor = [System.Drawing.SystemColors]::ControlText
        
        $menuFile.DropDown.BackColor = [System.Drawing.SystemColors]::Control
        $menuFile.DropDown.ForeColor = [System.Drawing.SystemColors]::ControlText
        $menuSettings.DropDown.BackColor = [System.Drawing.SystemColors]::Control
        $menuSettings.DropDown.ForeColor = [System.Drawing.SystemColors]::ControlText
        $menuSource.DropDown.BackColor = [System.Drawing.SystemColors]::Control
        $menuSource.DropDown.ForeColor = [System.Drawing.SystemColors]::ControlText
        $menuTools.DropDown.BackColor = [System.Drawing.SystemColors]::Control
        $menuTools.DropDown.ForeColor = [System.Drawing.SystemColors]::ControlText
        $menuHelp.DropDown.BackColor = [System.Drawing.SystemColors]::Control
        $menuHelp.DropDown.ForeColor = [System.Drawing.SystemColors]::ControlText
    }

    $form.BackColor = $bgMain
    $form.ForeColor = $fgText
    $list.BackColor = $bgControl
    $list.ForeColor = $fgText
    $log.BackColor = $bgControl
    $log.ForeColor = $fgText
    $txtCustomSource.BackColor = $bgControl
    $txtCustomSource.ForeColor = $txtCustomSource.ForeColor = $fgText

    $grpSource.ForeColor = $fgText
    $radPlayStore.ForeColor = $fgText
    $radAurora.ForeColor = $fgText
    $radFdroid.ForeColor = $fgText
    $radCustom.ForeColor = $fgText
    $chkReinstall.ForeColor = $fgText
    $chkDarkMode.ForeColor = $fgText

    $buttons = @($btnBrowse, $btnSelectAll, $btnUnselectAll, $btnRefresh, $btnRemove, $btnClearLog, $btnExportLog, $btnClearCustom, $btnInstall, $btnUninstall)
    foreach ($btn in $buttons) {
        $btn.FlatStyle = $btnStyle
        $btn.ForeColor = $fgText
        if ($IsDark) {
            $btn.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 65)
            $btn.FlatAppearance.BorderColor = $btnBorder
        } else {
            $btn.BackColor = [System.Drawing.SystemColors]::Control
        }
    }

    $form.ResumeLayout($true)

    if ($null -ne $global:activeLogcatForm -and -not $global:activeLogcatForm.IsDisposed) {
        
        $global:activeLogcatForm.SuspendLayout()
        Set-TitleBarTheme $global:activeLogcatForm $IsDark
        
        if ($IsDark) {
            $global:activeLogcatForm.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
            $global:activeLogcatForm.ForeColor = [System.Drawing.Color]::White
            $script:chkCrash.ForeColor = [System.Drawing.Color]::White
            $script:lblSearch.ForeColor = [System.Drawing.Color]::White
            
            $script:txtSearchLog.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
            $script:txtSearchLog.ForeColor = [System.Drawing.Color]::White
            
            $script:rtbLogs.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
            $script:rtbLogs.ForeColor = [System.Drawing.Color]::LightGray

            $script:cmbLevel.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
            $script:cmbLevel.ForeColor = [System.Drawing.Color]::White

            $logcatBtns = @($script:btnStartLogcat, $script:btnStopLogcat, $script:btnClearLogcat, $script:btnExportLogcat)
            foreach ($btn in $logcatBtns) {
                $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
                $btn.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 65)
                $btn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
                $btn.ForeColor = [System.Drawing.Color]::White
            }
        } else {
            $global:activeLogcatForm.BackColor = [System.Drawing.SystemColors]::Control
            $global:activeLogcatForm.ForeColor = [System.Drawing.SystemColors]::ControlText
            $script:chkCrash.ForeColor = [System.Drawing.SystemColors]::ControlText
            $script:lblSearch.ForeColor = [System.Drawing.SystemColors]::ControlText
            
            $script:txtSearchLog.BackColor = [System.Drawing.SystemColors]::Window
            $script:txtSearchLog.ForeColor = [System.Drawing.SystemColors]::WindowText
            
            $script:rtbLogs.BackColor = [System.Drawing.SystemColors]::Window
            $script:rtbLogs.ForeColor = [System.Drawing.SystemColors]::WindowText

            $script:cmbLevel.BackColor = [System.Drawing.SystemColors]::Window
            $script:cmbLevel.ForeColor = [System.Drawing.SystemColors]::WindowText

            $logcatBtns = @($script:btnStartLogcat, $script:btnStopLogcat, $script:btnClearLogcat, $script:btnExportLogcat)
            foreach ($btn in $logcatBtns) {
                $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Standard
                $btn.BackColor = [System.Drawing.SystemColors]::Control
                $btn.ForeColor = [System.Drawing.SystemColors]::ControlText
            }
        }

        $global:activeLogcatForm.ResumeLayout($true)
    }
}

function Load-ApkList {
    $list.Items.Clear()
    $script:apkMap.Clear()
    
    $files = Get-ChildItem -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '\.(apk|apks|xapk|apkm|zip)$' }

    foreach ($f in $files) {
        $sizeMB = [math]::Round($f.Length / 1MB, 2)
        $displayText = "$($f.FullName) ($sizeMB MB)"
        $script:apkMap[$displayText] = $f.FullName
        [void]$list.Items.Add($displayText, $false)
    }
}

Load-ApkList

function Write-Log($text) {
    if ($text -ne $null -and $text.Trim() -ne "") {
        if ($log.TextLength -gt 100000) {
            $log.Clear()
            $log.AppendText("--- LOG BUFFER CLEARED TO PREVENT MEMORY OVERLOAD ---`r`n")
        }
        $log.AppendText($text.Trim() + "`r`n")
        $log.SelectionStart = $log.Text.Length
        $log.ScrollToCaret()
    }
    [System.Windows.Forms.Application]::DoEvents()
}

$list.Add_DragEnter({
    if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $_.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    }
})

$list.Add_DragDrop({
    $droppedFiles = $_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    
    foreach ($file in $droppedFiles) {
        $fileInfo = Get-Item $file -ErrorAction SilentlyContinue
        
        if ($null -ne $fileInfo -and $fileInfo.Extension -match '\.(apk|apks|xapk|apkm|zip)$') {
            $sizeMB = [math]::Round($fileInfo.Length / 1MB, 2)
            $displayText = "$($fileInfo.FullName) ($sizeMB MB)"
            
            if (-not $script:apkMap.ContainsKey($displayText)) {
                $script:apkMap[$displayText] = $fileInfo.FullName
                [void]$list.Items.Add($displayText, $true)
            }
        }
    }
})

$btnSelectAll.Add_Click({
    for ($i = 0; $i -lt $list.Items.Count; $i++) { $list.SetItemChecked($i, $true) }
})

$btnUnselectAll.Add_Click({
    for ($i = 0; $i -lt $list.Items.Count; $i++) { $list.SetItemChecked($i, $false) }
})

$btnRefresh.Add_Click({ Load-ApkList })

$btnRemove.Add_Click({
    if ($list.CheckedIndices.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show("Please check (tick) the App(s) from the list first to remove.", "Information", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    
    for ($i = $list.CheckedIndices.Count - 1; $i -ge 0; $i--) {
        $idx = $list.CheckedIndices[$i]
        $itemText = $list.Items[$idx]
        $script:apkMap.Remove($itemText)
        $list.Items.RemoveAt($idx)
    }
})

$btnClearLog.Add_Click({
    $log.Clear()
})

$btnExportLog.Add_Click({
    if ([string]::IsNullOrWhiteSpace($log.Text)) {
        [void][System.Windows.Forms.MessageBox]::Show("The log is currently empty. Nothing to export.", "Information", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }

    $saveFileDialog = New-Object System.Windows.Forms.SaveFileDialog
    $saveFileDialog.FileName = "installation.log"
    $saveFileDialog.Filter = "Log Files (*.log)|*.log|Text Files (*.txt)|*.txt|All Files (*.*)|*.*"
    $saveFileDialog.Title = "Save Installation Log"

    try {
        if ($saveFileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Set-Content -Path $saveFileDialog.FileName -Value $log.Text -Encoding UTF8 -ErrorAction SilentlyContinue
            [void][System.Windows.Forms.MessageBox]::Show("Log successfully exported!", "Success", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        }
    }
    finally {
        $saveFileDialog.Dispose()
    }
})

$chkDarkMode.Add_CheckedChanged({
    Apply-Theme $chkDarkMode.Checked
})

$btnBrowse.Add_Click({
    $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $openFileDialog.Filter = "Android Packages (*.apk;*.apks;*.xapk;*.apkm;*.zip)|*.apk;*.apks;*.xapk;*.apkm;*.zip|All Files (*.*)|*.*"
    $openFileDialog.Title = "Select App Packages"
    $openFileDialog.Multiselect = $true

    try {
        if ($openFileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            foreach ($file in $openFileDialog.FileNames) {
                $fileInfo = Get-Item $file
                $sizeMB = [math]::Round($fileInfo.Length / 1MB, 2)
                $displayText = "$($fileInfo.FullName) ($sizeMB MB)"
                
                if (-not $script:apkMap.ContainsKey($displayText)) {
                    $script:apkMap[$displayText] = $fileInfo.FullName
                    [void]$list.Items.Add($displayText, $true)
                }
            }
        }
    }
    finally {
        $openFileDialog.Dispose()
    }
})

$menuAbout.Add_Click({
    $aboutForm = New-Object System.Windows.Forms.Form
    $aboutForm.Text = "About"
    $aboutForm.Size = New-Object System.Drawing.Size(460, 260)
    $aboutForm.StartPosition = "CenterParent"
    $aboutForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $aboutForm.MaximizeBox = $false
    $aboutForm.MinimizeBox = $false
    Enable-DoubleBuffer $aboutForm

    $aboutForm.Add_HandleCreated({
        Set-TitleBarTheme $aboutForm $chkDarkMode.Checked
    })

    if ($chkDarkMode.Checked) {
        $aboutForm.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
        $aboutForm.ForeColor = [System.Drawing.Color]::White
    }

    $aboutLabel = New-Object System.Windows.Forms.LinkLabel
    $aboutText = "Developed by: chihafuyu`nVersion: 48.480.0.0`nCopyright: © 2026 chihafuyu`nLicense: MIT License`n`nThis program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. By using this software, you agree that the developer is not liable for any damages, data loss, or device bricks. Use at your own risk."
    $aboutLabel.Text = $aboutText
    $aboutLabel.Location = New-Object System.Drawing.Point(20, 20)
    $aboutLabel.Size = New-Object System.Drawing.Size(410, 140)
    
    if ($chkDarkMode.Checked) {
        $aboutLabel.LinkColor = [System.Drawing.Color]::LightSkyBlue
    }
    
    $targetLink = "MIT License"
    $gplStart = $aboutText.IndexOf($targetLink)
    
    if ($gplStart -ge 0) {
        $aboutLabel.LinkArea = New-Object System.Windows.Forms.LinkArea($gplStart, $targetLink.Length)
    }
    
    $aboutLabel.Add_LinkClicked({
        Start-Process "https://opensource.org/licenses/mit"
    })
    $aboutForm.Controls.Add($aboutLabel)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "OK"
    $btnOk.Size = New-Object System.Drawing.Size(100, 30)
    $btnOk.Location = New-Object System.Drawing.Point(170, 170)
    
    if ($chkDarkMode.Checked) {
        $btnOk.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnOk.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 65)
        $btnOk.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
        $btnOk.ForeColor = [System.Drawing.Color]::White
    }

    $btnOk.Add_Click({ $aboutForm.Close() })
    $aboutForm.Controls.Add($btnOk)

    [void]$aboutForm.ShowDialog()
    $aboutForm.Dispose()
})

$btnUninstall.Add_Click({
    $inputForm = New-Object System.Windows.Forms.Form
    $inputForm.Text = "Uninstall App"
    # Keep the uninstall window bounds fixed to prevent layout issues when maximizing.
    $inputForm.Size = New-Object System.Drawing.Size(460, 295)
    $inputForm.StartPosition = "CenterParent"
    $inputForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $inputForm.MaximizeBox = $false
    $inputForm.MinimizeBox = $false
    Enable-DoubleBuffer $inputForm

    $inputForm.Add_HandleCreated({
        Set-TitleBarTheme $inputForm $chkDarkMode.Checked
    })

    if ($chkDarkMode.Checked) {
        $inputForm.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
        $inputForm.ForeColor = [System.Drawing.Color]::White
    }

    $lblInput = New-Object System.Windows.Forms.Label
    $lblInput.Text = "Enter the exact Package Name to uninstall:`n(e.g., com.facebook.katana)"
    $lblInput.Location = New-Object System.Drawing.Point(20, 15)
    $lblInput.Size = New-Object System.Drawing.Size(400, 35)
    $lblInput.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $inputForm.Controls.Add($lblInput)

    $txtPkg = New-Object System.Windows.Forms.TextBox
    $txtPkg.Location = New-Object System.Drawing.Point(20, 55)
    $txtPkg.Size = New-Object System.Drawing.Size(400, 20)
    $txtPkg.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    if ($chkDarkMode.Checked) {
        $txtPkg.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
        $txtPkg.ForeColor = [System.Drawing.Color]::White
    }
    $inputForm.Controls.Add($txtPkg)

    $grpUninstMode = New-Object System.Windows.Forms.GroupBox
    $grpUninstMode.Text = "Uninstallation Mode"
    $grpUninstMode.Location = New-Object System.Drawing.Point(20, 90)
    $grpUninstMode.Size = New-Object System.Drawing.Size(400, 120)
    $grpUninstMode.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    if ($chkDarkMode.Checked) { $grpUninstMode.ForeColor = [System.Drawing.Color]::White }
    $inputForm.Controls.Add($grpUninstMode)

    $radStd = New-Object System.Windows.Forms.RadioButton
    $radStd.Text = "Standard (Wipe app and data completely)"
    $radStd.Location = New-Object System.Drawing.Point(10, 20)
    $radStd.AutoSize = $true
    $radStd.Checked = $true
    if ($chkDarkMode.Checked) { $radStd.ForeColor = [System.Drawing.Color]::White }
    $grpUninstMode.Controls.Add($radStd)

    $radKeep = New-Object System.Windows.Forms.RadioButton
    $radKeep.Text = "Keep Data (Uninstall app but save data)"
    $radKeep.Location = New-Object System.Drawing.Point(10, 45)
    $radKeep.AutoSize = $true
    if ($chkDarkMode.Checked) { $radKeep.ForeColor = [System.Drawing.Color]::White }
    $grpUninstMode.Controls.Add($radKeep)

    $radSys = New-Object System.Windows.Forms.RadioButton
    $radSys.Text = "System App (Uninstall for current user / User 0)"
    $radSys.Location = New-Object System.Drawing.Point(10, 70)
    $radSys.AutoSize = $true
    if ($chkDarkMode.Checked) { $radSys.ForeColor = [System.Drawing.Color]::White }
    $grpUninstMode.Controls.Add($radSys)
    
    $radDisable = New-Object System.Windows.Forms.RadioButton
    $radDisable.Text = "Disable / Hide App (Xiaomi/Oppo strict bypass)"
    $radDisable.Location = New-Object System.Drawing.Point(10, 95)
    $radDisable.AutoSize = $true
    if ($chkDarkMode.Checked) { $radDisable.ForeColor = [System.Drawing.Color]::White }
    $grpUninstMode.Controls.Add($radDisable)

    $tlpUninstBtns = New-Object System.Windows.Forms.TableLayoutPanel
    $tlpUninstBtns.ColumnCount = 2
    $tlpUninstBtns.RowCount = 1
    $tlpUninstBtns.Location = New-Object System.Drawing.Point(20, 220)
    $tlpUninstBtns.Size = New-Object System.Drawing.Size(400, 28)
    $tlpUninstBtns.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    Enable-DoubleBuffer $tlpUninstBtns

    [void]$tlpUninstBtns.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    [void]$tlpUninstBtns.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    $inputForm.Controls.Add($tlpUninstBtns)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "Uninstall"
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnOk.Dock = [System.Windows.Forms.DockStyle]::Fill
    $btnOk.Margin = New-Object System.Windows.Forms.Padding(0, 0, 5, 0)
    $tlpUninstBtns.Controls.Add($btnOk, 0, 0)
    
    $btnExportPkgs = New-Object System.Windows.Forms.Button
    $btnExportPkgs.Text = "Export Package List"
    $btnExportPkgs.Dock = [System.Windows.Forms.DockStyle]::Fill
    $btnExportPkgs.Margin = New-Object System.Windows.Forms.Padding(5, 0, 0, 0)
    $tlpUninstBtns.Controls.Add($btnExportPkgs, 1, 0)
    
    if ($chkDarkMode.Checked) {
        $flatBtns = @($btnOk, $btnExportPkgs)
        foreach ($b in $flatBtns) {
            $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $b.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 65)
            $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
            $b.ForeColor = [System.Drawing.Color]::White
        }
    }
    
    $btnExportPkgs.Add_Click({
        $btnExportPkgs.Enabled = $false
        $btnOk.Enabled = $false
        $txtPkg.Enabled = $false
        $grpUninstMode.Enabled = $false

        try {
            $targetDev = Get-TargetDevice $menuWifi.Checked
            if ([string]::IsNullOrEmpty($targetDev)) {
                $modeStr = if ($menuWifi.Checked) { "Wireless" } else { "USB Cable" }
                [void][System.Windows.Forms.MessageBox]::Show("No active $modeStr device detected! Please connect your device to export the package list.", "Device Not Found", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                return
            }

            $sfd = New-Object System.Windows.Forms.SaveFileDialog
            $sfd.FileName = "installed_packages_$([DateTime]::Now.ToString('yyyyMMdd_HHmmss')).txt"
            $sfd.Filter = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*"
            $sfd.Title = "Save Package List"
            
            if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $inputForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
                
                # Parse the raw ADB output into a clean, sorted list.
                function Parse-PackageList($rawOutput) {
                    return @($rawOutput -split "`r?`n" | Where-Object { $_ -match "^package:" } | ForEach-Object { $_.Replace("package:","").Trim() } | Sort-Object -Unique)
                }

                $rawThirdParty = Run-AdbCommand "-s `"$targetDev`" shell pm list packages -3"
                $rawSystem = Run-AdbCommand "-s `"$targetDev`" shell pm list packages -s"
                $rawDisabled = Run-AdbCommand "-s `"$targetDev`" shell pm list packages -d"
                $rawEnabled = Run-AdbCommand "-s `"$targetDev`" shell pm list packages -e"
                $rawUninstalled = Run-AdbCommand "-s `"$targetDev`" shell pm list packages -u"
                $rawPaths = Run-AdbCommand "-s `"$targetDev`" shell pm list packages -f"
                $rawInstallers = Run-AdbCommand "-s `"$targetDev`" shell pm list packages -i"
                
                $outStr = New-Object System.Text.StringBuilder
                [void]$outStr.AppendLine("===============================================")
                [void]$outStr.AppendLine(" DEVICE: $targetDev")
                [void]$outStr.AppendLine(" EXPORT DATE: $([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))")
                [void]$outStr.AppendLine("===============================================")
                [void]$outStr.AppendLine("")
                
                [void]$outStr.AppendLine("=== THIRD-PARTY APPS (-3) ===")
                foreach ($p in Parse-PackageList $rawThirdParty) { [void]$outStr.AppendLine($p) }
                [void]$outStr.AppendLine("")
                
                [void]$outStr.AppendLine("=== SYSTEM APPS (-s) ===")
                foreach ($p in Parse-PackageList $rawSystem) { [void]$outStr.AppendLine($p) }
                [void]$outStr.AppendLine("")
                
                [void]$outStr.AppendLine("=== DISABLED APPS (-d) ===")
                foreach ($p in Parse-PackageList $rawDisabled) { [void]$outStr.AppendLine($p) }
                [void]$outStr.AppendLine("")
                
                [void]$outStr.AppendLine("=== ENABLED APPS (-e) ===")
                foreach ($p in Parse-PackageList $rawEnabled) { [void]$outStr.AppendLine($p) }
                [void]$outStr.AppendLine("")
                
                [void]$outStr.AppendLine("=== ALL APPS INCLUDING UNINSTALLED/HIDDEN (-u) ===")
                foreach ($p in Parse-PackageList $rawUninstalled) { [void]$outStr.AppendLine($p) }
                [void]$outStr.AppendLine("")
                
                [void]$outStr.AppendLine("=== APPS WITH INSTALLER SOURCES (-i) ===")
                foreach ($p in Parse-PackageList $rawInstallers) { [void]$outStr.AppendLine($p) }
                [void]$outStr.AppendLine("")
                
                [void]$outStr.AppendLine("=== APPS WITH FILE PATHS (-f) ===")
                foreach ($p in Parse-PackageList $rawPaths) { [void]$outStr.AppendLine($p) }

                Set-Content -Path $sfd.FileName -Value $outStr.ToString() -Encoding UTF8 -Force -ErrorAction SilentlyContinue
                
                $inputForm.Cursor = [System.Windows.Forms.Cursors]::Default
                [void][System.Windows.Forms.MessageBox]::Show("Detailed package list exported successfully!`n`nYou can open the text file to browse categories, copy the desired package name, and paste it into the uninstall field.", "Export Success", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            }
            $sfd.Dispose()
        } finally {
            $btnExportPkgs.Enabled = $true
            $btnOk.Enabled = $true
            $txtPkg.Enabled = $true
            $grpUninstMode.Enabled = $true
            $inputForm.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })
    
    $inputForm.AcceptButton = $btnOk

    # Expand the dialog width if the main window is maximized or resized.
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Maximized -or $form.Width -gt 700) {
        $inputForm.Width = 650
    }

    try {
        if ($inputForm.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $pkgName = $txtPkg.Text.Trim()
            if (-not [string]::IsNullOrWhiteSpace($pkgName)) {
                
                # Validates the package name format to prevent shell injection vulnerabilities.
                if ($pkgName -notmatch '^[a-zA-Z0-9\._\-]+$') {
                    [void][System.Windows.Forms.MessageBox]::Show("Invalid package name format. Only alphanumeric characters, dots, underscores, and dashes are allowed.", "Validation Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                    return
                }

                $btnInstall.Enabled = $false
                $btnUninstall.Enabled = $false
                $menuStrip.Enabled = $false

                Write-Log "--------------------------------"
                Write-Log "Initializing ADB daemon and scanning for devices..."
                
                $targetDev = Get-TargetDevice $menuWifi.Checked
                
                if ([string]::IsNullOrEmpty($targetDev)) {
                    $modeStr = if ($menuWifi.Checked) { "Wireless" } else { "USB Cable" }
                    Write-Log "Error: No active $modeStr device found."
                    [void][System.Windows.Forms.MessageBox]::Show("No active $modeStr device detected! Please check your connection or switch the Source Connection in the Settings menu.", "Device Not Found", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                    
                    $btnInstall.Enabled = $true
                    $btnUninstall.Enabled = $true
                    $menuStrip.Enabled = $true
                    return
                }

                Write-Log "Target device: $targetDev"
                Write-Log "Uninstalling: $pkgName"
                
                if ($radKeep.Checked) {
                    $uninstallArg = "-s `"$targetDev`" shell pm uninstall -k `"$pkgName`""
                    Write-Log "(Mode: Keep Data [-k])"
                } elseif ($radSys.Checked) {
                    $uninstallArg = "-s `"$targetDev`" shell pm uninstall -k --user 0 `"$pkgName`""
                    Write-Log "(Mode: System App / Debloat [-k --user 0])"
                } elseif ($radDisable.Checked) {
                    $uninstallArg = "-s `"$targetDev`" shell pm disable-user --user 0 `"$pkgName`""
                    Write-Log "(Mode: Disable/Hide App [pm disable-user])"
                } else {
                    $uninstallArg = "-s `"$targetDev`" shell pm uninstall `"$pkgName`""
                    Write-Log "(Mode: Standard Wipe)"
                }
                
                $uninstallResult = Run-AdbCommand $uninstallArg
                Write-Log "Result: $uninstallResult"
                
                [System.Media.SystemSounds]::Exclamation.Play()
                
                if ($null -eq $global:logcatProcess -or $global:logcatProcess.HasExited) {
                    Write-Log "Releasing ADB USB interface lock..."
                    Start-Process -FilePath "adb.exe" -ArgumentList "kill-server" -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
                }
                
                $btnInstall.Enabled = $true
                $btnUninstall.Enabled = $true
                $menuStrip.Enabled = $true
            }
        }
    }
    finally {
        $inputForm.Dispose()
    }
})

$btnInstall.Add_Click({

    if ($list.CheckedItems.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show("No App selected.", "Information", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }

    $installerSource = "com.android.vending"
    if ($radAurora.Checked) {
        $installerSource = "com.aurora.store"
    } elseif ($radFdroid.Checked) {
        $installerSource = "org.fdroid.basic"
    } elseif ($radCustom.Checked) {
        if ([string]::IsNullOrWhiteSpace($txtCustomSource.Text)) {
            [void][System.Windows.Forms.MessageBox]::Show("Please enter a custom installer package name.", "Warning", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        $installerSource = $txtCustomSource.Text.Trim()
    }

    $btnInstall.Enabled = $false
    $btnUninstall.Enabled = $false
    $menuStrip.Enabled = $false
    $btnRefresh.Enabled = $false
    $btnSelectAll.Enabled = $false
    $btnUnselectAll.Enabled = $false
    $btnRemove.Enabled = $false
    $btnBrowse.Enabled = $false 
    $btnClearLog.Enabled = $false 
    $btnExportLog.Enabled = $false 
    $chkReinstall.Enabled = $false
    $chkDarkMode.Enabled = $false
    $grpSource.Enabled = $false
    $progress.Value = 0

    # Lock drag-and-drop during installation to prevent list modification exceptions.
    $list.AllowDrop = $false

    try {
        Write-Log "--------------------------------"
        Write-Log "Initializing ADB daemon and scanning for devices..."
        
        $targetDev = Get-TargetDevice $menuWifi.Checked
        
        if ([string]::IsNullOrEmpty($targetDev)) {
            $modeStr = if ($menuWifi.Checked) { "Wireless" } else { "USB Cable" }
            Write-Log "Error: No active $modeStr device found."
            [void][System.Windows.Forms.MessageBox]::Show("No active $modeStr device detected! Please check your connection or switch the Source Connection in the Settings menu.", "Device Not Found", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            
            $btnInstall.Enabled = $true
            $btnUninstall.Enabled = $true
            $menuStrip.Enabled = $true
            $btnRefresh.Enabled = $true
            $btnSelectAll.Enabled = $true
            $btnUnselectAll.Enabled = $true
            $btnRemove.Enabled = $true
            $btnBrowse.Enabled = $true
            $btnClearLog.Enabled = $true
            $btnExportLog.Enabled = $true
            $chkReinstall.Enabled = $true
            $chkDarkMode.Enabled = $true
            $grpSource.Enabled = $true
            $list.AllowDrop = $true
            return
        }
        
        Write-Log "Target device: $targetDev"

        # Create a snapshot of the checked items to avoid errors if the UI changes during the loop.
        $snapshotItems = @($list.CheckedItems)

        foreach ($itemText in $snapshotItems) {
            $progress.Value = 0
            $apk = $script:apkMap[$itemText]
            $originalName = Split-Path $apk -Leaf
            $ext = [System.IO.Path]::GetExtension($apk).ToLower()
            
            Write-Log "--------------------------------"
            Write-Log "Processing: $originalName"
            
            if ($ext -match '\.(apks|xapk|apkm|zip)$') {
                Write-Log "Detected Bundle/Split Package ($ext). Validating & Extracting..."
                $progress.Value = 10
                
                # Memory-safe ZIP Bomb Validation
                $isValid = $true
                $zip = $null
                try {
                    $zip = [System.IO.Compression.ZipFile]::OpenRead($apk)
                    if ($zip.Entries.Count -gt 10000) {
                        Write-Log "Error: Archive contains too many entries ($($zip.Entries.Count)). Skipping to prevent CPU exhaustion."
                        $isValid = $false
                    } else {
                        $totalUncompressedSize = 0
                        foreach ($entry in $zip.Entries) { $totalUncompressedSize += $entry.Length }
                        if (([math]::Round($totalUncompressedSize / 1MB, 2)) -gt 3500) {
                            Write-Log "Error: Uncompressed size is dangerously large (> 3.5GB). Skipping to prevent resource exhaustion."
                            $isValid = $false
                        }
                    }
                } catch {
                    Write-Log "Error: Failed to read archive structure. The file might be corrupted."
                    $isValid = $false
                } finally {
                    if ($null -ne $zip) { $zip.Dispose() }
                }

                if (-not $isValid) { continue }
                
                $progress.Value = 20
                $tempExtDir = Join-Path ([System.IO.Path]::GetTempPath()) "bundle_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
                New-Item -ItemType Directory -Path $tempExtDir -Force | Out-Null
                
                try {
                    [System.Windows.Forms.Application]::DoEvents()
                    # Native fast extraction
                    [System.IO.Compression.ZipFile]::ExtractToDirectory($apk, $tempExtDir)
                    
                    $baseApkCheck = Get-ChildItem -Path $tempExtDir -Filter 'base.apk' -Recurse
                    if (-not $baseApkCheck) {
                        Write-Log "Error: 'base.apk' is missing from the bundle. Invalid archive structure. Skipping..."
                        continue
                    }

                    $splitApks = Get-ChildItem -Path $tempExtDir -Filter *.apk -Recurse
                    
                    if ($splitApks.Count -eq 0) {
                        Write-Log "Error: No valid APK files found inside the bundle."
                        continue
                    }

                    if ($splitApks.Count -gt 150) {
                        Write-Log "Error: APK fragment count exceeds safe limit ($($splitApks.Count) files). Skipping to prevent command-line overflow."
                        continue
                    }
                    
                    Write-Log "Found $($splitApks.Count) split APKs. Installing via install-multiple..."
                    Write-Log "(Fake Source: $installerSource)"
                    $progress.Value = 50
                    
                    $multipleArgs = "-s `"$targetDev`" install-multiple"
                    if ($chkReinstall.Checked) {
                        Write-Log "(Using -r flag for reinstallation)"
                        $multipleArgs += " -r"
                    }
                    $multipleArgs += " -i $installerSource"
                    
                    foreach ($s in $splitApks) {
                        $multipleArgs += " `"$($s.FullName)`""
                    }
                    
                    $installResult = Run-AdbCommand $multipleArgs
                    Write-Log "Result: $installResult"
                    $progress.Value = 80
                    
                    # Check for OBB data inside .xapk
                    $obbFolder = Join-Path $tempExtDir "Android\obb"
                    if (Test-Path $obbFolder) {
                        $obbItems = Get-ChildItem -Path $obbFolder -Directory
                        foreach ($obbAppFolder in $obbItems) {
                            Write-Log "Found OBB data. Pushing $($obbAppFolder.Name) to device..."
                            [System.Windows.Forms.Application]::DoEvents()
                            $pushObbArg = "-s `"$targetDev`" push `"$($obbAppFolder.FullName)`" `"/sdcard/Android/obb/`""
                            $pushObbResult = Run-AdbCommand $pushObbArg
                            Write-Log "OBB Push Result: $pushObbResult"
                        }
                    }
                    
                    $progress.Value = 100
                    
                } catch {
                    Write-Log "Extraction or installation failed: $_"
                } finally {
                    if (Test-Path $tempExtDir) { Remove-Item $tempExtDir -Recurse -Force -ErrorAction SilentlyContinue }
                }
            } else {
                # Single APK installation
                $safeName = "install_$([Guid]::NewGuid().ToString('N').Substring(0,8)).apk"
                
                Write-Log "Pushing to device..."
                $progress.Value = 30
                
                $pushArg = "-s `"$targetDev`" push `"$apk`" `"/data/local/tmp/$safeName`""
                $pushResult = Run-AdbCommand $pushArg
                Write-Log $pushResult

                Write-Log "Installing..."
                Write-Log "(Fake Source: $installerSource)"
                $progress.Value = 70
                
                if ($chkReinstall.Checked) {
                    Write-Log "(Using -r flag for reinstallation)"
                    $installArg = "-s `"$targetDev`" shell pm install -r -i $installerSource `"/data/local/tmp/$safeName`""
                } else {
                    Write-Log "(Clean install, not using -r flag)"
                    $installArg = "-s `"$targetDev`" shell pm install -i $installerSource `"/data/local/tmp/$safeName`""
                }
                
                $installResult = Run-AdbCommand $installArg
                Write-Log "Result: $installResult"
                
                $progress.Value = 100
                
                for ($w = 0; $w -lt 15; $w++) {
                    [System.Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Milliseconds 50
                }
                
                Run-AdbCommand "-s `"$targetDev`" shell rm `"/data/local/tmp/$safeName`"" | Out-Null
            }
        }

        Write-Log "--------------------------------"
        Write-Log "All selected packages have been processed."
        [System.Media.SystemSounds]::Exclamation.Play()

    }
    catch {
        Write-Log "Exception: $_"
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    finally {
        Write-Log "Cleaning up temporary files..."
        Write-Log "ADB temporary files cleaned."
        
        if ($null -eq $global:logcatProcess -or $global:logcatProcess.HasExited) {
            Write-Log "Releasing ADB USB interface lock..."
            Start-Process -FilePath "adb.exe" -ArgumentList "kill-server" -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
        }
        
        Start-Sleep -Seconds 1
        $progress.Value = 0
        $btnInstall.Enabled = $true
        $btnUninstall.Enabled = $true
        $menuStrip.Enabled = $true
        $btnRefresh.Enabled = $true
        $btnSelectAll.Enabled = $true
        $btnUnselectAll.Enabled = $true
        $btnRemove.Enabled = $true
        $btnBrowse.Enabled = $true
        $btnClearLog.Enabled = $true
        $btnExportLog.Enabled = $true
        $chkReinstall.Enabled = $true
        $chkDarkMode.Enabled = $true
        $grpSource.Enabled = $true
        $list.AllowDrop = $true
    }
})

$form.Add_FormClosing({
    if ($null -ne $global:activeLogcatForm -and -not $global:activeLogcatForm.IsDisposed) {
        $global:activeLogcatForm.Close()
    }
})

[void]$form.ShowDialog()

Start-Process -FilePath "adb.exe" -ArgumentList "kill-server" -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
$form.Dispose()