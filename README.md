# EC Observability Hub (Modernized with OpenTelemetry & SNMP)

This project provides a professional-grade observability stack (Prometheus, Loki, Tempo, OpenTelemetry, Grafana, Icinga2, K6) optimized for enterprise environments like the European Commission.

## Architecture Overview

```mermaid
graph LR
    subgraph "External Access"
        User((User/Browser))
        SNMP_Dev[Network Devices]
    end

    subgraph "Local Kubernetes Cluster (Colima/k3s)"
        direction TB
        
        subgraph "Production Namespace"
            direction LR
            App[Podinfo App]
        end

        subgraph "Monitoring Namespace"
            direction TB
            subgraph "LGTM + OTel Stack"
                OTel[OTel Collector]
                Prom[Prometheus]
                Loki[Loki]
                Tempo[Tempo]
                Telegraf[Telegraf SNMP]
            end
            Graf[Grafana]
            Icinga[Icinga2]
            
            OTel --> Prom
            OTel --> Loki
            OTel --> Tempo
            Telegraf -->|SNMP Traps| OTel
            Prom --> Graf
            Loki --> Graf
            Tempo --> Graf
        end
    end

    %% Flows
    User -->|Port Forward: 3000| Graf
    SNMP_Dev -->|UDP:162| Telegraf
    
    App -->|OTLP Traces/Metrics| OTel
    
    Icinga -.->|External Check| App

    %% Styles
    style App fill:#f9f,stroke:#333,stroke-width:2px
    style OTel fill:#f80,stroke:#333,stroke-width:2px
    style Telegraf fill:#0cf,stroke:#333,stroke-width:2px
    style Graf fill:#3c7,stroke:#333,stroke-width:2px
```

## Features

- **Multi-Platform Support:** Automatically detects OS (**macOS / Linux**) and Architecture (**ARM64 / Intel**) for optimized cluster provisioning via Colima.
- **Vendor-Neutral Observability:** Built on **OpenTelemetry (OTel)**, allowing seamless switching between backends (Open-Source or Proprietary like Dynatrace).
- **Network Awareness (SNMP):** Integrated **SNMP Trap receiver** (via Telegraf) to capture asynchronous hardware events.
- **Unified Pipeline:** A single OTel Collector handles metrics, logs, and traces, ensuring data consistency and correlation.
- **Automated Deployment:** One-click `make deploy` that provisions the cluster, installs the stack, establishes port-forwards, and opens dashboards.
- **Security First:** Zero-trust network policies, hardened pod security contexts, and automated Trivy scans.

## Getting Started

Initialize the infrastructure and deploy the stack:

```bash
make deploy
```

*The script will automatically handle dependency checks, cluster creation (detecting your CPU architecture), and post-deployment access.*

## Testing SNMP Traps

To demonstrate how the system handles hardware/network events (the "SNMP Trap" feature used at the EC), run:

```bash
make send-test-trap
```
Then, check the **Loki/Grafana logs** to see the trap event being captured and routed through the OTel pipeline.

## Access URLs

| Service | URL | Credentials |
|---------|-----|-------------|
| Grafana | http://localhost:3000 | admin / prom-operator |
| Prometheus | http://localhost:9090 | - |
| Loki | http://localhost:3100 | - |
| PodInfo App | http://localhost:9898 | - |
| Icinga2 API | localhost:5665 | - |
| SNMP Receiver | telegraf-snmp:162 (UDP) | public |


## Useful Commands

```bash
make deploy              # Full deployment
make scan                # Scan vulnerabilities (Trivy)
make access              # Open all port-forwards
make ports              # Show URLs
make load-test          # Run load tests
make k6-web             # K6 Web Interface
kubectl get pods -A       # All pods
kubectl top pods -n monitoring  # Real-time metrics
colima status           # Cluster status
```

## Performance Validation

To simulate real-user traffic and observe the cluster's response (including auto-scaling and metric spikes), run the integrated load test:

```bash
make load-test
```

While the test is running, you can monitor the scaling behavior in your terminal:
```bash
kubectl get hpa -n app --watch
```

## Technical Architecture and Decisions

### 1. Observability: The 3 Pillars (Prometheus, Loki, Tempo)
Complete observability with:
- **Metrics (Prometheus):** Real-time performance indicators.
- **Logs (Loki):** Centralized log aggregation with direct correlation to traces.
- **Traces (Tempo):** Distributed tracing to visualize the request lifecycle across pods.
- **Grafana Visualization:** Unified dashboards with seamless navigation from Log to Trace.

### 2. Icinga2 for External Monitoring
Icinga2 provides enterprise-grade external monitoring for hosts and services, complementing Prometheus's metrics-based approach.

### 3. K6 for Performance Testing
K6 offers a developer-friendly load testing solution with both CLI and web UI. Perfect for validating system behavior under stress.

### 4. Resilience and Self-Healing
The deployment includes Liveness and Readiness probes. This ensures that traffic is only routed to healthy pods and that Kubernetes automatically restarts containers in case of failure.

### 5. Security & Compliance (DevSecOps)
- **Zero Trust Networking:** Network Policies with \`default-deny\` enforce strict isolation between namespaces and only allow authorized traffic (DNS, Monitoring, Apps).
- **Least Privilege RBAC:** Dedicated ServiceAccounts for applications, moving away from default permissions.
- **Pod Hardening:** SecurityContext enforces \`runAsNonRoot\`, drops all kernel capabilities, and prevents privilege escalation.
- **Automated Auditing:** Integrated \`make scan\` using **Trivy** to detect security misconfigurations in Kubernetes manifests.

### 6. Dynamic Scaling (HPA)
A Horizontal Pod Autoscaler is configured to scale the application from 2 to 5 replicas based on CPU utilization.

### 6. Resource Management
Optimized for 18GB RAM hosts, the stack uses resource limits and optimized container images for Apple Silicon.

## Future Roadmap (Production Readiness)

To transition this local prototype to a production-grade environment, the following enhancements are planned:

- **Infrastructure as Code (Terraform):** Replace manual cluster setup with Terraform providers (e.g., AWS EKS, Google GKE, or Azure AKS) to manage cloud resources and networking.
- **Configuration Management (Ansible):** Automate the baseline security and OS-level tuning for Kubernetes nodes.
- **CI/CD Integration:** Migrate the `Makefile` logic into GitHub Actions or GitLab CI for automated testing and deployment.
- **External Persistence:** Configure Loki and Prometheus to use object storage (like AWS S3 or Azure Blob Storage) for long-term log and metric retention.
- **Secrets Management:** Integrate with HashiCorp Vault or Cloud KMS instead of using hardcoded/dynamic terminal outputs for credentials.

## Cleanup

To stop the cluster:
```bash
make clean
```

To completely uninstall all tools and delete data:
```bash
make destroy
```
