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
- Security group (SSH and dashboard port 8080 open by default; restrict to your IP via `DashboardAccessCidr`)
- IAM instance profile with SSM Session Manager access (no bastion host needed)


## Parameters

| Parameter | Default | Description |
|---|---|---|
| `ResourcePrefix` | `ps-heroku-migration` | Prefix for all AWS resource names |
| `VpcId` | — | VPC ID where the instance will run |
| `SubnetId` | — | Subnet with outbound internet access |
| `DashboardAccessCidr` | `0.0.0.0/0` | CIDR for dashboard access on port 8080. Open to all by default (dashboard is password-protected). Restrict to your IP (e.g. `1.2.3.4/32`) for tighter security. |
| `InstanceType` | `m7i-flex.2xlarge` | EC2 instance type |
| `VolumeSize` | `100` | EBS volume in GB |
| `KeyPairName` | *(empty)* | Optional SSH key pair |

### Choosing an Instance Type

| Database Size | Recommended Type |
|---|---|
| Under 50 GB | `m7i.xlarge` |
| 50–200 GB | `m7i.2xlarge` |
| 200–500 GB | `m7i.4xlarge` |
| Over 500 GB | `m7i.8xlarge` |

Bucardo runs a PostgreSQL instance inside the container to manage replication state, so RAM
matters. Watch `docker compose logs -f` for OOM signals and resize if needed.

## How to Deploy

### Prerequisites

- VPC with a subnet that has outbound internet access (NAT Gateway or Internet Gateway)
- The source Heroku database must be reachable from that subnet

### Steps

1. **Upload** `heroku-migrator-ec2.yaml` to CloudFormation (Console → Create Stack → Upload template)
2. **Fill in** VPC ID, Subnet ID, and instance type. `DashboardAccessCidr` defaults to `0.0.0.0/0` — set it to your IP (`x.x.x.x/32`) if you want to restrict dashboard access.
3. **Deploy** and wait for completion (~5 minutes). The Docker image build (~15–20 min) runs in the background after CloudFormation marks the stack complete. The migrator dashboard won't be available until the build finishes.
4. **Connect** to the instance via SSM Session Manager (no key needed):
   ```bash
   aws ssm start-session --target INSTANCE_ID
   ```
   Or open the instance in the EC2 console and click **Connect → Session Manager**.

5. **Set your credentials:**
   ```bash
   sudo vim /opt/heroku-migrator/.env
   ```
   Fill in `HEROKU_URL`, `PLANETSCALE_URL`, and `PASSWORD`, then save.

6. **Start the migrator:**
   ```bash
   sudo systemctl restart heroku-migrator
   ```

7. **Access the dashboard** — open `http://PUBLIC_IP:8080` in your browser (find the public IP in the EC2 console or the stack Outputs). Log in with username `admin` and the `PASSWORD` you set in `.env`.

8. **Click Start Migration** and follow the dashboard.

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

## Dashboard Access

Port 8080 is open by default. Go to `http://PUBLIC_IP:8080` — no tunnel needed.

To restrict access to your IP only, set `DashboardAccessCidr` to `YOUR_IP/32` when deploying, or update the security group inbound rule directly in the EC2 console after deployment.

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
