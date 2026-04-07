#!/bin/bash
set -e

REGION="asia-southeast1"
ZONE="${REGION}-a"
PROJECT_ID=$(gcloud config get-value core/project)

echo "================================================================"
echo "Starting PSC PoC Deployment in Project: $PROJECT_ID, Region: $REGION"
echo "================================================================"

# ====================================================================
# 1. Producer VPC Setup
# ====================================================================
echo "=== Setting up Producer Environment ==="
# Custom mode VPC
gcloud compute networks create producer-vpc --subnet-mode=custom || true

# Subnet for Nginx VM
gcloud compute networks subnets create producer-subnet \
    --network=producer-vpc \
    --region=$REGION \
    --range=100.64.48.0/24 \
    --enable-private-ip-google-access || true

# Subnet for PSC NAT (must be PRIVATE_SERVICE_CONNECT purpose)
gcloud compute networks subnets create producer-psc-nat \
    --network=producer-vpc \
    --region=$REGION \
    --range=100.64.50.0/24 \
    --purpose=PRIVATE_SERVICE_CONNECT || true

# Firewall: Allow health checks
gcloud compute firewall-rules create producer-allow-hc \
    --network=producer-vpc \
    --action=allow \
    --direction=ingress \
    --source-ranges=130.211.0.0/22,35.191.0.0/16 \
    --rules=tcp:80 || true

# Firewall: Allow IAP for SSH
gcloud compute firewall-rules create producer-allow-iap-ssh \
    --network=producer-vpc \
    --action=allow \
    --direction=ingress \
    --source-ranges=35.235.240.0/20 \
    --rules=tcp:22 || true

# Firewall: Allow PSC translated traffic
gcloud compute firewall-rules create producer-allow-psc \
    --network=producer-vpc \
    --action=allow \
    --direction=ingress \
    --source-ranges=100.64.50.0/24 \
    --rules=tcp:80 || true

# Cloud NAT for Producer (so the private VM can download Nginx)
gcloud compute routers create producer-nat-router \
    --network=producer-vpc \
    --region=$REGION || true
gcloud compute routers nats create producer-nat-gw \
    --router=producer-nat-router \
    --region=$REGION \
    --auto-allocate-nat-external-ips \
    --nat-all-subnet-ip-ranges || true

# Nginx VM startup script
cat << 'EOF' > startup.sh
#!/bin/bash
apt-get update
apt-get install -y nginx
systemctl start nginx
echo "Hello from the Producer! You have successfully reached the PSC Endpoint." > /var/www/html/index.html
EOF

# Create the VM instance without a public IP
gcloud compute instances create producer-nginx \
    --zone=$ZONE \
    --machine-type=e2-micro \
    --network=producer-vpc \
    --subnet=producer-subnet \
    --metadata-from-file=startup-script=startup.sh \
    --tags=nginx \
    --no-address || true

# Instance Group
gcloud compute instance-groups unmanaged create producer-mig \
    --zone=$ZONE || true
gcloud compute instance-groups unmanaged add-instances producer-mig \
    --zone=$ZONE \
    --instances=producer-nginx || true

# Internal Load Balancer
gcloud compute health-checks create tcp producer-hc \
    --region=$REGION \
    --port=80 || true

gcloud compute backend-services create producer-backend \
    --load-balancing-scheme=INTERNAL \
    --protocol=TCP \
    --region=$REGION \
    --health-checks=producer-hc \
    --health-checks-region=$REGION || true

gcloud compute backend-services add-backend producer-backend \
    --region=$REGION \
    --instance-group=producer-mig \
    --instance-group-zone=$ZONE || true

gcloud compute forwarding-rules create producer-ilb-fr \
    --region=$REGION \
    --network=producer-vpc \
    --subnet=producer-subnet \
    --load-balancing-scheme=INTERNAL \
    --ip-protocol=TCP \
    --ports=80 \
    --backend-service=producer-backend || true

