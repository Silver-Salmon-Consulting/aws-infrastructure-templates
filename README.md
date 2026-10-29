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
  cloud-dev-environment.yaml          # shared: IAM role, log group, SSM documents, VPC
  cloud-dev-permission-set.yaml       # Identity Center permission set for developers
  cloud-dev-server-amazon-linux.yaml      # x86_64 (AMD) dev server
  cloud-dev-server-amazon-linux-arm.yaml  # arm64 (Graviton) dev server
  cloud-dev-ollama-server.yaml            # private GPU Ollama LLM server
```

### Getting started

Two roles: an **admin** sets up AWS and creates servers; a **developer**
connects to one with VS Code.

#### Admin setup

##### Once per AWS account

1. Deploy the **environment stack** (`CloudDevEnv`). See
   [Deploy the environment stack](#1-deploy-the-environment-stack).
2. Deploy the **permission set** in the Identity Center account, and assign it
   to your developers for this account. See
   [Deploy the developer permission set](#3-optional-deploy-the-developer-permission-set).

##### For each developer and project

Deploy a **server stack**. Its name must start with `CloudDev`:

```bash
aws cloudformation deploy \
  --template-file cloud/dev/cloud-dev-server-amazon-linux-arm.yaml \
  --stack-name CloudDev-MyProject-Arm-1 \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      KeyPairName=<key-pair> VpcId=<vpc-id> SubnetId=<subnet-id> \
      GitUserName="<name>" GitUserEmail=<email>
```

Then give the developer:

- the stack's `InstanceId` output;
- the key pair's `.pem` file;
- the AWS region and the name of the permission set to sign in with.

##### Rebuilding a server

Update the stack with `ServerEnabled=false`, then again with
`ServerEnabled=true`. The developer's whole home folder (code, Git keys,
logins, settings) is on the stack's
[workspace disk](#workspace-disk-code-and-caches-that-survive-rebuilds), so
the rebuilt server picks up where the old one left off. Only the OS is new, and
the server gets a new `InstanceId`. A **new stack** starts with a fresh home.

#### Developer setup

##### 1. Install the tools

- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
  (Windows: `winget install Amazon.SessionManagerPlugin`)
- The VS Code **Remote - SSH** extension

Then fully quit VS Code (File → Exit) and start it again, so it picks up the
plugin on its PATH.

##### 2. Sign in to AWS

Use the CloudDev permission set:

```bash
aws configure sso                      # once
aws sso login --profile <profile>      # each day
```

##### 3. Save your key

Save the `.pem` file from your admin as `~/.ssh/<key-pair>.pem`. On Windows,
make it private, or SSH refuses to use it:

```powershell
icacls $env:USERPROFILE\.ssh\<key-pair>.pem /inheritance:r /grant:r "$($env:USERNAME):R"
```

##### 4. Add the server to your SSH config

Add this to `~/.ssh/config`:

```
Host my-dev-server
    HostName <instance-id>
    User ec2-user
    IdentityFile ~/.ssh/<key-pair>.pem
    ProxyCommand aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p --region <region> --profile <profile>
    StrictHostKeyChecking accept-new
    ForwardAgent yes
```

On Windows, wrap the `ProxyCommand` in PowerShell:

```
    ProxyCommand C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe "aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p --region <region> --profile <profile>"
