# Heroku Migrator — EC2 CloudFormation Template

## What This Does

This CloudFormation template creates an EC2 instance pre-configured to run
[heroku-migrator](https://github.com/planetscale/heroku-migrator) on AWS instead of Heroku.
It installs Docker, builds the heroku-migrator image from source, and manages it with
docker-compose and systemd.

**Use this instead of deploying to Heroku when:**
- Your database is large enough that Heroku's 24-hour dyno restart could interrupt the initial
  data copy (rough guideline: >~1 TB, or a database that takes more than 18 hours to copy)
- You want more control over the runtime environment, memory, and restart behavior

## What Gets Created

- EC2 instance (Ubuntu 24.04) with Docker and heroku-migrator running under systemd
- EBS gp3 volume for Docker image and Bucardo working data
- Security group: SSH (port 22) open, dashboard port 8080 **not exposed** (localhost-only)
- IAM instance profile with SSM Session Manager access

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `ResourcePrefix` | `ps-heroku-migration` | Prefix for all AWS resource names |
| `VpcId` | — | VPC ID where the instance will run |
| `SubnetId` | — | Subnet with outbound internet access |
| `InstanceType` | `m7i.2xlarge` | EC2 instance type |
| `VolumeSize` | `100` | EBS volume in GB (gp3, 50–1000). Needs to hold the Docker image (~2 GB) and Bucardo working data. |
| `KeyPairName` | *(empty)* | Optional SSH key pair |
| `YourPublicIP` | *(empty)* | Your IPv4 to restrict SSH. Get it with `curl -4 icanhazip.com`. Leave empty to allow SSH from anywhere. |

### Choosing an Instance Type

| Database Size | Recommended Type |
|---|---|
| Under 50 GB | `m7i.xlarge` |
| 50–200 GB | `m7i.2xlarge` |
| 200–500 GB | `m7i.4xlarge` |
| Over 500 GB | `m7i.8xlarge` |

Bucardo runs a PostgreSQL instance inside the container, so RAM matters. Watch
`docker compose logs -f` for OOM signals and resize if needed.

## How to Deploy

### Prerequisites

- VPC with a subnet that has outbound internet access (NAT Gateway or Internet Gateway)
- The source Heroku database must be reachable from that subnet

### Steps

1. **Upload** `heroku-migrator-ec2.yaml` to CloudFormation (Console → Create Stack → Upload template)
2. **Fill in** VPC ID, Subnet ID, and instance type. Optionally set `YourPublicIP` to restrict SSH.
3. **Deploy** and wait for completion (~5 minutes). The Docker image build (~15–20 min) runs in
   the background — the dashboard won't be available until the build finishes.
4. **Connect** to the instance via SSM Session Manager (no key needed):
   ```bash
   aws ssm start-session --target INSTANCE_ID
   ```
   Or open the EC2 console → select instance → **Connect → Session Manager**.
5. **Set your credentials** on the instance:
   ```bash
   sudo vim /opt/heroku-migrator/.env
   ```
   Fill in `HEROKU_URL`, `PLANETSCALE_URL`, and `PASSWORD`, then save.
6. **Start the migrator:**
   ```bash
   sudo systemctl restart heroku-migrator
   ```
7. **Open an encrypted tunnel to the dashboard** (see below) and go to `http://localhost:8080`.
8. **Click Start Migration** and follow the dashboard.

## Accessing the Dashboard

The dashboard runs on port 8080 but is **bound to localhost only** on the instance — it is not
reachable from the internet. Access it through an encrypted tunnel so credentials and migration
data are never transmitted in plaintext.

### Option A — SSH tunnel (recommended if you have a key pair)

```bash
ssh -i /path/to/key.pem -L 8080:localhost:8080 -N ubuntu@PUBLIC_IP
```

Keep this running in a terminal, then open **http://localhost:8080** in your browser.

### Option B — SSM port forwarding (no key pair needed)

```bash
aws ssm start-session \
  --target INSTANCE_ID \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
```

Keep this running in a terminal, then open **http://localhost:8080** in your browser.

Both options require the tunnel to stay open while you use the dashboard. The `INSTANCE_ID`
and the SSH tunnel command are available in the stack **Outputs** tab after deployment.

## Useful Commands (on the instance)

```bash
# Monitor the Docker image build (runs in background after stack creation, ~15-20 min)
journalctl -u heroku-migrator -f

# View live container logs (once the build is done and the container is running)
cd /opt/heroku-migrator && docker compose logs -f

# Check service status
systemctl status heroku-migrator

# Restart after editing .env
sudo systemctl restart heroku-migrator

# Stop the migrator
sudo systemctl stop heroku-migrator

# Check which containers are running
docker ps
```

## Tearing Down

Delete the CloudFormation stack to remove the instance and all associated resources:

```bash
aws cloudformation delete-stack --stack-name YOUR_STACK_NAME
```

The EBS volume is set to `DeleteOnTermination: true`, so it is also removed when the stack
is deleted.

## Questions?

See [PlanetScale documentation](https://planetscale.com/docs) or
[reach out for migration assistance](https://planetscale.com/contact).
