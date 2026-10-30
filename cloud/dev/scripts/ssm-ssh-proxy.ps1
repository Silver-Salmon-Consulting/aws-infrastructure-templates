# SSH ProxyCommand for a CloudDev dev server: starts the instance if it is
# stopped, waits for it, and opens an AWS-StartSSHSession tunnel. If the tunnel
# fails to open, it restarts the SSM agent with the environment stack's
# RestartSsmAgentDocument and tries once more.
#
# Usage, in ~/.ssh/config:
#   ProxyCommand powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\path\to\ssm-ssh-proxy.ps1 -InstanceId %h -Port %p -Region <region> -AwsProfile <profile> -RestartDocument <RestartSsmAgentDocumentName output>
#
# stdout IS the SSH stream: everything except start-session must go to
# Out-Null or stderr, or ssh reads it as protocol data.
param(
    [Parameter(Mandatory)] [string] $InstanceId,
    [int] $Port = 22,
    [Parameter(Mandatory)] [string] $Region,
    [Parameter(Mandatory)] [string] $AwsProfile,
    # Leave empty to skip the agent restart and just fail.
    [string] $RestartDocument = ""
)

$aws = @("--region", $Region, "--profile", $AwsProfile)

aws ec2 start-instances --instance-ids $InstanceId @aws | Out-Null
aws ec2 wait instance-status-ok --instance-ids $InstanceId @aws

aws ssm start-session --target $InstanceId --document-name AWS-StartSSHSession --parameters "portNumber=$Port" @aws
if ($LASTEXITCODE -eq 0 -or -not $RestartDocument) { exit $LASTEXITCODE }

# Run Command is delivered by the agent too, so this only helps when the agent
# still takes commands. If it is fully offline, send-command fails and we stop:
# reboot the server (RestartDevServerRunbook) instead.
[Console]::Error.WriteLine("ssm-ssh-proxy: session failed, restarting the SSM agent on $InstanceId")
$commandId = aws ssm send-command --instance-ids $InstanceId --document-name $RestartDocument --query Command.CommandId --output text @aws
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
aws ssm wait command-executed --command-id $commandId --instance-id $InstanceId @aws
# The document schedules the restart 5 seconds after it reports success; give
# the agent time to restart and reconnect.
Start-Sleep -Seconds 20

aws ssm start-session --target $InstanceId --document-name AWS-StartSSHSession --parameters "portNumber=$Port" @aws
exit $LASTEXITCODE