```

##### 5. Connect with VS Code

Run **Remote-SSH: Connect to Host… → my-dev-server**, then open the folder
`/home/ec2-user/code`. The first connection takes a minute or two while VS
Code installs its server.

##### 6. Give the server a Git SSH key with `rotate-git-key`

Every server has `rotate-git-key`, which makes an SSH key for GitHub (or Azure
DevOps, if that is the server's source provider). In VS Code's terminal on the
server:

1. Create the key:

   ```bash
   rotate-git-key
   ```

   It prints the new **public** key and a title named after the server. The
   private key never leaves the server.
2. Add the public key where the output says:
   - **GitHub:** Settings → SSH and GPG keys → New SSH key
   - **Azure DevOps:** User settings → SSH public keys → New Key
3. Check it works:

   ```bash
   ssh -T git@github.com     # "Hi <name>! You've successfully authenticated"
   ```

4. Clone into `~/code`:

   ```bash
   cd ~/code && git clone git@github.com:<owner>/<repo>.git
   ```

**Rotating later:** run `rotate-git-key` again and add the new key. It keeps
the previous key for rollback and lists any older ones it removed, which you
then delete in GitHub. More options: [Rotating the SSH key](#rotating-the-ssh-key).

**After a rebuild:** nothing to do. The key is in your home folder on the
workspace disk, so a rebuilt server keeps it. A new stack needs its own key.

**Alternative: use your own key instead.** With `ForwardAgent yes` in your SSH
config, git on the server can use the key on your own machine while you are
connected, and no key is stored on the server. Load it into your local agent
(on Windows, enable the `ssh-agent` service first) with
`ssh-add ~/.ssh/id_ed25519`. A key made by `rotate-git-key` takes precedence
over a forwarded one.

#### Troubleshooting

Test the tunnel on its own first:

```bash
aws ssm start-session --target <instance-id> --region <region> --profile <profile>
```

| What you see | Fix |
| --- | --- |
| `Connection closed by UNKNOWN port 65535` | The `ProxyCommand` failed. Run the tunnel test above to see why |
| `SSL validation failed ... CERTIFICATE_VERIFY_FAILED` | Antivirus or a proxy is inspecting HTTPS. Exclude `*.amazonaws.com` and `*.awsapps.com` from HTTPS scanning |
| `AccessDeniedException ... ssm:StartSession` | Your permission set is missing the Session Manager rules. Ask an admin to redeploy it from this repo |
| `TargetNotConnected` | The server is stopped (idle auto-stop). Start it, or wait a minute after a new deploy |
| Tunnel test works but VS Code fails | VS Code still has the PATH from before the plugin was installed. Fully quit and restart it |
| `Token has expired` | `aws sso login --profile <profile>` |

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
  - a workspace document and association that attach and mount each server's
    [workspace disk](#workspace-disk-code-and-caches-that-survive-rebuilds),
    optional daily snapshots of those disks, and a subnet lookup function that
    tells server stacks their subnet's Availability Zone;
  - an optional VPC (`public` or `public-private`, 1–3 AZs).
- **Server stacks** (`cloud-dev-server-*.yaml`) — each launches one EC2 instance
  and owns a separate workspace disk for code and caches that outlives it.
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
   - `AzCliV2ConfigAssociation` targets `tag:CloudDevAzCliConfig = v2`
   - `SourceControlConfigAssociation` targets `tag:CloudDevSourceProvider = GitHub`
     or `AzureDevOps` (see [Source control](#source-control-github-or-azure-devops))
   - `WorkspaceConfigAssociation` targets `tag:CloudDevWorkspaceConfig = enabled`
     and, unlike the others, re-runs every 30 minutes (see [Workspace disk](#workspace-disk-code-and-caches-that-survive-rebuilds))
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
   - `CloudDevSourceProvider = <SourceProvider>` (`GitHub` / `AzureDevOps` /
     `none`, default `GitHub`), plus `CloudDevGhCliConfig = v2` for GitHub or
     `CloudDevAzCliConfig = v2` for Azure DevOps (`none` otherwise)
   - `CloudDevGitUserName = <GitUserName>` and `CloudDevGitUserEmail =
     <GitUserEmail>`, each only when set (default empty)
   - `CloudDevWorkspaceConfig = enabled` (always) and
     `CloudDevWorkspaceVolumeId = <the stack's workspace volume>`

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

