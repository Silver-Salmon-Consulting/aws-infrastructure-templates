<#
SSH ProxyCommand for CloudDev dev servers (Windows). Starts the server if it
is stopped (e.g. by the idle auto-stop), waits until Session Manager can reach
it, then opens the SSH tunnel through Session Manager.

Usage, in ~/.ssh/config:

  Host my-dev-server
      HostName <instance-id>
      ProxyCommand powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Users\<you>\.ssh\clouddev-ssh-proxy.ps1 %h %p <region> <profile>

stdout carries the SSH connection, so every message goes to stderr (shown in
VS Code's Remote-SSH log and by `ssh -v`). Needs the AWS CLI v2, the Session
Manager plugin, and permission to describe and start the instance (the
CloudDev permission set has both).
#>
param(
    [Parameter(Mandatory = $true)][string]$InstanceId,
    [int]$Port = 22,
    [Parameter(Mandatory = $true)][string]$Region,
    [string]$AwsProfile = ""
)

$awsArgs = @("--region", $Region)
if ($AwsProfile) { $awsArgs += @("--profile", $AwsProfile) }

function Log([string]$Message) { [Console]::Error.WriteLine("[clouddev] $Message") }

function Get-State {
    $state = aws ec2 describe-instances --instance-ids $InstanceId @awsArgs `
        --query "Reservations[0].Instances[0].State.Name" --output text 2>&1
    if ($LASTEXITCODE -ne 0) {
        Log "Could not read $InstanceId ($state). If your sign-in expired, run: aws sso login$(if ($AwsProfile) { " --profile $AwsProfile" })"
        exit 1
    }
    return "$state".Trim()
}

function Get-PingStatus {
    $ping = aws ssm describe-instance-information @awsArgs `
        --filters "Key=InstanceIds,Values=$InstanceId" `
        --query "InstanceInformationList[0].PingStatus" --output text 2>$null
    return "$ping".Trim()
}

# Start the server if needed and wait (up to 5 minutes) until it is running.
$deadline = (Get-Date).AddMinutes(5)
while ($true) {
    $state = Get-State
    switch ($state) {
        "running" { break }
        "stopped" {
            Log "$InstanceId is stopped; starting it..."
            aws ec2 start-instances --instance-ids $InstanceId @awsArgs --output text > $null 2>&1
            if ($LASTEXITCODE -ne 0) { Log "Could not start $InstanceId (are you allowed to start it?)."; exit 1 }
        }
        { $_ -in "pending", "stopping" } { Log "$InstanceId is $state; waiting..." }
        default { Log "$InstanceId is '$state' and cannot be connected to."; exit 1 }
    }
    if ($state -eq "running") { break }
    if ((Get-Date) -gt $deadline) { Log "Timed out waiting for $InstanceId to start."; exit 1 }
    Start-Sleep -Seconds 5
}

# A freshly started server needs a moment before the SSM agent is online.
$deadline = (Get-Date).AddMinutes(5)
while ((Get-PingStatus) -ne "Online") {
    if ((Get-Date) -gt $deadline) { Log "$InstanceId is running but Session Manager cannot reach it yet; try again shortly."; exit 1 }
    Log "Waiting for Session Manager to reach $InstanceId..."
    Start-Sleep -Seconds 5
}

# Unpiped, so the plugin talks to ssh directly on stdin/stdout.
aws ssm start-session --target $InstanceId --document-name AWS-StartSSHSession `
    --parameters "portNumber=$Port" @awsArgs
exit $LASTEXITCODE
