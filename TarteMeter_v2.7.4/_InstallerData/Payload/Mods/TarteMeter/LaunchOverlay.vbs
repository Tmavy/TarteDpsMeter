Option Explicit
On Error Resume Next

Dim shell, fso, folder, bootstrapPath, errorPath, diagnosticPath
Dim powershellPath, commandLine, result, stream, message

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

folder = fso.GetParentFolderName(WScript.ScriptFullName)
bootstrapPath = fso.BuildPath(folder, "OverlayBootstrap.ps1")
errorPath = fso.BuildPath(folder, "window_launcher_error.txt")
diagnosticPath = fso.BuildPath(folder, "startup_diagnostic.txt")
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")

Set stream = fso.OpenTextFile(diagnosticPath, 8, True, 0)
stream.WriteLine "[" & Now & "] Windows Script Host fallback started"
stream.Close

If Not fso.FileExists(bootstrapPath) Then
    message = "OverlayBootstrap.ps1 is missing: " & bootstrapPath
    Set stream = fso.CreateTextFile(errorPath, True, False)
    stream.WriteLine message
    stream.Close
    WScript.Quit 2
End If

If Not fso.FileExists(powershellPath) Then
    powershellPath = "powershell.exe"
End If

shell.CurrentDirectory = folder
commandLine = Chr(34) & powershellPath & Chr(34) & _
    " -NoLogo -NoProfile -ExecutionPolicy Bypass -STA" & _
    " -WindowStyle Hidden -File " & Chr(34) & bootstrapPath & Chr(34)

Err.Clear
result = shell.Run(commandLine, 0, False)

If Err.Number <> 0 Or result <> 0 Then
    message = "Windows could not start TarteMeter." & vbCrLf & _
              "Error " & Err.Number & ": " & Err.Description & vbCrLf & _
              "Command: " & commandLine
    Set stream = fso.CreateTextFile(errorPath, True, False)
    stream.WriteLine message
    stream.Close
    WScript.Quit 3
End If

WScript.Quit 0
