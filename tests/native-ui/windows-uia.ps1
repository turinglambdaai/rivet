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

$process = Start-Process -FilePath (Resolve-Path -LiteralPath $Executable) -PassThru
$window = $null
try {
    $processCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
        $process.Id)
    $window = Wait-Until 'the Taskboard WinUI window' {
        [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Children, $processCondition)
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
        Find-ByAutomationId $window 'task-row-4'
    } | Out-Null

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
        Find-ByAutomationId $window 'task-row-1004'
    } -TimeoutSeconds 20 | Out-Null

    Convert-Element $window | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath (Join-Path $OutputDirectory 'accessibility-after.json') -Encoding utf8
    [ordered]@{
        application = 'Rivet Taskboard'
        actions = @('invoke:new-task', 'invoke:generate-demo')
        observedStatus = @($observedStatus)
        assertions = @(
            'native WinUI window exposed'
            'stable control types and AutomationIds exposed'
            'RPC-created task appeared'
            'operation-progress Event appeared'
            '1,000-row State reached the UI'
        )
    } | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $OutputDirectory 'interaction-trace.json') -Encoding utf8
    Save-Screenshot (Join-Path $OutputDirectory 'screen.png')

    $window.GetCurrentPattern(
        [System.Windows.Automation.WindowPattern]::Pattern).Close()
    if (-not $process.WaitForExit(10000)) {
        throw 'Taskboard did not exit within ten seconds of native window close'
    }
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
