@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Interactive console UX (coloured menu/progress) intentionally uses Write-Host.
        'PSAvoidUsingWriteHost',
        # Plain text is converted to SecureString only at the point a crypt hash is built.
        'PSAvoidUsingConvertToSecureStringWithPlainText'
    )
    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
    }
}
