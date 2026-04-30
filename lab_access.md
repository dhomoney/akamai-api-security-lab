# Lab Access Guide

All traffic should flow through the gateway URLs below — not directly to the apps — so Noname sees it through its configured integrations.

## Via Kong

**ALB**: `homoney-akamai-lab-kong-alb-734047586.us-east-2.elb.amazonaws.com`

| App | URL | Notes |
|---|---|---|
| crAPI | `http://homoney-akamai-lab-kong-alb-734047586.us-east-2.elb.amazonaws.com/crapi/` | Full web UI + REST API |
| Pixi | `http://homoney-akamai-lab-kong-alb-734047586.us-east-2.elb.amazonaws.com/pixi/` | REST API only — use Postman or curl |
| Kong Admin | `http://homoney-akamai-lab-kong-alb-734047586.us-east-2.elb.amazonaws.com:8001/` | List routes, services, plugins |

## Via NGINX

**ALB**: `homoney-akamai-lab-nginx-alb-1669909971.us-east-2.elb.amazonaws.com`

| App | URL | Notes |
|---|---|---|
| VAmPI | `http://homoney-akamai-lab-nginx-alb-1669909971.us-east-2.elb.amazonaws.com/vampi/` | REST API — use Postman or curl |
| DVGA  | `http://homoney-akamai-lab-nginx-alb-1669909971.us-east-2.elb.amazonaws.com/dvga/`  | GraphQL — endpoint at `/dvga/graphql` |

## Via MuleSoft

vAPI — wired up once MuleSoft is resolved.

## crAPI Email Verification (MailHog)

crAPI sends registration and verification emails to MailHog, which has no public endpoint. Access it via SSH tunnel through the bastion:

```bash
ssh -i keys/lab_key \
  -o ProxyJump=ec2-user@<bastion-public-ip> \
  -L 8025:localhost:8025 \
  ec2-user@<apps-host-private-ip>
```

Then open `http://localhost:8025` in your browser.

Get the current IPs from Terraform:

```bash
# Bastion public IP
terraform -chdir=terraform output bastion_public_ip

# Apps host private IP
terraform -chdir=terraform output apps_alb_dns
```
