param([Parameter(Mandatory=$true)][string]$KeyFile)
$ErrorActionPreference = 'Stop'
[Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') | Out-Null
[Reflection.Assembly]::LoadWithPartialName('System.Drawing') | Out-Null
$form = New-Object Windows.Forms.Form
$form.Text = 'LabApp - Clave API de Linear'
$form.ClientSize = New-Object Drawing.Size(520, 165)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$label = New-Object Windows.Forms.Label
$label.Text = 'Pega la clave API de Linear (Ctrl+V). No uses tu clave de Google.'
$label.Location = New-Object Drawing.Point(16, 16)
$label.Size = New-Object Drawing.Size(488, 35)
$inputBox = New-Object Windows.Forms.TextBox
$inputBox.Location = New-Object Drawing.Point(16, 56)
$inputBox.Size = New-Object Drawing.Size(488, 25)
$inputBox.UseSystemPasswordChar = $true
$inputBox.ShortcutsEnabled = $true
$save = New-Object Windows.Forms.Button
$save.Text = 'Guardar clave'
$save.Location = New-Object Drawing.Point(275, 112)
$save.Size = New-Object Drawing.Size(115, 30)
$cancel = New-Object Windows.Forms.Button
$cancel.Text = 'Cancelar'
$cancel.Location = New-Object Drawing.Point(400, 112)
$cancel.Size = New-Object Drawing.Size(104, 30)
$cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
$form.AcceptButton = $save
$form.CancelButton = $cancel
$form.Controls.AddRange(@($label, $inputBox, $save, $cancel))
$save.Add_Click({
    $candidate = $inputBox.Text.Trim()
    if ($candidate -notmatch '^[A-Za-z0-9_-]{20,}$') {
        [Windows.Forms.MessageBox]::Show('Pega la clave API completa, sin espacios ni saltos de linea.', 'Clave incompleta') | Out-Null
        return
    }
    [IO.File]::WriteAllText($KeyFile, $candidate + "`n", (New-Object Text.UTF8Encoding($false)))
    $inputBox.Clear()
    $candidate = $null
    $form.DialogResult = [Windows.Forms.DialogResult]::OK
    $form.Close()
})
try {
    if ($form.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { throw 'Credential entry cancelled; no key was changed.' }
    Write-Host 'Clave guardada de forma privada.'
} finally {
    $inputBox.Clear()
    $form.Dispose()
}
