' Silent launcher for Sync-KeyboardClock.ps1 (used as the Task Scheduler action).
' Window style 0 = hidden.
' Third arg True = wait: the task must stay alive while PowerShell runs, otherwise
' Task Scheduler tears down the whole process tree as soon as wscript exits.
Option Explicit

Dim sh, fso, base, script, cmd, rc
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

base   = fso.GetParentFolderName(WScript.ScriptFullName)
script = base & "\Sync-KeyboardClock.ps1"

If Not fso.FileExists(script) Then WScript.Quit 9

cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """"
rc  = sh.Run(cmd, 0, True)
WScript.Quit rc
