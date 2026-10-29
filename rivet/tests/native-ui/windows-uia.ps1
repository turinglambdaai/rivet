param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class RivetNativeUi {
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool PostMessage(
        IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SendMessage(
        IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
}
'@

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

function Wait-Until {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][scriptblock]$Probe,
        [double]$TimeoutSeconds = 30
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $value = & $Probe
        if ($null -ne $value -and $value -ne $false) { return $value }
        Start-Sleep -Milliseconds 50
    }
    throw "Timed out waiting for $Description"
}

function Find-ByAutomationId {
    param(
        [Parameter(Mandatory = $true)]$Root,
        [Parameter(Mandatory = $true)][string]$AutomationId
    )
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
        $AutomationId)
    return $Root.FindFirst(
        [System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Get-StatusText {
    param([Parameter(Mandatory = $true)]$StatusElement)
    $message = Find-ByAutomationId $StatusElement 'Message'
    if ($null -ne $message) { return $message.Current.Name }
    return $StatusElement.Current.Name
}

function Convert-Element {
    param($Element, [int]$Depth = 0, [int]$MaximumDepth = 8)
    $current = $Element.Current
    $result = [ordered]@{
        name = $current.Name
        automationId = $current.AutomationId
        controlType = $current.ControlType.ProgrammaticName
        enabled = $current.IsEnabled
    }
    if ($Depth -lt $MaximumDepth) {
        $children = $Element.FindAll(
            [System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.Condition]::TrueCondition)
        $result.children = @(
            foreach ($child in $children) {
                Convert-Element $child ($Depth + 1) $MaximumDepth
            }
        )
    }
    return [pscustomobject]$result
}

function Save-Screenshot {
    param([string]$Path)
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bounds.Size)
        } finally {
            $graphics.Dispose()
        }
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $bitmap.Dispose()
    }
}

