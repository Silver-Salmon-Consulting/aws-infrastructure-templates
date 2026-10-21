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
```

### Architecture

- **Environment stack** (`cloud-dev-environment.yaml`) — the shared foundation,
  deployed once. It creates:
  - an IAM role + instance profile with `AmazonSSMManagedInstanceCore` (so SSM
    Session Manager, Run Command, and Patch Manager can manage the instances),
    plus scoped inline policies that let the instances signal CloudFormation and
    write bootstrap logs;
  - a CloudWatch Logs group for instance bootstrap output;
  - eight SSM Command Documents — one installs Node.js/npm via nvm, one
    installs PowerShell (per-architecture tarball, works on x86_64 and arm64),
    one installs the system libraries/fonts Playwright's Chromium needs, one
    installs a .NET SDK channel (`DotNetChannel` parameter), one installs
    jq/zip/unzip, and three are per-major-version tool documents (k6 0.x,
    k6 1.x, AWS CLI 2.x — see [Versioned tool documents](#versioned-tool-documents));
  - nine **tag-targeted** SSM State Manager associations that apply those
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
   - `PowerShellConfigAssociation` targets `tag:CloudDevPowerShellConfig = enabled`
   - `PlaywrightConfigAssociation` targets `tag:CloudDevPlaywrightConfig = enabled`
   - `DotNet8ConfigAssociation` targets `tag:CloudDevDotNet8Config = enabled`
     (passes `DotNetChannel=8.0`)
   - `DotNet10ConfigAssociation` targets `tag:CloudDevDotNet10Config = enabled`
     (passes `DotNetChannel=10.0`)
   - `BaseToolsConfigAssociation` targets `tag:CloudDevBaseToolsConfig = enabled`
   - `K6V0ConfigAssociation` / `K6V1ConfigAssociation` target
     `tag:CloudDevK6Config = v0` / `v1`
   - `AwsCliV2ConfigAssociation` targets `tag:CloudDevAwsCliConfig = v2`
3. Each server tags its instance to opt in:
   - `CloudDevNodeConfig = enabled` (always — every dev server gets Node)
   - `CloudDevPowerShellConfig = enabled` when `EnablePowerShell=true`, else
     `disabled` (any value other than `enabled` simply does not match)
   - `CloudDevPlaywrightConfig = enabled` when `EnablePlaywright=true`
     (default `false`), else `disabled`
   - `CloudDevDotNet8Config` / `CloudDevDotNet10Config = enabled` when
     `EnableDotNet8` / `EnableDotNet10=true` (both default `false`)
   - `CloudDevBaseToolsConfig = enabled` (always — jq, zip and unzip)
   - `CloudDevK6Config = <K6MajorVersion>` (`none` / `v0` / `v1`, default `none`)
   - `CloudDevAwsCliConfig = <AwsCliMajorVersion>` (`none` / `v2`, default `none`)

The .NET SDKs install side by side into `/opt/dotnet` (via Microsoft's
`dotnet-install.sh`, x64 or arm64 automatically), with `/usr/bin/dotnet`
symlinked and `DOTNET_ROOT` set in `/etc/profile.d/dotnet.sh`. Pin a project to
a specific SDK with `global.json`; `dotnet --list-sdks` shows what is installed.

The Playwright document installs only OS dependencies (the dnf equivalent of
`npx playwright install-deps`, which supports apt only) plus Xvfb. Browser
binaries are versioned per project, so run `npx playwright install chromium` in
the project. Chromium is the supported engine on Amazon Linux; Playwright's
WebKit and Firefox builds target Ubuntu.

### Versioned tool documents

Tools whose version matters to a project (k6, the AWS CLI) follow one pattern:
**one SSM document per tool per major version**, for example
`AmazonLinuxK6V0Document` and `AmazonLinuxK6V1Document`.

- The document fixes the major version. Its version parameter (`K6Version`,
  `AwsCliVersion`) defaults to `latest`, the newest release **within that
  major**, and also accepts an exact version (`0.55.0`), checked against the
  major by `allowedPattern`.
- Each major has its own association. All majors of a tool share one tag key
  and differ by tag **value**, so a server selects exactly one major
  (`CloudDevK6Config = v0`), and `none` selects nothing. Server stacks expose
  this as `K6MajorVersion` / `AwsCliMajorVersion`.
- To add a major, copy the document and association, change the major number,
  and add the value to the server stacks' `AllowedValues`.
- Re-applying an association upgrades to the newest release in that major.
  Changing a server's tag value and re-applying switches majors.

To pin an exact version on one server, run the document with Run Command:

```bash
aws ssm send-command --instance-ids <instance-id>   --document-name <AmazonLinuxK6V0DocumentName output>   --parameters K6Version=0.55.0
```

The AWS CLI document installs AWS's official v2 build at `/usr/local/bin/aws`,
which comes first on PATH. It leaves the AL2023 `awscli-2` RPM
(`/usr/bin/aws`) in place, because UserData uses it to signal CloudFormation.
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

Node and PowerShell versions are set **once, on the environment stack**, and
flow into the SSM documents' parameter defaults:

- `DefaultNodeVersion` (default `24`) — Node.js major version (22 / 24 / 26)
- `DefaultPowerShellVersion` (default `7.6.6`) — PowerShell version

Server stacks do not take a Node/PowerShell version. Changing the fleet version
means updating the environment stack and re-applying the association on existing
servers (new servers pick it up automatically).

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

## Connecting

Connect via **Session Manager** — no SSH key or open port required, and it uses
the attached SSM role:

```bash
aws ssm start-session --target <instance-id> --region <region>
```

The server stack's `SessionManagerCommand` output gives you this line directly.

> Why not SSH / a public-IP output? The public IP is **ephemeral** — it changes
> on every stop/start, which the idle auto-stop safeguard (below) triggers. SSH
> still works from `AllowedCidr` if you fetch the current IP from the console,
> but it is intentionally not a stack output. The default login user for Amazon
> Linux is `ec2-user`.

## Idle auto-stop safeguard

Each server creates a CloudWatch alarm that **stops** (not terminates) the
instance when it is idle, as a cost guard against a forgotten-running box:

- `EnableIdleShutdown` (default `true`)
- `IdleCpuThresholdPercent` (default `5`) — CPU % below which it is "idle"
- `IdleStopPeriods` (default `12`) — consecutive 5-minute periods below the
  threshold before stopping (12 × 5 min = 60 minutes)

The alarm uses a 300-second period to match EC2 basic monitoring's 5-minute
`CPUUtilization` resolution. The instance stops (EBS persists; restart it later).
A truly idle box you are connected to will still stop after the window — raise
`IdleStopPeriods` or set `EnableIdleShutdown=false` if that is a problem.

## Environment stack parameters (summary)

| Parameter | Default | Purpose |
|---|---|---|
| `StackNamePrefix` | `CloudDev` | Scopes which stacks the shared role may signal |
| `LogRetentionDays` | `7` | Bootstrap log retention |
| `DefaultNodeVersion` | `24` | Fleet-wide Node.js version |
| `DefaultPowerShellVersion` | `7.6.6` | Fleet-wide PowerShell version |
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

## Roadmap / parked ideas

- **Ubuntu dev server** — a sibling of the Amazon Linux server templates (apt,
  the `ubuntu` login user) with its own SSM documents.
- **Versioned, pinnable SSM documents** — version-named documents
  (`DeletionPolicy: Retain`) with one tag-targeted association per version, so a
  server can pin to a specific config version via its tag value while the fleet
  default tracks the latest.
