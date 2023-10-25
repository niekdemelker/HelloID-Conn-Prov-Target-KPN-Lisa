#region functions
function Get-LisaAccessToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]
        $TenantId,

        [Parameter(Mandatory)]
        [string]
        $ClientId,

        [Parameter(Mandatory)]
        [string]
        $ClientSecret,

        [Parameter(Mandatory)]
        [string]
        $Scope
    )

    try {
        $RestMethod = @{
            Uri         = "https://login.microsoftonline.com/$($TenantId)/oauth2/v2.0/token/"
            ContentType = "application/x-www-form-urlencoded"
            Method      = "Post"
            Body        = @{
                grant_type    = "client_credentials"
                client_id     = $ClientId
                client_secret = $ClientSecret
                scope         = $Scope
            }
        }
        $Response = Invoke-RestMethod @RestMethod

        Write-Output $Response.access_token
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}


function Resolve-ErrorMessage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]
        $ErrorObject
    )

    process {
        $Exception = [PSCustomObject]@{
            FullyQualifiedErrorId = $ErrorObject.FullyQualifiedErrorId
            MyCommand             = $ErrorObject.InvocationInfo.MyCommand
            RequestUri            = $ErrorObject.TargetObject.RequestUri
            ScriptStackTrace      = $ErrorObject.ScriptStackTrace
            ErrorMessage          = $Null
            VerboseErrorMessage   = $Null
        }

        switch ($ErrorObject.Exception.GetType().FullName) {
            "Microsoft.PowerShell.Commands.HttpResponseException" {
                $Exception.ErrorMessage = $ErrorObject.ErrorDetails.Message
                break
            }
            "System.Net.WebException" {
                $Exception.ErrorMessage = [System.IO.StreamReader]::new(
                    $ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
                break
            }
            default {
                $Exception.ErrorMessage = $ErrorObject.Exception.Message
            }
        }

        $Exception.VerboseErrorMessage = @(
            "Error at Line [$($ErrorObject.InvocationInfo.ScriptLineNumber)]: $($ErrorObject.InvocationInfo.Line)."
            "ErrorMessage: $($Exception.ErrorMessage) [$($ErrorObject.ErrorDetails.Message)]"
        ) -Join ' '

        Write-Output $Exception
    }
}
#endregion functions

# Set TLS to accept TLS, TLS 1.1 and TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = @(
    [Net.SecurityProtocolType]::Tls
    [Net.SecurityProtocolType]::Tls11
    [Net.SecurityProtocolType]::Tls12
)

#region Aliasses
$Config = $ActionContext.Configuration
$AuditLogs = $OutputContext.AuditLogs
#endregion Aliasses

# Start Script
try {
    Write-Verbose -Verbose 'Getting accessToken'

    $SplatParams = @{
        TenantId     = $Config.TenantId
        ClientId     = $Config.ClientId
        ClientSecret = $Config.ClientSecret
        Scope        = $Config.Scope
    }
    $AccessToken = Get-LisaAccessToken @SplatParams

    $AuthorizationHeaders = [System.Collections.Generic.Dictionary[[String], [String]]]::new()
    $AuthorizationHeaders.Add("Authorization", "Bearer $($AccessToken)")
    $AuthorizationHeaders.Add("Content-Type", "application/json")
    $AuthorizationHeaders.Add("Mwp-Api-Version", "1.0")

    $SplatParams = @{
            Uri     = "$($Config.BaseUrl)/Users/$($PersonContext.References.Account)/groups/$($personContext.References.Permission.Reference)"
            Headers = $AuthorizationHeaders
            Method  = 'Delete'
    }

    if (-Not ($ActionContext.DryRun -eq $True)) {
        try {
            [void] (Invoke-RestMethod @splatParams)
        }
        catch {
            if ($_ -match "InvalidOperation") {
                $InvalidOperation = $true   # Group not exists
                Write-Verbose "$($_.Errordetails.message)" -Verbose
            }
            else {
                throw "Could not delete member from group, $($_.Exception.Message) $($_.Errordetails.message)".trim(" ")
            }
        }
    }

    if ($InvalidOperation) {
        Write-Verbose "Verifying that the group [$($personContext.References.Permission.Reference)] is removed" -Verbose

        $splatParams = @{
            Uri     = "$($Config.BaseUrl)/Users/$($PersonContext.References.Account)/groups"
            Headers = $AuthorizationHeaders
            Method  = 'Get'
        }
        $result = (Invoke-RestMethod @splatParams)

        if ($personContext.References.Permission.Reference -in $result.value.id) {
            throw "Group [$($personContext.References.Permission.Reference)] is not removed"
        }
    }

    $AuditLogs.Add([PSCustomObject]@{
            Action  = "RevokePermission"
            Message = "Group Permission $($personContext.References.Permission.Reference) removed from account [$($Person.DisplayName) ($($PersonContext.References.Account))]"
            IsError = $False
        })

    $OutputContext.Success = $True
}
catch {
    $Exception = $PSItem | Resolve-ErrorMessage

    Write-Verbose -Verbose $Exception.VerboseErrorMessage

    $AuditLogs.Add([PSCustomObject]@{
            Action  = "RevokePermission" # Optionally specify a different action for this audit log
            Message = "Failed to remove Group permission $($personContext.References.Permission.Reference) from account [$($Person.DisplayName) ($($PersonContext.References.Account))]. Error Message: $($Exception.AuditErrorMessage)."
            IsError = $True
        })
}