$priorProbe = [Environment]::GetEnvironmentVariable('RIVET_TEST_ICON_PROBE', 'Process')
[Environment]::SetEnvironmentVariable('RIVET_TEST_ICON_PROBE', '1', 'Process')
try {
    $process = Start-Process -FilePath (Resolve-Path -LiteralPath $Executable) -PassThru
} finally {
    [Environment]::SetEnvironmentVariable('RIVET_TEST_ICON_PROBE', $priorProbe, 'Process')
}
$window = $null
$probeWindow = $null
try {
    $processCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
        $process.Id)
    $window = Wait-Until 'the Taskboard WinUI window' {
        $matches = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
            [System.Windows.Automation.TreeScope]::Children, $processCondition)
        foreach ($candidate in $matches) {
            if ($candidate.Current.Name -like 'Rivet Taskboard*') { return $candidate }
        }
        return $null
    }
    $probeWindow = Wait-Until 'the second titled WinUI icon-probe window' {
        $matches = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
            [System.Windows.Automation.TreeScope]::Children, $processCondition)
        foreach ($candidate in $matches) {
            if ($candidate.Current.Name -eq 'Rivet Icon Probe') { return $candidate }
        }
        return $null
    }

    # Both top-level windows must expose the exact solid-color icon fixture
    # embedded into the packaged EXE as Win32 group icon resource ID 1.
    foreach ($entry in @(
        @{ label = 'Taskboard'; element = $window },
        @{ label = 'secondary icon probe'; element = $probeWindow }
    )) {
        $hwnd = [IntPtr]$entry.element.Current.NativeWindowHandle
        if ($hwnd -eq [IntPtr]::Zero) { throw "$($entry.label) has no native HWND" }
        $iconHandle = [RivetNativeUi]::SendMessage($hwnd, 0x007F, [IntPtr]0, [IntPtr]::Zero)
        if ($iconHandle -eq [IntPtr]::Zero) {
            $iconHandle = [RivetNativeUi]::SendMessage($hwnd, 0x007F, [IntPtr]1, [IntPtr]::Zero)
        }
        if ($iconHandle -eq [IntPtr]::Zero) {
            throw "$($entry.label) did not publish the packaged executable icon"
        }
        # The fixture is a 16x16 fully opaque bitmap with RGB(25,115,186).
        $bitmap = [System.Drawing.Icon]::FromHandle($iconHandle).ToBitmap()
        try {
            $pixel = $bitmap.GetPixel(8, 8)
            # Win32 may premultiply the fully opaque ICO DIB through a
            # 254/255 alpha round-trip; tolerate one channel level but reject
            # any generic/default title-bar icon or unrelated product art.
            if ([Math]::Abs([int]$pixel.R - 25) -gt 1 -or
                [Math]::Abs([int]$pixel.G - 115) -gt 1 -or
                [Math]::Abs([int]$pixel.B - 186) -gt 1 -or
                $pixel.A -lt 254) {
                throw "$($entry.label) published a different title-bar icon: $pixel"
            }
        } finally {
            $bitmap.Dispose()
        }
    }

    $required = [ordered]@{
        'application-status' = 'ControlType.StatusBar'
        'task-list' = 'ControlType.List'
        'new-task' = 'ControlType.Button'
        'generate-demo' = 'ControlType.Button'
    }
    foreach ($entry in $required.GetEnumerator()) {
        $element = Wait-Until "AutomationId $($entry.Key)" {
            Find-ByAutomationId $window $entry.Key
        }
        if ($element.Current.ControlType.ProgrammaticName -ne $entry.Value) {
            throw "AutomationId $($entry.Key) exposed $($element.Current.ControlType.ProgrammaticName), expected $($entry.Value)"
        }
    }
    Wait-Until 'the ready native controls' {
        (Find-ByAutomationId $window 'new-task').Current.IsEnabled -and
        (Find-ByAutomationId $window 'generate-demo').Current.IsEnabled
    } | Out-Null

    Convert-Element $window | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath (Join-Path $OutputDirectory 'accessibility-before.json') -Encoding utf8

    $newTask = Find-ByAutomationId $window 'new-task'
    $invoke = $newTask.GetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern)
    $invoke.Invoke()
    Wait-Until 'the RPC-created task row' {
        if ($process.HasExited) {
            throw "the Taskboard process exited with code $($process.ExitCode) before the RPC-created row appeared"
        }
        Find-ByAutomationId $window 'task-row-4'
    } | Out-Null

    # Exercise real WinUI edit/draft/save behavior through native UI Automation.
    # Backend validation rejects blank titles; the failure must keep the draft
    # editable rather than discarding it or silently showing a saved state.
    $edit = Wait-Until 'an enabled Edit title action' {
        $candidate = Find-ByAutomationId $window 'edit-task'
        if ($null -ne $candidate -and $candidate.Current.IsEnabled) { return $candidate }
        return $null
    }
    $edit.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $editor = Wait-Until 'editable task title' {
        $candidate = Find-ByAutomationId $window 'edit-task-title'
        if ($null -ne $candidate -and $candidate.Current.IsEnabled) { return $candidate }
        return $null
    }
    $editor.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('Discard this draft')
    $discard = Find-ByAutomationId $window 'cancel-task-edit'
    $discard.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-Until 'cancel restores the original title' {
        $titleElement = Find-ByAutomationId $window 'task-title'
        $editElement = Find-ByAutomationId $window 'edit-task'
        $null -ne $titleElement -and $titleElement.Current.Name -eq 'New task' -and
            $null -ne $editElement -and $editElement.Current.IsEnabled
    } | Out-Null

    $edit.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $editor = Wait-Until 'editor reopened after cancel' {
        $candidate = Find-ByAutomationId $window 'edit-task-title'
        if ($null -ne $candidate -and $candidate.Current.IsEnabled) { return $candidate }
        return $null
    }
    $editor.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('   ')
    $save = Find-ByAutomationId $window 'save-task'
    $save.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $status = Find-ByAutomationId $window 'application-status'
    Wait-Until 'failed save leaves the draft editable' {
        $candidate = Find-ByAutomationId $window 'edit-task-title'
        if ($null -eq $candidate -or -not $candidate.Current.IsEnabled) { return $false }
        $retained = $candidate.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
        $message = Get-StatusText $status
        ($retained -eq '   ') -and ($message -like '*Save failed; draft retained*')
    } | Out-Null

    $editor = Find-ByAutomationId $window 'edit-task-title'
    $editor.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('Edited via native UIA')
    $save = Find-ByAutomationId $window 'save-task'
    $save.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-Until 'saved title visible in the native detail pane' {
        $candidate = Find-ByAutomationId $window 'task-title'
        $null -ne $candidate -and $candidate.Current.Name -eq 'Edited via native UIA'
    } | Out-Null
    $edit = $null
    $editor = $null
    $save = $null
    $discard = $null

    $generate = Find-ByAutomationId $window 'generate-demo'
    $generate.GetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $status = Find-ByAutomationId $window 'application-status'
    $observedStatus = [System.Collections.Generic.List[string]]::new()
    $sawEvent = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(6)
    while ([DateTime]::UtcNow -lt $deadline) {
        $message = Get-StatusText $status
        if ($message -and ($observedStatus.Count -eq 0 -or $observedStatus[$observedStatus.Count - 1] -ne $message)) {
            $observedStatus.Add($message)
        }
        if ($message -like 'Preparing task *') { $sawEvent = $true; break }
        Start-Sleep -Milliseconds 10
    }
    if (-not $sawEvent) {
        throw "operation-progress Event never reached UI Automation; observed=$($observedStatus -join ' | ')"
    }
    Wait-Until 'the RPC-driven 1,000-row state' {
        if ($process.HasExited) {
            throw "the Taskboard process exited with code $($process.ExitCode) before the 1,000-row state reached the UI"
        }
        (Get-StatusText $status) -eq 'Generated 1000 tasks'
    } -TimeoutSeconds 20 | Out-Null

    Convert-Element $window | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath (Join-Path $OutputDirectory 'accessibility-after.json') -Encoding utf8
    [ordered]@{
        application = 'Rivet Taskboard'
        actions = @('invoke:new-task', 'invoke:generate-demo', 'tray-command:exit')
        observedStatus = @($observedStatus)
        assertions = @(
            'native WinUI window exposed'
            'two titled WinUI windows exposed the expected packaged icon'
            'stable control types and AutomationIds exposed'
            'RPC-created task appeared'
            'operation-progress Event appeared'
            '1,000-row State reached the UI'
            'tray menu command reached its application callback'
        )
    } | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $OutputDirectory 'interaction-trace.json') -Encoding utf8
    Save-Screenshot (Join-Path $OutputDirectory 'screen.png')

    # Target the exact HWND exposed by the UIA root. Process.MainWindowHandle
    # is heuristic and may select a diagnostic console instead of the WinUI
    # window; WindowPattern is also absent when WinUI exposes the root as a
    # pane. Command 2 is the reference host's tray-menu Exit action, so this
    # also proves that TrayController's HWND subclass routes WM_COMMAND back to
    # its application callback before the normal close lifecycle runs.
    $shutdownTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $nativeWindow = [IntPtr]$window.Current.NativeWindowHandle
    if ($nativeWindow -eq [IntPtr]::Zero -or
        -not [RivetNativeUi]::PostMessage(
            $nativeWindow, 0x0111, [IntPtr]2, [IntPtr]::Zero)) {
        throw 'Taskboard did not expose a tray-command-capable native WinUI HWND'
    }
    # UI Automation proxies keep out-of-process provider objects alive. Drop
    # every retained proxy once WM_CLOSE is sent so XAML can destroy the large
    # virtualized tree before the process-exit assertion.
    $element = $null
    $newTask = $null
    $invoke = $null
    $generate = $null
    $status = $null
    $window = $null
    $probeWindow = $null
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    [GC]::Collect()
    if (-not $process.WaitForExit(10000)) {
        throw 'Taskboard did not exit within ten seconds of its tray Exit command'
    }
    $shutdownTimer.Stop()
    [ordered]@{ shutdownMilliseconds = $shutdownTimer.ElapsedMilliseconds } |
        ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $OutputDirectory 'shutdown-trace.json') -Encoding utf8
    if ($process.ExitCode -ne 0) {
        throw "Taskboard exited with status $($process.ExitCode)"
    }
} catch {
    try { Save-Screenshot (Join-Path $OutputDirectory 'failure-screen.png') } catch {}
    if ($null -ne $window) {
        try {
            Convert-Element $window | ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath (Join-Path $OutputDirectory 'failure-accessibility.json') -Encoding utf8
        } catch {}
    }
    throw
} finally {
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit()
    }
    $process.Dispose()
}