# PSC Service Attachment
gcloud compute service-attachments create producer-svc-attachment \
    --region=$REGION \
    --producer-forwarding-rule=producer-ilb-fr \
    --connection-preference=ACCEPT_AUTOMATIC \
    --nat-subnets=producer-psc-nat || true

# ====================================================================
# 2. Consumer VPC Setup
# ====================================================================
echo "=== Setting up Consumer Environment ==="
gcloud compute networks create consumer-vpc --subnet-mode=custom || true

gcloud compute networks subnets create consumer-subnet \
    --network=consumer-vpc \
    --region=$REGION \
    --range=100.64.52.0/24 \
    --enable-private-ip-google-access || true

# Reserve PSC Endpoint IP
gcloud compute addresses create consumer-psc-ip \
    --region=$REGION \
    --subnet=consumer-subnet \
    --addresses=100.64.52.100 || true

# Get Service Attachment URI to link Endpoint
SVC_ATTACHMENT_URI=$(gcloud compute service-attachments describe producer-svc-attachment --region=$REGION --format="value(selfLink)")

# Create PSC Endpoint
gcloud compute forwarding-rules create consumer-psc-endpoint \
    --region=$REGION \
    --network=consumer-vpc \
    --address=consumer-psc-ip \
    --target-service-attachment=$SVC_ATTACHMENT_URI || true

# ====================================================================
# 3. On-Premise VPC Setup
# ====================================================================
echo "=== Setting up On-Premise Environment ==="
gcloud compute networks create onprem-vpc --subnet-mode=custom || true

gcloud compute networks subnets create onprem-subnet \
    --network=onprem-vpc \
    --region=$REGION \
    --range=100.64.56.0/24 \
    --enable-private-ip-google-access || true

# Firewall: Allow IAP for SSH
gcloud compute firewall-rules create onprem-allow-iap-ssh \
    --network=onprem-vpc \
    --action=allow \
    --direction=ingress \
    --source-ranges=35.235.240.0/20 \
    --rules=tcp:22 || true

# Allow on-prem -> consumer traffic over VPN (and ICMP)
gcloud compute firewall-rules create consumer-allow-onprem \
    --network=consumer-vpc \
    --action=allow \
    --direction=ingress \
    --source-ranges=100.64.56.0/24 \
    --rules=tcp:80,icmp || true

# Client VM
gcloud compute instances create onprem-client \
    --zone=$ZONE \
    --machine-type=e2-micro \
    --network=onprem-vpc \
    --subnet=onprem-subnet \
    --no-address || true

# ====================================================================
# 4. VPN Setup (Consumer <-> On-Premise)
# ====================================================================
echo "=== Setting up VPN Tunnels ==="
# Cloud HA VPN Gateways
gcloud compute vpn-gateways create consumer-vpn-gw \
    --network=consumer-vpc \
    --region=$REGION || true
gcloud compute vpn-gateways create onprem-vpn-gw \
    --network=onprem-vpc \
    --region=$REGION || true

# Cloud Routers
# NOTE: Advertising the subnet so that BGP sends the route for the PSC endpoint across the VPN
gcloud compute routers create consumer-router \
    --network=consumer-vpc \
    --region=$REGION \
    --asn=65001 \
    --advertisement-mode=CUSTOM \
    --set-advertisement-ranges=100.64.52.0/24 || true

gcloud compute routers create onprem-router \
    --network=onprem-vpc \
    --region=$REGION \
    --asn=65002 || true

SHARED_SECRET="SuperSecretVPNKey123!"

# Tunnels Consumer -> Onprem
gcloud compute vpn-tunnels create tunnel-consumer-to-onprem-0 \
    --peer-gcp-gateway=onprem-vpn-gw \
    --region=$REGION \
    --ike-version=2 \
    --shared-secret=$SHARED_SECRET \
    --router=consumer-router \
    --vpn-gateway=consumer-vpn-gw \
    --interface=0 || true

