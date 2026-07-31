Option Explicit
On Error Resume Next

Dim shell, fso, baseFolder, setupScript, powershellPath
Dim commandLine, exitCode, logPath, stream, errorText

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

baseFolder = fso.GetParentFolderName(WScript.ScriptFullName)
setupScript = fso.BuildPath(baseFolder, "_InstallerData\Setup.ps1")
logPath = fso.BuildPath(baseFolder, "_InstallerData\InstallerError.log")
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")

If fso.FileExists(logPath) Then
    fso.DeleteFile logPath, True
End If

If Not fso.FileExists(setupScript) Then
    MsgBox "The setup files are incomplete." & vbCrLf & vbCrLf & _
           "Extract the entire archive to a normal folder, then run TarteMeter Setup.vbs again.", _
           vbCritical, "TarteMeter Setup"
    WScript.Quit 2
End If

If Not fso.FileExists(powershellPath) Then
    powershellPath = "powershell.exe"
End If

shell.CurrentDirectory = baseFolder

commandLine = Chr(34) & powershellPath & Chr(34) & _
              " -NoLogo -NoProfile -ExecutionPolicy Bypass -STA" & _
              " -WindowStyle Hidden -File " & Chr(34) & setupScript & Chr(34)

Err.Clear
exitCode = shell.Run(commandLine, 0, True)

If Err.Number <> 0 Then
    errorText = "Windows Script Host could not start the setup." & vbCrLf & _
                "Error " & Err.Number & ": " & Err.Description & vbCrLf & _
                "Command: " & commandLine
    Set stream = fso.CreateTextFile(logPath, True, True)
    stream.WriteLine errorText
    stream.Close
    MsgBox errorText & vbCrLf & vbCrLf & "Diagnostic file:" & vbCrLf & logPath, _
           vbCritical, "TarteMeter Setup"
    WScript.Quit 3
End If

If exitCode <> 0 Then
    MsgBox "TarteMeter Setup could not complete." & vbCrLf & vbCrLf & _
           "Open this diagnostic file:" & vbCrLf & logPath, _
           vbCritical, "TarteMeter Setup"
End If

WScript.Quit exitCode
