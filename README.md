# aws-infrastructure-templates

Reusable, public AWS CloudFormation templates that are deployed manually. Each
template is standalone YAML with no build step. They are validated in CI with
[cfn-lint](https://github.com/aws-cloudformation/cfn-lint).

## CloudDev remote development servers

The first set of templates provisions remote development servers on EC2, split
into a shared **environment** stack and one or more **server** stacks. Server
configuration (Node.js, PowerShell, Playwright dependencies, .NET SDKs, k6,
the AWS CLI and small CLI utilities) is delivered through managed, versioned AWS
Systems Manager (SSM) documents applied by tag, rather than baked into instance
boot scripts — so it is maintained centrally and re-appliable on demand.

```
cloud/dev/
  environment/
    cloud-dev-environment.yaml          # shared: IAM role, log group, SSM documents, VPC
    cloud-dev-permission-set.yaml       # Identity Center permission set for developers
  server/
    cloud-dev-server-amazon-linux.yaml      # x86_64 (AMD) dev server
    cloud-dev-server-amazon-linux-arm.yaml  # arm64 (Graviton) dev server
    cloud-dev-ollama-server.yaml            # private GPU Ollama LLM server
```

### Architecture

- **Environment stack** (`cloud-dev-environment.yaml`) — the shared foundation,
  deployed once. It creates:
  - an IAM role + instance profile with `AmazonSSMManagedInstanceCore` (so SSM
    Session Manager, Run Command, and Patch Manager can manage the instances),
    plus scoped inline policies that let the instances signal CloudFormation and
    write bootstrap logs;
  - a CloudWatch Logs group for instance bootstrap output;
  - nine SSM Command Documents — one installs Node.js/npm via nvm, one
    installs the system libraries/fonts and Chromium build Playwright needs
    (takes a `PlaywrightVersion`), one installs jq/zip/unzip, and the rest are
    per-version tool documents (PowerShell 7.4 and 7.6, .NET 8 and 10, k6 0.x
    and 1.x, AWS CLI 2.x, GitHub CLI 2.x — see [Versioned tool documents](#versioned-tool-documents));
  - **tag-targeted** SSM State Manager associations that apply those
    documents to any instance carrying the matching tag;
  - an optional VPC (`public` or `public-private`, 1–3 AZs).
- **Server stacks** (`cloud-dev-server-*.yaml`) — each launches one EC2 instance.
  A server imports the IAM instance profile and log group from the environment
  stack by name, and **tags itself** to opt into the shared SSM associations. It
  does not define its own SSM documents or associations.

The two server templates are identical except for CPU architecture:

| Template | Arch | AMI | Instance types (default) |
|---|---|---|---|
| `cloud-dev-server-amazon-linux.yaml` | x86_64 (AMD) | AL2023 x86_64 | `t3a`/`m5a`/`c5a` (`t3a.medium`) |
| `cloud-dev-server-amazon-linux-arm.yaml` | arm64 (Graviton) | AL2023 arm64 | `t4g`/`m6g`/`c6g` (`t4g.medium`) |

### How server configuration is delivered (SSM, not UserData)

Node.js and PowerShell are **not** installed by instance UserData. Instead:

1. The environment stack owns the install logic as SSM Command Documents.
2. The environment stack owns tag-targeted associations:
   - `NodeConfigAssociation` targets `tag:CloudDevNodeConfig = enabled`
   - `PowerShellV74ConfigAssociation` / `PowerShellV76ConfigAssociation` target
     `tag:CloudDevPowerShellConfig = v7.4` / `v7.6` (pass `PowerShell74Version` /
     `PowerShell76Version`)
   - `PlaywrightConfigAssociation` targets `tag:CloudDevPlaywrightConfig = enabled`
     (passes `PlaywrightVersion`)
   - `DotNet8ConfigAssociation` / `DotNet10ConfigAssociation` target
     `tag:CloudDevDotNetConfig = v8` / `v10` (pass `DotNet8Version` /
     `DotNet10Version`)
   - `BaseToolsConfigAssociation` targets `tag:CloudDevBaseToolsConfig = enabled`
   - `K6V0ConfigAssociation` / `K6V1ConfigAssociation` target
     `tag:CloudDevK6Config = v0` / `v1`
   - `AwsCliV2ConfigAssociation` targets `tag:CloudDevAwsCliConfig = v2`
   - `GhCliV2ConfigAssociation` targets `tag:CloudDevGhCliConfig = v2`
3. Each server tags its instance to opt in:
   - `CloudDevNodeConfig = enabled` (always — every dev server gets Node)
   - `CloudDevPowerShellConfig = <PowerShellVersion>` (`none` / `v7.4` / `v7.6`,
     default `none`)
   - `CloudDevPlaywrightConfig = enabled` when `EnablePlaywright=true`
     (default `false`), else `disabled`
   - `CloudDevDotNetConfig = <DotNetVersion>` (`none` / `v8` / `v10`, default
     `none`)
   - `CloudDevBaseToolsConfig = enabled` (always — jq, zip and unzip)
   - `CloudDevK6Config = <K6MajorVersion>` (`none` / `v0` / `v1`, default `none`)
   - `CloudDevAwsCliConfig = <AwsCliMajorVersion>` (`none` / `v2`, default `none`)
   - `CloudDevGhCliConfig = <GhCliMajorVersion>` (`none` / `v2`, default `none`)

The .NET SDK installs into `/opt/dotnet` (via Microsoft's `dotnet-install.sh`,
x64 or arm64 automatically), with `/usr/bin/dotnet` symlinked and `DOTNET_ROOT`
set in `/etc/profile.d/dotnet.sh`. `DotNet8Version` / `DotNet10Version` are
exact SDK versions (`8.0.426`). Pin a project to a
specific SDK with `global.json`; `dotnet --list-sdks` shows what is installed.

The Playwright document installs the OS dependencies (the dnf equivalent of
`npx playwright install-deps`, which supports apt only) plus Xvfb, then runs
`npx playwright@<PlaywrightVersion> install chromium` into the shared
`/opt/playwright-browsers` (`PLAYWRIGHT_BROWSERS_PATH` is set in
`/etc/profile.d/playwright.sh`). A project pinned to that Playwright version
needs no browser download. Chromium is the supported engine on Amazon Linux;
Playwright's WebKit and Firefox builds target Ubuntu.

### Versioned tool documents

Tools whose version matters to a project (PowerShell, .NET, k6, the AWS CLI, the GitHub CLI)
follow one pattern: **one SSM document per tool per major version** (PowerShell:
per release line), for example `AmazonLinuxK6V0Document` and
`AmazonLinuxK6V1Document`. Nothing floats to `latest`: every document takes an
**exact version** with no default of its own, and the association passes it in
from a pinned environment-stack parameter (`PowerShell74Version`,
`PowerShell76Version`, `DotNet8Version`, `DotNet10Version`, `K6V0Version`,
`K6V1Version`, `AwsCliV2Version`, `GhCliV2Version`).

- The document fixes the major version. Its version parameter (`PowerShellVersion`,
  `DotNetVersion`, `K6Version`, `AwsCliVersion`) takes an exact version
  (`0.59.0`), checked against the major by `allowedPattern`.
- Each major has its own association. All majors of a tool share one tag key
  and differ by tag **value**, so a server selects exactly one major
  (`CloudDevK6Config = v0`), and `none` selects nothing. Server stacks expose
  this as `K6MajorVersion` / `AwsCliMajorVersion` / `GhCliMajorVersion`.
- To add a major, copy the document and association, change the major number,
  and add the value to the server stacks' `AllowedValues`.
- To roll the fleet to a new release, change the pinned parameter on the
  environment stack and re-apply the association. Changing a server's tag value
  and re-applying switches majors.

To pin an exact version on one server, run the document with Run Command:

```bash
aws ssm send-command --instance-ids <instance-id>   --document-name <AmazonLinuxK6V0DocumentName output>   --parameters K6Version=0.58.0
```

The AWS CLI document installs AWS's official v2 build at `/usr/local/bin/aws`,
which comes first on PATH. It leaves the AL2023 `awscli-2` RPM
(`/usr/bin/aws`) in place, because UserData uses it to signal CloudFormation.
It also creates an empty `~/.aws/credentials` for `ec2-user` (mode `600`, in a
`700` directory) if none exists, ready for you to fill in; an existing file is
never overwritten, and an empty file does not stop the CLI using the instance role.
Small unversioned utilities (jq, zip, unzip) come from dnf through the base
tools document.

Because the association lives beside the document in the environment stack and
references it directly, server stacks have **no cross-stack dependency on the
documents** — the documents can be edited freely without CloudFormation
blocking the update. To decouple a server from fleet config, remove its tag.

The instance's UserData does only the minimum: start the CloudWatch agent
(best-effort) and signal CloudFormation that the instance booted. It installs no
packages.

### Fleet-wide software versions

Software versions are set **once, on the environment stack**, as exact pinned
defaults (current as of October 2026), so every server gets the same release:

- `DefaultNodeVersion` (default `24`) — Node.js major version (22 / 24 / 26)
- `PowerShell74Version` (`7.4.21`), `PowerShell76Version` (`7.6.8`, LTS)
- `DotNet8Version` (`8.0.426`), `DotNet10Version` (`10.0.402`)
- `PlaywrightVersion` (`1.64.1`)
- `K6V0Version` (`0.59.0`), `K6V1Version` (`1.8.2`), `AwsCliV2Version` (`2.38.5`),
  `GhCliV2Version` (`2.103.0`)
- `DefaultNpmVersion` (`12.2.1`) — exact npm, installed over Node's bundled one

Servers only choose *which* line to install (`PowerShellVersion`,
`DotNetVersion`, `K6MajorVersion`, `AwsCliMajorVersion`, `GhCliMajorVersion` dropdowns); the exact
release is fleet-wide.

Server stacks do not take an exact version. Changing the fleet version means
updating the environment stack and re-applying the association on existing
servers (new servers pick it up automatically).

### GitHub SSH key rotation

The GitHub document (`AmazonLinuxGhCliV2Document`) does two jobs, selected by its
`Action` parameter. `Install` (the default, run by the association at launch)
installs the GitHub CLI. `RotateSshKey` is **on demand only**; nothing runs it
automatically. It:

1. generates a new ed25519 key for `ec2-user` in `~/.ssh/github/` (the private
   key never leaves the instance);
2. points the `github.com` entry in `~/.ssh/config` at the new key (a managed
   block between `# BEGIN/END clouddev-github` markers, placed at the **top** of
   the file because ssh uses the first value it finds; the rest of the file is
   kept). A hand-written `Host github.com` block further down still lists its own
   key as a fallback, so remove it once you no longer want the old key used;
3. keeps only the newest `KeepKeys` keys on the instance (default `2`: the new
   key plus the previous one for rollback) and deletes the rest;
4. prints the new public key, its fingerprint, a suggested GitHub title
   (`<server name>-<timestamp>`, where the server name is the instance's
   `DnsName` tag if set, else its CloudFormation stack name, else the instance
   ID) and the fingerprints of the keys it removed.

The same document's `Install` action also creates a code directory for `ec2-user`
(`/home/ec2-user/github` by default, set with the `CodeDirectory` document
parameter), ready to `git clone` into. It is created once, existing contents are
never touched, and re-running it is safe.

It cannot touch GitHub: the server holds no GitHub credentials. Adding the new
public key and deleting the old ones in GitHub is a manual step. GitHub SSH keys
never expire on their own, so rotation is what keeps them short-lived. Prefer
**deploy keys** (one repo, read-only by default) or a dedicated **machine user**
over a personal account's key.

**Run it from anywhere** you have AWS credentials and `ssm:SendCommand` — your
laptop, CloudShell, or the console. The instance only needs to be running and
SSM-managed.

```bash
# Look up the document name and the instance (once)
DOC=$(aws cloudformation describe-stacks --stack-name <environment-stack> \
  --query "Stacks[0].Outputs[?OutputKey=='AmazonLinuxGhCliV2DocumentName'].OutputValue" --output text)
INSTANCE=<i-0123456789abcdef0>

# Rotate the key and print the result
CMD=$(aws ssm send-command --document-name "$DOC" --instance-ids "$INSTANCE" \
  --parameters Action=RotateSshKey,KeepKeys=2 \
  --query "Command.CommandId" --output text)
aws ssm wait command-executed --command-id "$CMD" --instance-id "$INSTANCE"
aws ssm get-command-invocation --command-id "$CMD" --instance-id "$INSTANCE" \
  --query "StandardOutputContent" --output text
```

In the console: **Systems Manager > Run Command > Run command**, pick the
document, set `Action` to `RotateSshKey`, choose the instance, run, then open the
instance's output. To rotate every dev server in the environment at once, replace
`--instance-ids "$INSTANCE"` with
`--targets Key=tag:CloudDevEnvironment,Values=<value of the tag on your servers>`.

**Shortcut script.** Servers with `GhCliMajorVersion=v2` get `rotate-github-key` in `/usr/local/bin`
from the GitHub document's `Install` action at first boot (it is a copy of
[cloud/dev/scripts/rotate-github-ssh-key.sh](cloud/dev/scripts/rotate-github-ssh-key.sh);
CI checks the two match, so edit both together). It does the lookup, send, wait and output in one command. By default it targets the
instance it runs on, finds the document by name and keeps 2 keys:

```bash
# already installed on dev servers; elsewhere (e.g. a laptop):
install -m 0755 cloud/dev/scripts/rotate-github-ssh-key.sh ~/.local/bin/rotate-github-key
rotate-github-key                         # this server, using the server role
rotate-github-key -i i-0123456789abcdef0  # another server (-r region, -k keep, -d document)
```

On a dev server it needs no AWS profile: the shared server role may send this one
document to dev servers of the same environment (it is not limited to the calling
instance, because all of them share the role). From your laptop it uses your normal
AWS login, and `-p <profile>` selects a different one anywhere.

Then register the printed public key and clean up the old one. With the GitHub CLI
signed in wherever you are:

```bash
# Add the new key (paste the printed public key and title)
echo '<printed public key>' | gh ssh-key add - --title '<printed title>'
# or, as a read-only deploy key on one repo
echo '<printed public key>' | gh repo deploy-key add - --repo <owner>/<repo> --title '<printed title>'

# Remove the key the run reported as deleted (match by the printed fingerprint)
gh ssh-key list
gh ssh-key delete <id>
```

Verify on the server: `sudo -u ec2-user ssh -T git@github.com` (a "Hi
<name>!" reply means the key works). Run the document with `Action=Install` and
a `GhCliVersion` only if you want to reinstall the CLI by hand; the association
already does this with the environment stack's pinned `GhCliV2Version`.

## Deployment

> **Stack naming matters.** The environment role only allows signaling
> CloudFormation stacks whose name starts with `StackNamePrefix` (default
> `CloudDev`). **Name every server stack with the `CloudDev` prefix** (e.g.
> `CloudDev-AmzLinux-1`), or the instance's success signal is denied and the
> stack hangs until it times out. ARN prefix matching is case-sensitive —
> `cloud-dev-...` will NOT match `CloudDev*`.

### 1. Deploy the environment stack

```bash
aws cloudformation deploy \
  --template-file cloud/dev/environment/cloud-dev-environment.yaml \
  --stack-name CloudDevEnv \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      VpcMode=public \
      AllowedCidr=<your.ip>/32
```

- `--capabilities CAPABILITY_IAM` is required (the stack creates IAM resources).
- `AllowedCidr` is the SSH source for the dev-server security group (set it to
  your public IP with `/32`). It is only consulted when a VPC is created.
- Name it `CloudDevEnv` to match the server stacks' `EnvironmentStackName`
  default.

### 2. Deploy a server stack

```bash
aws cloudformation deploy \
  --template-file cloud/dev/server/cloud-dev-server-amazon-linux.yaml \
  --stack-name CloudDev-AmzLinux-1 \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      EnvironmentStackName=CloudDevEnv \
      AllowedCidr=<your.ip>/32 \
      KeyPairName=<your-key-pair> \
      VpcId=<vpc-id> \
      SubnetId=<public-subnet-id>
```

Use the ARM template (`...-arm.yaml`) for a Graviton instance; it is otherwise
identical.

**The stack name must start with the environment stack's `StackNamePrefix`**
(default `CloudDev`). The instance signals CloudFormation from UserData, and the
dev server role may only signal stacks named `<prefix>*`. With any other name the
signal is denied, the instance still boots, and the stack fails after the
`CreationPolicy` timeout (15 minutes; 30 for the Ollama server) with "Failed to
receive 1 resource signal(s)". The server templates import the prefix
(`<environment-stack>-StackNamePrefix`) and log the problem at boot, so update the
environment stack **before** deploying a server stack from these templates.

Bootstrap signalling is logged as `[cfn-signal <time>]` lines to
`/var/log/cloud-init-output.log` (streamed to the bootstrap CloudWatch log group),
the journal (`journalctl -t cfn-signal`) and the EC2 console output (Actions >
Monitor and troubleshoot > Get system log). They record the stack, instance, AWS
CLI version and caller identity, whether the stack name matches the prefix, and
each signal attempt with its full error. If the bootstrap script itself fails, it
logs the failing command and line (`ERROR: command failed ... at line N`) and copies
the last 300 lines of the bootstrap log to the bootstrap log group as stream
`<instance-id>/bootstrap-failure` **before** sending the `FAILURE` signal, so the
reason survives CloudFormation deleting the instance on rollback. To debug a failed
create with the instance still running, deploy with `--disable-rollback`.

The instance reaches `CREATE_COMPLETE` once it boots and signals — **before**
Node/PowerShell finish installing. Those install asynchronously via SSM State
Manager after the instance registers; check their status in SSM association
compliance (or just connect and run `node --version` / `pwsh --version`).

### 3. (Optional) Deploy the developer permission set

`cloud-dev-permission-set.yaml` creates an IAM Identity Center permission set
that lets developers start, stop and reboot an environment's dev servers and
apply its SSM documents to them, either with Run Command or by re-running the
associations. It grants no terminate and no arbitrary commands
(`AWS-RunShellScript`).

```bash
aws cloudformation deploy   --template-file cloud/dev/environment/cloud-dev-permission-set.yaml   --stack-name CloudDevPermissionSet   --parameter-overrides       InstanceArn=<arn:aws:sso:::instance/ssoins-...>       EnvironmentStackName=CloudDevEnv
```

- Deploy it in the Identity Center **management (or delegated administrator)
  account**, then assign the permission set to users or groups for the account
  that hosts the environment.
- Instances are matched by their `CloudDevEnvironment` tag, which the server
  stacks set to `EnvironmentStackName`. Update existing server stacks to add
  that tag. The update changes the tag in place and does not replace the
  instance.
- Documents are matched by CloudFormation's `<EnvironmentStackName>-*` naming,
  so only that environment's documents can be sent.

## Private Ollama LLM server

`cloud/dev/server/cloud-dev-ollama-server.yaml` runs [Ollama](https://ollama.com)
on a GPU instance (default `g6.xlarge`, 24 GB VRAM; Deep Learning Base AMI on
Amazon Linux 2023) so dev servers can use an open-source model from the shell
or an editor. It reuses the environment stack's instance profile (Session
Manager, no SSH) and the same idle auto-stop alarm as the dev servers.

Ollama has no authentication, so access is controlled by security groups. The
stack creates an empty **Ollama client security group** and allows TCP 11434
from it only. Attach that group to any dev server in the same VPC to grant
access.

```bash
# 1. Deploy the Ollama server (same VPC as your dev servers)
aws cloudformation deploy   --template-file cloud/dev/server/cloud-dev-ollama-server.yaml   --stack-name CloudDevOllama   --parameter-overrides       VpcId=<vpc-id> SubnetId=<subnet-id>       OllamaModel=qwen2.5-coder:14b

# 2. Read the client security group and endpoint outputs
aws cloudformation describe-stacks --stack-name CloudDevOllama   --query "Stacks[0].Outputs"

# 3. Update each dev server stack, passing the client group
#    (an in-place change; the instance is not replaced)
#    OllamaClientSecurityGroupId=<sg-...>
```

From a dev server:

```bash
export OLLAMA_HOST=http://<private-ip>:11434            # ollama CLI
export OPENAI_BASE_URL=http://<private-ip>:11434/v1 OPENAI_API_KEY=ollama   # OpenAI-compatible tools
```

Notes:

- GPU instances are costly (a `g6.xlarge` is roughly $0.80/hour on demand), so
  keep idle auto-stop on. A stopped instance still pays for its EBS volume.
- New accounts often have a zero quota for "Running On-Demand G and VT
  instances"; request an increase before the first deploy.
- The model pull at boot is best-effort. Pull more models later with
  `ollama pull` over Session Manager.

## Connecting

Connect with **Session Manager**: no open port, no key to share, access is
controlled by your AWS permissions and every session is logged in CloudTrail.
Leave the server stack's `AllowedCidr` empty (the default) and the security group
opens **no inbound port at all**; Session Manager only needs the instance's
outbound connection to AWS. If you do set `AllowedCidr`, port 22 is opened to
that CIDR only.

**Shell.** Console: EC2 > select the instance > Connect > Session Manager. CLI
(needs AWS CLI v2 and the
[Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)):

```bash
aws ssm start-session --target <instance-id> --region <region>
```

The server stack's `SessionManagerCommand` output prints this line. Sessions start
as `ssm-user`; run `sudo su - ec2-user` for the normal environment (Node, `gh`,
`~/.aws` and the rest are set up for `ec2-user`).

**SSH and VS Code Remote-SSH over Session Manager.** The SSH connection is
tunnelled through SSM, so it works with port 22 closed. It needs the key pair the
stack was created with. Add to `~/.ssh/config` on your machine:

```
Host i-* mi-*
    ProxyCommand aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p --region <region>
    User ec2-user
    IdentityFile ~/.ssh/<your-key-pair>.pem
    StrictHostKeyChecking accept-new
```

Then `ssh i-0123456789abcdef0`, or in VS Code run **Remote-SSH: Connect to
Host...** and enter the instance ID. For SSO profiles add `--profile <name>` to
the `ProxyCommand` or set `AWS_PROFILE`. VS Code installs its server on the
instance, which needs outbound internet.

**Permissions.** The CloudDev permission set allows `ssm:StartSession` on
instances tagged `CloudDevEnvironment=<stack>`, using only the shell document
(`SSM-SessionManagerRunShell`) and the SSH tunnel document (`AWS-StartSSHSession`),
and lets you end or resume your own sessions. Anyone who can start a session gets a
shell on the server, so assign the permission set accordingly.

> Why no public-IP output? The public IP is **ephemeral**: it changes on every
> stop/start, which the idle auto-stop safeguard (below) triggers. Session Manager
> targets the instance ID, which never changes. The default login user for Amazon
> Linux is `ec2-user`.

## Idle auto-stop safeguard

Each server creates a CloudWatch alarm that **stops** (not terminates) the
instance when it is idle, as a cost guard against a forgotten-running box:

- `EnableIdleShutdown` (default `true`)
- `IdleCpuThresholdPercent` (default `5`) — CPU % below which it is "idle"
- `IdleNetworkThresholdMB` (default `5`) — combined NetworkIn + NetworkOut
  (MB per 5 minutes) below which it is "idle"
- `IdleStopPeriods` (default `12`) — consecutive 5-minute periods that are idle
  (CPU **and** network both below their thresholds) before stopping
  (12 × 5 min = 60 minutes)

The alarm is a metric-math alarm over `CPUUtilization`, `NetworkIn` and
`NetworkOut`, using a 300-second period to match EC2 basic monitoring's
5-minute resolution. Requiring both signals keeps background CPU noise from
holding a quiet box up, and keeps a busy download from being stopped.
CloudWatch does not allow the built-in EC2 stop action on metric-math alarms, so
the alarm has no action: an EventBridge rule sends its `ALARM` state change to a
small Lambda (`IdleStopFunction`, allowed to stop only that one instance), which
stops it. The instance stops (EBS persists; restart it later).
A truly idle box you are connected to will still stop after the window — raise
`IdleStopPeriods` or set `EnableIdleShutdown=false` if that is a problem.

## DNS for dev servers (optional)

Set the environment stack's `HostedZoneId` (a Route 53 zone in the same account)
and each dev server gets an A record for its public IP. Leave it empty (the
default) and none of this is created.

- An EventBridge rule sends EC2 `running`, `stopped` and `terminated` events to a
  Lambda (`DnsRegistrarFunction`; its `HOSTED_ZONE_ID` environment variable is the
  parameter, and it does nothing if that is empty).
- On `running` it UPSERTs `<label>.<zone name>` with a 60-second TTL and the
  instance's public IP. These servers have no Elastic IP, so the address changes
  on every stop/start, which is why the record is refreshed on each start.
- On `stopped` or `terminated` it deletes the record, so DNS never points at an
  address that may belong to someone else.
- `<label>` is the server stack's optional `DnsName` parameter (stored as the
  instance's `DnsName` tag) if you set one, otherwise the CloudFormation stack
  name, lowercased with other characters turned into `-` (stack
  `CloudDev-Music-Arm-2` in zone `dev.example.com` becomes
  `clouddev-music-arm-2.dev.example.com`).
- It only touches instances tagged `CloudDevEnvironment=<this environment stack>`,
  and its role can change records in that one zone only. The instances need no
  Route 53 permission. An instance with no public IP (private subnet) is logged
  and skipped.

Logs are in `/clouddev/<environment-stack>/dns-registrar` in CloudWatch Logs.

To turn it on, update the environment stack with your zone ID, for example
`HostedZoneId=Z055297224GATXGNE59WY` (zone `clouddev.silversalmon.com`). Servers
that are already running get their record the next time they start; to register one
that is running now, stop and start it. The record is removed when the server
stops, so use the name only while the server is up.

## Environment stack parameters (summary)

| Parameter | Default | Purpose |
|---|---|---|
| `StackNamePrefix` | `CloudDev` | Scopes which stacks the shared role may signal |
| `LogRetentionDays` | `7` | Bootstrap log retention |
| `DefaultNodeVersion` | `24` | Fleet-wide Node.js version |
| `PowerShell74Version` | `7.4.21` | Exact PowerShell 7.4.x release |
| `PowerShell76Version` | `7.6.8` | Exact PowerShell 7.6.x release |
| `DotNet8Version` | `8.0.426` | Exact .NET 8 SDK |
| `DotNet10Version` | `10.0.402` | Exact .NET 10 SDK |
| `PlaywrightVersion` | `1.64.1` | Playwright version to install Chromium for |
| `K6V0Version` | `0.59.0` | Exact k6 0.x release |
| `K6V1Version` | `1.8.2` | Exact k6 1.x release |
| `AwsCliV2Version` | `2.38.5` | Exact AWS CLI 2.x release |
| `GhCliV2Version` | `2.103.0` | Exact GitHub CLI 2.x release |
| `DefaultNpmVersion` | `12.2.1` | Exact npm version |
| `HostedZoneId` | *(empty)* | Optional Route 53 zone; registers DNS for each server (see [DNS](#dns-for-dev-servers-optional)) |
| `VpcMode` | `none` | `none` / `public` / `public-private` |
| `AzCount` | `1` | Availability Zones (1–3) when a VPC is created |
| `VpcCidr` | `10.0.0.0/16` | VPC CIDR when a VPC is created |
| `AllowedCidr` | *(required)* | SSH source CIDR for the dev-server security group |

## Validation

All templates must pass cfn-lint with zero errors and warnings. CI
(`.github/workflows/validate-templates.yml`) lints every template on push and
pull request. To lint locally:

```bash
cfn-lint cloud/dev/**/*.yaml ses/*.yaml redirect/*.yaml
```

## Domain redirect

`redirect/domain-redirect.yaml` redirects every request to a domain (and
optionally `www.` of it) to a URL. It creates a DNS-validated ACM certificate,
a CloudFront distribution whose viewer-request CloudFront Function returns the
redirect at the edge, and A/AAAA alias records in the hosted zone. HTTP and
HTTPS both redirect in a single hop.

```bash
aws cloudformation deploy \
  --region us-east-1 \
  --template-file redirect/domain-redirect.yaml \
  --stack-name redirect-old-example-com \
  --parameter-overrides \
      DomainName=old-example.com \
      HostedZoneId=<zone-id> \
      RedirectUrl=https://www.example.com
```

- **Must be deployed in `us-east-1`**, because CloudFront only accepts ACM
  certificates from there. A template rule enforces this.
- The hosted zone must be in the same account, and must be authoritative for
  the domain (ACM validation waits for it).
- The domain must not already have A/AAAA records. Delete them first, or the
  stack fails.
- First deploys take roughly 5–15 minutes (certificate validation, then
  distribution rollout).

| Parameter | Default | Purpose |
|---|---|---|
| `DomainName` | *(required)* | Domain to redirect from |
| `HostedZoneId` | *(required)* | Route 53 zone for `DomainName` |
| `RedirectUrl` | *(required)* | Absolute `http(s)://` URL to redirect to |
| `StatusCode` | `301` | `301` / `302` / `307` / `308`. Browsers cache 301/308, so use 302 while testing |
| `PreservePath` | `false` | `true` appends the request path and query string (`/a?b=c` → `RedirectUrl/a?b=c`) |
| `IncludeWww` | `false` | Also redirect `www.DomainName` |

## GitHub Actions ephemeral Fargate runners

`github/runner/github-actions-fargate-runner.yaml` deploys on-demand,
single-use GitHub Actions self-hosted runners on AWS Fargate. Idle, nothing runs
(no EC2, no containers); each queued job gets its own fresh task.

```
GitHub workflow_job webhook
  -> API Gateway (HTTP API, POST /webhook)
  -> Lambda "webhook": verifies X-Hub-Signature-256 (HMAC), filters repo/labels
  -> SQS queue (+ DLQ): buffers and rate-limits
  -> Lambda "scale-up": confirms the job is still queued, enforces MaxRunners,
     creates a just-in-time (JIT) runner via the GitHub API, calls ecs:RunTask
  -> Fargate task (one container): run.sh --jitconfig  -> runs ONE job -> exits
```

A JIT runner accepts exactly one job and GitHub removes it afterwards, so the
container needs no PAT and no deregistration step; the PAT only lives in
Secrets Manager and the scale-up Lambda. The stack creates a VPC (2 public + 2
private subnets, S3 gateway endpoint, optional ECR/Logs interface endpoints), an
ECR repository, an ECS cluster with `FARGATE` and `FARGATE_SPOT`, and all IAM
roles (separate roles for each Lambda, the task execution role, and a task role
that holds the AWS permissions your jobs get).

```bash
# 1. Deploy (the template has a Lambda and IAM roles, so CAPABILITY_IAM is needed)
aws cloudformation deploy \
  --template-file github/runner/github-actions-fargate-runner.yaml \
  --stack-name gha-fargate-runner --capabilities CAPABILITY_IAM \
  --parameter-overrides GitHubOrg=my-org GitHubRepo=my-repo \
      GitHubPat=<token> RunnerLabels=fargate

# 2. Build and push the runner image (outputs: RunnerRepositoryUri)
cd github/runner/image
aws ecr get-login-password | docker login --username AWS --password-stdin <repo-uri-host>
docker buildx build --platform linux/amd64 -t <RunnerRepositoryUri>:latest --push .

# 3. In GitHub: Settings -> Webhooks -> Add webhook
#    Payload URL = WebhookUrl output, content type application/json,
#    Secret = output of the WebhookSecretCommand output, event = "Workflow jobs"

# 4. In workflows
#    runs-on: [self-hosted, linux, x64, fargate]
```

| Parameter | Default | Purpose |
|---|---|---|
| `GitHubOrg` | *(required)* | Organization or user |
| `GitHubRepo` | blank | Repository name; blank = organization-level runners |
| `GitHubPat` | *(required)* | Token for the scale-up Lambda (fine-grained: repo "Administration: write" + "Actions: read", or org "Self-hosted runners: write") |
| `RunnerGroupId` | `1` | Runner group (org runners) |
| `RunnerLabels` | `fargate` | Custom labels; `self-hosted`, `linux`, `x64`/`arm64` always added |
| `ContainerImage` | blank | Image URI; blank = the stack's ECR repository `:latest` |
| `CpuArchitecture` | `X86_64` | `X86_64` or `ARM64` (must match the image) |
| `TaskCpu` / `TaskMemory` / `EphemeralStorageGiB` | `2048` / `4096` / `30` | Task size |
| `UseFargateSpot` | `false` | Spot is cheaper, but interruptions fail the running job |
| `MaxRunners` | `10` | Concurrent task cap; extra jobs wait in SQS |
| `MaxRunnerSeconds` | `21600` | Hard per-task time limit (also reaps runners that never get a job) |
| `RunnerManagedPolicyArn` | blank | Managed policy giving jobs AWS permissions |
| `NatMode` | `SingleNat` | `SingleNat` = private subnets + one NAT (~$32/month idle); `PublicIp` = public subnets, no NAT, no idle cost, still no inbound |
| `CreateInterfaceEndpoints` | `false` | ECR/Logs interface endpoints (hourly cost) |

Notes and limits:

- **Idle cost** is zero except the NAT gateway in the default `SingleNat` mode
  (Secrets Manager secrets are about $0.80/month). Use `NatMode=PublicIp` for a
  truly pay-per-job setup; runner tasks still have no inbound access.
- Runners reach github.com, so private subnets need the NAT; the endpoints only
  save NAT data charges.
- Fargate cannot run Docker-in-Docker or privileged containers, so jobs that
  build images with the Docker daemon need Kaniko/Buildah or a different runner.
- Jobs wait up to an hour in the queue when `MaxRunners` is reached, then are
  dropped; GitHub fails jobs that stay queued 24 hours anyway.
- The JIT config is passed to the task as an environment override; it is
  single-use and only valid for that one runner.

## Roadmap / parked ideas

- **Ubuntu dev server** — a sibling of the Amazon Linux server templates (apt,
  the `ubuntu` login user) with its own SSM documents.
- **Versioned, pinnable SSM documents** — version-named documents
  (`DeletionPolicy: Retain`) with one tag-targeted association per version, so a
  server can pin to a specific config version via its tag value while the fleet
  default tracks the latest.