gcloud compute vpn-tunnels create tunnel-consumer-to-onprem-1 \
    --peer-gcp-gateway=onprem-vpn-gw \
    --region=$REGION \
    --ike-version=2 \
    --shared-secret=$SHARED_SECRET \
    --router=consumer-router \
    --vpn-gateway=consumer-vpn-gw \
    --interface=1 || true

# Tunnels Onprem -> Consumer
gcloud compute vpn-tunnels create tunnel-onprem-to-consumer-0 \
    --peer-gcp-gateway=consumer-vpn-gw \
    --region=$REGION \
    --ike-version=2 \
    --shared-secret=$SHARED_SECRET \
    --router=onprem-router \
    --vpn-gateway=onprem-vpn-gw \
    --interface=0 || true

gcloud compute vpn-tunnels create tunnel-onprem-to-consumer-1 \
    --peer-gcp-gateway=consumer-vpn-gw \
    --region=$REGION \
    --ike-version=2 \
    --shared-secret=$SHARED_SECRET \
    --router=onprem-router \
    --vpn-gateway=onprem-vpn-gw \
    --interface=1 || true

# Consumer Router BGP Interfaces and Peers
gcloud compute routers add-interface consumer-router \
    --interface-name=if-tunnel-0-to-onprem \
    --ip-address=169.254.0.1 \
    --mask-length=30 \
    --vpn-tunnel=tunnel-consumer-to-onprem-0 \
    --region=$REGION || true
gcloud compute routers add-bgp-peer consumer-router \
    --peer-name=bgp-onprem-0 \
    --interface=if-tunnel-0-to-onprem \
    --peer-ip-address=169.254.0.2 \
    --peer-asn=65002 \
    --region=$REGION || true

gcloud compute routers add-interface consumer-router \
    --interface-name=if-tunnel-1-to-onprem \
    --ip-address=169.254.1.1 \
    --mask-length=30 \
    --vpn-tunnel=tunnel-consumer-to-onprem-1 \
    --region=$REGION || true
gcloud compute routers add-bgp-peer consumer-router \
    --peer-name=bgp-onprem-1 \
    --interface=if-tunnel-1-to-onprem \
    --peer-ip-address=169.254.1.2 \
    --peer-asn=65002 \
    --region=$REGION || true

# Onprem Router BGP Interfaces and Peers
gcloud compute routers add-interface onprem-router \
    --interface-name=if-tunnel-0-to-consumer \
    --ip-address=169.254.0.2 \
    --mask-length=30 \
    --vpn-tunnel=tunnel-onprem-to-consumer-0 \
    --region=$REGION || true
gcloud compute routers add-bgp-peer onprem-router \
    --peer-name=bgp-consumer-0 \
    --interface=if-tunnel-0-to-consumer \
    --peer-ip-address=169.254.0.1 \
    --peer-asn=65001 \
    --region=$REGION || true

gcloud compute routers add-interface onprem-router \
    --interface-name=if-tunnel-1-to-consumer \
    --ip-address=169.254.1.2 \
    --mask-length=30 \
    --vpn-tunnel=tunnel-onprem-to-consumer-1 \
    --region=$REGION || true
gcloud compute routers add-bgp-peer onprem-router \
    --peer-name=bgp-consumer-1 \
    --interface=if-tunnel-1-to-consumer \
    --peer-ip-address=169.254.1.1 \
    --peer-asn=65001 \
    --region=$REGION || true

# Cleanup temp script
rm -f startup.sh || true

echo "================================================================"
echo "Deployment Complete!"
echo "Please wait 2-3 minutes for BGP routing to fully converge and"
echo "for the Nginx setup script to complete on the Producer VM."
echo "================================================================"
echo "To test your connectivity, run the following commands:"
echo ""
echo "1. Connect to the On-Prem Client VM:"
echo "   gcloud compute ssh onprem-client --zone=$ZONE --tunnel-through-iap"
echo ""
echo "2. Once connected, access the Nginx VM via the PSC Endpoint IP:"
echo "   curl 100.64.52.100"
echo "================================================================"