Tools whose version matters to a project (PowerShell, .NET, k6, the AWS CLI, the GitHub CLI, the Azure CLI)
follow one pattern: **one SSM document per tool per major version** (PowerShell:
per release line), for example `AmazonLinuxK6V0Document` and
`AmazonLinuxK6V1Document`. Nothing floats to `latest`: every document takes an
**exact version** with no default of its own, and the association passes it in
from a pinned environment-stack parameter (`PowerShell74Version`,
`PowerShell76Version`, `DotNet8Version`, `DotNet10Version`, `K6V0Version`,
`K6V1Version`, `AwsCliV2Version`, `GhCliV2Version`, `AzCliV2Version`).

- The document fixes the major version. Its version parameter (`PowerShellVersion`,
  `DotNetVersion`, `K6Version`, `AwsCliVersion`) takes an exact version
  (`0.59.0`), checked against the major by `allowedPattern`.
- Each major has its own association. All majors of a tool share one tag key
  and differ by tag **value**, so a server selects exactly one major
  (`CloudDevK6Config = v0`), and `none` selects nothing. Server stacks expose
  this as `K6MajorVersion` / `AwsCliMajorVersion`. The GitHub and Azure CLIs
  are chosen by `SourceProvider` instead.
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
  `GhCliV2Version` (`2.103.2`), `AzCliV2Version` (`2.91.0`)
- `DefaultNpmVersion` (`12.2.1`) — exact npm, installed over Node's bundled one

The stack echoes each one as an output named `<parameter>Output`
(`DotNet8VersionOutput`, `GhCliV2VersionOutput`, ...), so the stack's **Outputs**
tab shows what is deployed, and you can copy a value from there when running a
document by hand. From the CLI:

```bash
aws cloudformation describe-stacks --stack-name <environment-stack> \
  --query "Stacks[0].Outputs[?ends_with(OutputKey,'VersionOutput')].[OutputKey,OutputValue]" --output table
```

Servers only choose *which* line to install (`PowerShellVersion`,
`DotNetVersion`, `K6MajorVersion`, `AwsCliMajorVersion`, `SourceProvider` dropdowns); the exact
release is fleet-wide.

Server stacks do not take an exact version. Changing the fleet version means
updating the environment stack and re-applying the association on existing
servers (new servers pick it up automatically).

### Source control: GitHub or Azure DevOps

Each server stack picks where its Git repos live with **`SourceProvider`**
(`GitHub`, the default, / `AzureDevOps` / `none`). The choice becomes the
instance's `CloudDevSourceProvider` tag and decides what the server gets:

| | `GitHub` | `AzureDevOps` |
| --- | --- | --- |
| CLI | GitHub CLI `gh` (`GhCliV2Version`) | Azure CLI `az` (`AzCliV2Version`) + `azure-devops` extension |
| SSH key `rotate-git-key` makes | ed25519 | 4096-bit `ssh-rsa` (Azure DevOps accepts only RSA) |
| Hosts in the managed `~/.ssh/config` block | `github.com` | `ssh.dev.azure.com`, `vs-ssh.visualstudio.com` |
| Keys on the server | `~/.ssh/github/` | `~/.ssh/azuredevops/` |
| Code directory | `~/code` (on the workspace disk) | `~/code` (on the workspace disk) |

Both get `rotate-git-key` in `/usr/local/bin` (`rotate-github-key` still works as
a link to it). git itself comes with the Node document. `none` sets up neither.

Three documents do this:

