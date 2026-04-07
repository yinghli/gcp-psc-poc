#!/bin/bash
set -e

REGION="asia-southeast1"
ZONE="${REGION}-a"
PROJECT_ID=$(gcloud config get-value core/project)

echo "================================================================"
echo "Starting PSC PoC Teardown in Project: $PROJECT_ID, Region: $REGION"
echo "================================================================"

echo "=== Deleting VPN Tunnels and Gateways ==="
# Delete VPN Tunnels first because Gateways depend on them
gcloud compute vpn-tunnels delete tunnel-consumer-to-onprem-0 tunnel-consumer-to-onprem-1 --region=$REGION --quiet || true
gcloud compute vpn-tunnels delete tunnel-onprem-to-consumer-0 tunnel-onprem-to-consumer-1 --region=$REGION --quiet || true

# Delete HA VPN Gateways
gcloud compute vpn-gateways delete consumer-vpn-gw onprem-vpn-gw --region=$REGION --quiet || true

echo "=== Deleting PSC Endpoints & Service Attachments ==="
# Forwarding Rule (PSC Endpoint in consumer)
gcloud compute forwarding-rules delete consumer-psc-endpoint --region=$REGION --quiet || true
# Reserved IP Address
gcloud compute addresses delete consumer-psc-ip --region=$REGION --quiet || true

# Service Attachment in Producer
gcloud compute service-attachments delete producer-svc-attachment --region=$REGION --quiet || true

echo "=== Deleting Producer Load Balancer Components ==="
# Forwarding Rule (ILB)
gcloud compute forwarding-rules delete producer-ilb-fr --region=$REGION --quiet || true
# Backend Service
gcloud compute backend-services delete producer-backend --region=$REGION --quiet || true
# Regional Health Check
gcloud compute health-checks delete producer-hc --region=$REGION --quiet || true

echo "=== Deleting Instances and Instance Groups ==="
# Remove instance from the unmanaged group, then delete the group
gcloud compute instance-groups unmanaged remove-instances producer-mig \
    --zone=$ZONE \
    --instances=producer-nginx --quiet || true
gcloud compute instance-groups unmanaged delete producer-mig --zone=$ZONE --quiet || true

# Delete the VMs
gcloud compute instances delete producer-nginx onprem-client --zone=$ZONE --quiet || true

echo "=== Deleting Cloud NAT & Routers ==="
# Cloud NAT must be deleted before its Cloud Router
gcloud compute routers nats delete producer-nat-gw \
    --router=producer-nat-router \
    --region=$REGION --quiet || true

# Delete all Routers (This also wipes BGP interfaces/peers)
gcloud compute routers delete producer-nat-router consumer-router onprem-router --region=$REGION --quiet || true

echo "=== Deleting Firewall Rules ==="
gcloud compute firewall-rules delete producer-allow-hc producer-allow-iap-ssh producer-allow-psc onprem-allow-iap-ssh consumer-allow-onprem --quiet || true

echo "=== Deleting Subnets ==="
# Subnets must be deleted before the VPC can be deleted
gcloud compute networks subnets delete producer-subnet producer-psc-nat consumer-subnet onprem-subnet --region=$REGION --quiet || true

echo "=== Deleting VPC Networks ==="
# Finally, delete the bare custom VPCs
gcloud compute networks delete producer-vpc consumer-vpc onprem-vpc --quiet || true

echo "================================================================"
echo "Teardown Complete!"
echo "All PoC resources have been successfully removed."
echo "================================================================"
