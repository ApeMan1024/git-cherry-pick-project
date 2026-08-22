' Git Cherry-Pick 需求合并工具 - 无黑窗口启动器
' 双击此文件运行，只显示 GUI 窗口，不弹出命令行窗口。
'
' 说明：WshShell.Run 的窗口样式必须设成正常(1)，否则 OS 会把
' 进程所有窗口（含 GUI）一起抑制，导致"双击后什么都没有"。
' 无黑窗口靠 powershell 自己的 -WindowStyle Hidden 实现。

Option Explicit
On Error Resume Next

Dim WshShell, fso, logFile, scriptPath, psCommand, tmp, rc, exePath

Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

tmp = WshShell.ExpandEnvironmentStrings("%TEMP%")
If tmp = "" Then tmp = "."
Set logFile = fso.OpenTextFile(tmp & "\git-cherry-pick-launch.log", 2, True)

logFile.WriteLine "[" & Now & "] VBS started. ScriptFullName=" & WScript.ScriptFullName

scriptPath = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\") - 1)
psCommand = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " & Chr(34) & scriptPath & "\git-cherry-pick-gui.ps1" & Chr(34)
logFile.WriteLine "[" & Now & "] Launch command: " & psCommand

exePath = WshShell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
If fso.FileExists(exePath) Then
    logFile.WriteLine "[" & Now & "] powershell found: " & exePath
Else
    logFile.WriteLine "[" & Now & "] WARNING: powershell not found at: " & exePath
End If

' 窗口样式 1=正常(让 OS 允许 GUI 显示)；powershell 自身 -WindowStyle Hidden 隐藏控制台
' bWaitOnReturn=True 便于本次诊断捕获退出码；确认无误后可改回 False
rc = WshShell.Run(psCommand, 1, True)
If Err.Number <> 0 Then
    logFile.WriteLine "[" & Now & "] Run ERROR: Number=" & Err.Number & " Description=" & Err.Description
    Err.Clear
Else
    logFile.WriteLine "[" & Now & "] Run returned exit code: " & CStr(rc)
End If
logFile.WriteLine "[" & Now & "] VBS finished."
logFile.Close