- **`AmazonLinuxSourceControlDocument`** (provider-neutral). `Action=Setup` (run
  by its association on every server with a provider) installs `rotate-git-key`
  and sets `ec2-user`'s global git `user.name` /
  `user.email` from the stack's optional **`GitUserName`** / **`GitUserEmail`**
  (an empty one is left alone). Code goes in `~/code` on the
  [workspace disk](#workspace-disk-code-and-caches-that-survive-rebuilds); on a
  server without one (or with `CodeDirectory` set) it creates
  `/home/ec2-user/github` or `/home/ec2-user/azuredevops` instead, never touching
  existing contents. `Action=RotateSshKey` is **on demand only**; nothing runs it
  automatically.
- **`AmazonLinuxGhCliV2Document`** installs `gh` (`CloudDevGhCliConfig = v2`).
- **`AmazonLinuxAzCliV2Document`** installs `az` from Microsoft's RHEL 9 RPM
  (x86_64 or arm64, pinned, signature-checked; no repo is added) and the
  `azure-devops` extension for `ec2-user`, with telemetry off
  (`CloudDevAzCliConfig = v2`).

Changing `SourceProvider` on an existing server switches which CLI the
associations target; the other CLI stays installed until you remove it.

Changing `GitUserName` / `GitUserEmail` on an existing server updates its tags
only; the association does not re-run on a tag change. Apply it with **Systems
Manager > State Manager > `<env>-source-control` > Apply association now**, or
run `git config --global` yourself. Clearing a value leaves the old setting in
place.

#### Signing in to the CLI (optional)

SSH is enough for `git clone`/`pull`/`push`. The CLI is for pull requests,
pipelines and so on, and needs its own sign-in as `ec2-user`:

```bash
# GitHub
gh auth login                     # or: export GH_TOKEN=<token>

# Azure DevOps: a PAT with the scopes you need (e.g. Code, Build)
az devops login --organization https://dev.azure.com/<org>   # paste the PAT
az devops configure --defaults organization=https://dev.azure.com/<org> project=<project>
az repos list -o table
```

#### Rotating the SSH key

`RotateSshKey`:

1. generates a new key for `ec2-user` in `~/.ssh/<provider>/`: **ed25519 for
   GitHub, 4096-bit ssh-rsa for Azure DevOps**. The private key never leaves the
   instance;
2. points that provider's managed block in `~/.ssh/config` at the new key
   (between `# BEGIN/END clouddev-github` or `clouddev-azuredevops` markers,
   placed at the **top** of the file because ssh uses the first value it finds;
   the rest of the file is kept). A hand-written block for the same host further
   down still lists its own key as a fallback, so remove it once you no longer
   want the old key used;
3. keeps only the newest `KeepKeys` keys **for that provider** (default `2`: the
   new key plus the previous one for rollback) and deletes the rest. The other
   provider's keys are never touched;
4. prints the new public key, its fingerprint, where to add it, a suggested
   title (`<server name>-<timestamp>`, where the server name is the instance's
   `DnsName` tag if set, else its CloudFormation stack name, else the instance
   ID), the fingerprints of the keys it removed and the command to check it.

The provider is the server's own `SourceProvider` unless you pass one. Passing
the other one gives a server keys for **both** (e.g. a GitHub server that also
pulls from Azure DevOps); each provider keeps its own key, block and `KeepKeys`.

It cannot touch GitHub or Azure DevOps: the server holds no credentials for
either. Adding the new public key and deleting the old ones is a manual step.
SSH keys there never expire on their own, so rotation is what keeps them
short-lived. On GitHub prefer **deploy keys** (one repo, read-only by default) or
a dedicated **machine user** over a personal account's key.

**With `rotate-git-key`** (the simplest way). By default it rotates the key of
the server it runs on, for that server's provider, keeping 2 keys:

| Flag | Meaning | Default |
| --- | --- | --- |
| `-P github\|azuredevops` | provider whose key to rotate | the server's `SourceProvider` |
| `-k N` | that provider's keys to keep on the instance, 1-9, including the new one | `2` |
| `-i <instance-id>` | server to rotate | the server it runs on |
| `-r <region>` | AWS region | instance metadata, else `AWS_REGION` |
| `-p <profile>` | AWS CLI profile | none (server role / your default login) |
| `-d <document>` | source control SSM document name | found by name |
| `-h` | print usage | |

```bash
# On a dev server (rotates that server, using the server role)
rotate-git-key                       # its own provider: ed25519 (GitHub) or ssh-rsa (Azure DevOps), keep 2
rotate-git-key -k 1                  # its own provider, keep only the new key
rotate-git-key -P github             # GitHub key (ed25519), whatever the server's provider
rotate-git-key -P azuredevops        # Azure DevOps key (ssh-rsa), whatever the server's provider
rotate-git-key -P azuredevops -k 3   # Azure DevOps key, keep the new one + 2 previous

# From a laptop or CloudShell (name the server; add -r if it is not your default region)
install -m 0755 cloud/dev/scripts/rotate-git-ssh-key.sh ~/.local/bin/rotate-git-key
rotate-git-key -i i-0123456789abcdef0
rotate-git-key -i i-0123456789abcdef0 -P azuredevops
rotate-git-key -i i-0123456789abcdef0 -P github -k 3 -r us-west-2 -p clouddev
rotate-git-key -i i-0123456789abcdef0 -d <stack>-AmazonLinuxSourceControlDocument-XXXX  # if the lookup fails
```

On a dev server it needs no AWS profile: the shared server role may send this one
document to dev servers of the same environment (it is not limited to the calling
instance, because all of them share the role). From your laptop it uses your normal
AWS login, and `-p <profile>` selects a different one anywhere. The script is
[cloud/dev/scripts/rotate-git-ssh-key.sh](cloud/dev/scripts/rotate-git-ssh-key.sh);
the source control document embeds a copy and CI checks the two match, so edit
both together.

**With the AWS CLI directly**, from anywhere you have AWS credentials and
`ssm:SendCommand`. The instance only needs to be running and SSM-managed.

```bash
# Look up the document name and the instance (once)
DOC=$(aws cloudformation describe-stacks --stack-name <environment-stack> \
  --query "Stacks[0].Outputs[?OutputKey=='AmazonLinuxSourceControlDocumentName'].OutputValue" --output text)
INSTANCE=<i-0123456789abcdef0>

# Pick ONE --parameters value:
PARAMS="Action=RotateSshKey"                                  # server's own provider, keep 2
PARAMS="Action=RotateSshKey,KeepKeys=1"                       # server's own provider, keep only the new key
PARAMS="Action=RotateSshKey,Provider=GitHub"                  # GitHub key (ed25519), keep 2
PARAMS="Action=RotateSshKey,Provider=AzureDevOps"             # Azure DevOps key (ssh-rsa), keep 2
PARAMS="Action=RotateSshKey,Provider=AzureDevOps,KeepKeys=3"  # Azure DevOps key, keep the new one + 2 previous

# Rotate the key and print the result
CMD=$(aws ssm send-command --document-name "$DOC" --instance-ids "$INSTANCE" \
  --parameters "$PARAMS" \
  --query "Command.CommandId" --output text)
aws ssm wait command-executed --command-id "$CMD" --instance-id "$INSTANCE"
aws ssm get-command-invocation --command-id "$CMD" --instance-id "$INSTANCE" \
  --query "StandardOutputContent" --output text
```

To rotate every server with one provider at once, replace
`--instance-ids "$INSTANCE"` with
`--targets Key=tag:CloudDevSourceProvider,Values=GitHub` (or `AzureDevOps`), then
read each instance's output with `get-command-invocation`.

**In the console:** Systems Manager > Run Command > Run command, pick the
source control document, set `Action` to `RotateSshKey` (it defaults to `Setup`,
which only reinstalls `rotate-git-key`), leave `Provider` at `auto` or pick
`GitHub` / `AzureDevOps`, set `KeepKeys` if you want, choose the instance, run,
then open the instance's output.

#### Registering the new key

| | GitHub | Azure DevOps |
| --- | --- | --- |
| Add the key | Settings > SSH and GPG keys > New SSH key, or a repo's Settings > Deploy keys | User settings (top right) > SSH public keys > New Key |
| Remove old keys | match the fingerprints printed under "Removed" | same |
| Check on the server | `sudo -u ec2-user ssh -T git@github.com` → `Hi <name>!` | `sudo -u ec2-user ssh -T git@ssh.dev.azure.com` → `remote: Shell access is not supported.` |
| Clone URL | `git@github.com:<owner>/<repo>.git` | `git@ssh.dev.azure.com:v3/<org>/<project>/<repo>` |

With the GitHub CLI signed in, you can add and remove keys from the command line:

```bash
echo '<printed public key>' | gh ssh-key add - --title '<printed title>'
# or, as a read-only deploy key on one repo
echo '<printed public key>' | gh repo deploy-key add - --repo <owner>/<repo> --title '<printed title>'
gh ssh-key list && gh ssh-key delete <id>
```

#### Re-running setup or the CLI install by hand

The associations do this at launch and whenever their parameters change. To do
it now on one server (e.g. to refresh `rotate-git-key` after updating the
environment stack), leave the version parameters at their defaults (the stack's
pinned versions):

```bash
aws ssm send-command --instance-ids "$INSTANCE" --document-name <AmazonLinuxSourceControlDocumentName output> \
  --parameters Action=Setup
aws ssm send-command --instance-ids "$INSTANCE" --document-name <AmazonLinuxGhCliV2DocumentName output>
aws ssm send-command --instance-ids "$INSTANCE" --document-name <AmazonLinuxAzCliV2DocumentName output>
```

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
  --template-file cloud/dev/cloud-dev-environment.yaml \
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
  --template-file cloud/dev/cloud-dev-server-amazon-linux.yaml \
  --stack-name CloudDev-AmzLinux-1 \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      EnvironmentStackName=CloudDevEnv \
      AllowedCidr=<your.ip>/32 \
      KeyPairName=<your-key-pair> \
      VpcId=<vpc-id> \
      SubnetId=<public-subnet-id>
```

The [workspace disk](#workspace-disk-code-and-caches-that-survive-rebuilds) is
created in the subnet's Availability Zone, which the stack looks up with the
environment stack's `SubnetLookupFunction` (a custom resource).

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
aws cloudformation deploy   --template-file cloud/dev/cloud-dev-permission-set.yaml   --stack-name CloudDevPermissionSet   --parameter-overrides       InstanceArn=<arn:aws:sso:::instance/ssoins-...>       EnvironmentStackName=CloudDevEnv
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

`cloud/dev/cloud-dev-ollama-server.yaml` runs [Ollama](https://ollama.com)
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
aws cloudformation deploy   --template-file cloud/dev/cloud-dev-ollama-server.yaml   --stack-name CloudDevOllama   --parameter-overrides       VpcId=<vpc-id> SubnetId=<subnet-id>       OllamaModel=qwen2.5-coder:14b

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

## Workspace disk: code and caches that survive rebuilds

Each server stack owns two disks:

| Disk | Holds | Lifetime |
| --- | --- | --- |
| Root (`VolumeSize`, default 30 GiB) | The OS and the tools the SSM documents install (`/usr`, `/opt`, `/etc`) | Replaced with the server, then rebuilt by SSM |
| Workspace (`WorkspaceVolumeSize`, default 20 GiB), at `/workspace` | All of `/home/ec2-user`: `~/code`, Git SSH keys, `~/.aws`, `gh`/`az` logins, `~/.gitconfig`, shell history and dotfiles, `~/.vscode-server`; plus the npm / NuGet / pip caches and `packages.txt` | Belongs to the stack; kept when the server is rebuilt. A new stack starts empty |

So an AMI update or rebuild keeps your keys, logins and settings, and only a
new stack needs them set up again.

The stack creates the workspace volume and tags the instance with its ID. The
environment stack's `AmazonLinuxWorkspaceDocument` (run by
`WorkspaceConfigAssociation`) then:

1. attaches the volume. If a replaced server still holds it, it waits (up to 35
   minutes) for CloudFormation to terminate the old one. CloudFormation cannot
   attach it itself, because it creates the new server before deleting the old;
2. formats it **only** if it has no file system, and mounts it at `/workspace`
   (by UUID in `/etc/fstab`, with `nofail`);
3. bind-mounts `/workspace/home` over `/home/ec2-user`. The first time, the
   server's current home is copied in. On a later server it keeps the
   workspace's home, taking only the new server's `~/.ssh/authorized_keys` (so
   a changed `KeyPairName` still works), and re-applies the stack's git name
   and email. Sessions opened in the first minutes, before the move, should
   reconnect;
4. links `~/code` and `~/.vscode-server` into it and sets `npm_config_cache`,
   `NUGET_PACKAGES` and `PIP_CACHE_DIR` in `/etc/profile.d/clouddev-workspace.sh`;
5. installs any missing packages listed in `/workspace/packages.txt`.

It re-runs every 30 minutes; each run is a no-op unless something changed, and
it grows the file system after `WorkspaceVolumeSize` is raised.

**Extra packages:** anything you install by hand with `dnf` is on the root disk
and is lost when the server is replaced. List it in `/workspace/packages.txt`
instead, one per line (`#` for comments). New servers install it, and a package
you add is installed within 30 minutes:

```bash
echo htop >> /workspace/packages.txt
```

What happens to the workspace when you change the stack:

| Change | Server | Workspace |
| --- | --- | --- |
| Instance type, tools, git name/email | Updated in place | Kept |
| AMI update (`LatestAmiId` re-resolves on every update), subnet in the same zone | Replaced | Kept, reattached |
| `ServerEnabled=false`, then `true` (rebuild) | Deleted, then new | Kept |
| `ServerEnabled=false` and leave it (park a project) | Deleted | Kept; you pay only for the disk |
| Larger `WorkspaceVolumeSize` | Unchanged | Grown in place |
| Smaller `WorkspaceVolumeSize` | Unchanged | Kept; EBS cannot shrink, so the update fails and rolls back |
| `SubnetId` in another zone, or `WorkspaceSnapshotId` | — | Replaced in the new zone / from the snapshot; the old one is snapshotted. Change these only while `ServerEnabled=false` |
| Delete the stack | Deleted | Final snapshot, then deleted |

To restore a workspace (into a new stack, or another Availability Zone), pass
the snapshot as `WorkspaceSnapshotId`. For regular backups, set the environment
stack's `EnableWorkspaceSnapshots=true`: Data Lifecycle Manager snapshots every
workspace volume daily at 05:00 UTC and keeps the newest
`WorkspaceSnapshotRetain` (default 7). Snapshots cannot skip folders, so the
caches are backed up too.

**Security:** because the home is on the workspace, Git keys and CLI logins
outlive the server and are in the workspace's snapshots (encrypted). Anyone in
the account who can create a volume from those snapshots can read them. The dev
server role can also attach any unattached volume tagged with its environment
(e.g. a parked project's) to any of the environment's servers, because all
servers share the role. Workspaces are separated by stack, not enforced between
users, so:

- do not keep long-lived AWS access keys in `~/.aws` (the server uses its
  instance role, and you sign in with SSO);
- revoke a project's Git keys in GitHub / Azure DevOps when its stack is
  deleted.

**Existing servers:** updating a server stack from these templates adds a
workspace and copies the server's current home onto it, so nothing in the home
folder is lost. Code in `~/github` comes along; move it into `~/code` if you
like.

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
| `GhCliV2Version` | `2.103.2` | Exact GitHub CLI 2.x release |
| `AzCliV2Version` | `2.91.0` | Exact Azure CLI 2.x release (with the `azure-devops` extension) |
| `DefaultNpmVersion` | `12.2.1` | Exact npm version |
| `HostedZoneId` | *(empty)* | Optional Route 53 zone; registers DNS for each server (see [DNS](#dns-for-dev-servers-optional)) |
| `VpcMode` | `none` | `none` / `public` / `public-private` |
| `AzCount` | `1` | Availability Zones (1–3) when a VPC is created |
| `VpcCidr` | `10.0.0.0/16` | VPC CIDR when a VPC is created |
| `AllowedCidr` | *(required)* | SSH source CIDR for the dev-server security group |
| `EnableWorkspaceSnapshots` | `false` | Daily snapshots of every server's workspace disk |
| `WorkspaceSnapshotRetain` | `7` | Daily workspace snapshots kept per disk |

## Validation

All templates must pass cfn-lint with zero errors and warnings. CI
(`.github/workflows/validate-templates.yml`) lints every template on push and
pull request. To lint locally:

```bash
cfn-lint cloud/dev/**/*.yaml ses/*.yaml redirect/*.yaml static-site/*.yaml
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

## Static website

`static-site/static-site.yaml` hosts a static site from a private S3 bucket
behind CloudFront (origin access control), served at `DomainName` and
`www.DomainName`. It creates the bucket, a DNS-validated ACM certificate, the
distribution, and A/AAAA alias records for both names in your hosted zone.
Directory paths such as `/about/` resolve to `index.html`, and missing pages
return `ErrorDocument` with a 404.

```bash
aws cloudformation deploy \
  --region us-east-1 \
  --template-file static-site/static-site.yaml \
  --stack-name site-example-com \
  --parameter-overrides \
      DomainName=example.com \
      HostedZoneId=<zone-id>

aws s3 sync ./site s3://<BucketName output> --delete
```

The template creates an IAM role, so pass `--capabilities CAPABILITY_IAM` to
`deploy`.

**Caching and invalidation.** Uploads need no metadata. CloudFront caches
objects for `EdgeCacheSeconds` (default 1 day) and sends browsers
`Cache-Control: public, max-age=BrowserCacheSeconds` (default 5 minutes). A
`Cache-Control` set on an object overrides both. Every upload or delete queues
an S3 event; a Lambda reads them in batches (about a minute) and issues a single
`/*` invalidation, so a `sync` of many files costs one invalidation and the
site updates within about a minute or two. Browsers keep what they cached for
up to `BrowserCacheSeconds`.

- **Must be deployed in `us-east-1`**, because CloudFront only accepts ACM
  certificates from there. A template rule enforces this.
- The hosted zone must be in the same account and authoritative for the domain.
- The domain and `www.` must not already have A/AAAA records.
- The bucket is retained (and versioned) if the stack is deleted.
- Incomplete multipart uploads are aborted automatically after 7 days.

| Parameter | Default | Purpose |
|---|---|---|
| `DomainName` | *(required)* | Site domain; `www.` is served too |
| `HostedZoneId` | *(required)* | Route 53 zone for `DomainName` |
| `ErrorDocument` | `404.html` | Object key shown for missing pages |
| `EdgeCacheSeconds` | `86400` | CloudFront cache time for objects without `Cache-Control` |
| `BrowserCacheSeconds` | `300` | Browser `max-age` for objects without `Cache-Control` |
| `BucketNamePrefix` | `static-site-bucket` | Bucket is named `<prefix>-<domain with dots as dashes>-<account ID>` (max 63 characters, so the domain can be about 30 characters). Must match the permission set's `BucketNamePrefix` |

### Permission set for site editors

`static-site/static-site-permission-set.yaml` creates an IAM Identity Center
permission set that lets users upload to the site bucket(s), and nothing else in
S3. Access is scoped by bucket name prefix (`BucketNamePrefix`, default
`static-site-bucket`), which is why the site template names its bucket from the
same prefix. Deploy it in the Identity Center account and assign it to the
account hosting the site stack.

```bash
aws cloudformation deploy \
  --template-file static-site/static-site-permission-set.yaml \
  --stack-name StaticSitePermissionSet \
  --parameter-overrides InstanceArn=<arn:aws:sso:::instance/ssoins-...>
```

It allows list, get, put and delete on objects (enough for
`aws s3 sync --delete`) and invoking the site's invalidation function for a
manual flush (`aws lambda invoke --function-name
static-site-bucket-invalidate-example-com out.json`), with no direct CloudFront
access. The bucket is versioned
and the permission set cannot delete object versions, so deletes only add
delete markers. Changing `BucketNamePrefix` on an existing site stack replaces
the bucket (the old one is retained).

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
