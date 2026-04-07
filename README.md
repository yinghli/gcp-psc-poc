# GCP Private Service Connect (PSC) PoC

This project provides a set of scripts to build a Proof of Concept (PoC) for Google Cloud Private Service Connect (PSC). It demonstrates how to expose a service in a Producer VPC to a Consumer VPC via PSC, and how to access that service from a simulated On-Premises environment connected to the Consumer VPC via an IPsec HA VPN.

## Architecture

The script deploys the following environment in the `asia-southeast1` region:

1.  **Producer VPC (`100.64.48.0/22`)**:
    *   Subnet: `100.64.48.0/24` for the backend VM.
    *   Subnet: `100.64.50.0/24` for PSC NAT (purpose: `PRIVATE_SERVICE_CONNECT`).
    *   An Nginx VM (private IP only) behind an Internal Passthrough Network Load Balancer.
    *   A PSC Service Attachment exposing the load balancer.
    *   A Cloud NAT to allow the private VM to install Nginx.

2.  **Consumer VPC (`100.64.52.0/22`)**:
    *   Subnet: `100.64.52.0/24` for endpoints and VPN.
    *   A PSC Endpoint (Forwarding Rule) with IP `100.64.52.100` pointing to the Producer's Service Attachment.
    *   An HA VPN Gateway.
    *   A Cloud Router configured to advertise the PSC endpoint subnet (`100.64.52.0/24`) over the VPN.

3.  **On-Premise VPC (`100.64.56.0/22`)**:
    *   Subnet: `100.64.56.0/24` for the client VM.
    *   A Client VM to simulate an on-premise host.
    *   An HA VPN Gateway connected to the Consumer VPC.
    *   A Cloud Router to receive advertised routes.

4.  **Connectivity**:
    *   HA VPN connection between Consumer VPC and On-Premise VPC with BGP routing.

## Prerequisites

*   Google Cloud SDK (`gcloud`) installed and configured.
*   An active Google Cloud project.
*   Sufficient permissions to create VPCs, subnets, VMs, Load Balancers, and VPNs.
*   Firewall rules allowing IAP for SSH (handled by script for default ranges, but ensure your project allows IAP).

## Usage

### Setup

To deploy the entire PoC environment, run:

```bash
chmod +x setup_psc_poc.sh
./setup_psc_poc.sh
```

The script will automatically use your current active `gcloud` project and configuration.

### Validation

After the script completes (wait 2-3 minutes for BGP to converge and Nginx to install):

1.  SSH into the simulated On-Premise client VM:
    ```bash
    gcloud compute ssh onprem-client --zone=asia-southeast1-a --tunnel-through-iap
    ```

2.  From the client VM, test connectivity to the PSC Endpoint in the Consumer VPC:
    ```bash
    curl 100.64.52.100
    ```

    If successful, you should see the response: `Hello from the Producer! You have successfully reached the PSC Endpoint.`

### Teardown

To clean up all resources created by this PoC and avoid ongoing charges:

```bash
chmod +x teardown_psc_poc.sh
./teardown_psc_poc.sh
```

## Important Notes

*   This script uses the `asia-southeast1` region and `asia-southeast1-a` zone by default. You can modify the variables at the top of the scripts to change this.
*   The IP ranges used are `100.64.48.0/22`, `100.64.52.0/22`, and `100.64.56.0/22`. Ensure these do not conflict with existing networks if you are running this in a shared project.
*   Resources created by this script incur costs. Remember to run the teardown script when you are done.
