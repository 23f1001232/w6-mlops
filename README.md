# 🧠 Iris Model Deployment on GKE Autopilot

This repository demonstrates an **end-to-end ML model deployment workflow** on **Google Cloud Platform (GCP)** using **GitHub Actions** and **GKE Autopilot**.  
The project includes a FastAPI inference service, containerization, Artifact Registry, and deployment to GKE.

---

## 📁 Repository Structure

| File/Folder | Description |
|--------------|-------------|
| `Dockerfile` | Defines the container image for the Iris prediction model API. |
| `iris_fastapi.py` | FastAPI application exposing the model inference endpoint and `/health`. |
| `requirements.txt` | Python dependencies required for the model and API. |
| `model.joblib` | Serialized scikit-learn Iris model used by the API (not checked into GitHub; keep out of git or store safely). |
| `k8s/deployment.yaml` | Kubernetes deployment configuration for the Iris service (Autopilot-friendly resources). |
| `k8s/service.yaml` | Kubernetes Service manifest exposing the deployment (ClusterIP / LoadBalancer). |
| `.github/workflows/ci-cd.yml` | GitHub Actions pipeline for CI/CD — builds, pushes, and deploys the image to GKE. |
| `README.md` | This file — documentation for setup, deployment, and troubleshooting. |

> **Security note:** Never commit service account keys, OAuth tokens, or other credentials to the repository. Use GitHub Secrets and IAM service accounts instead.

---

## 🚀 Workflow Overview

1. **Model & API**
   - `iris_fastapi.py` loads `model.joblib` with `joblib.load("model.joblib")` and exposes `/predict/` POST endpoint and `/health` GET endpoint.
2. **Containerization**
   - `Dockerfile` installs dependencies from `requirements.txt`, copies `iris_fastapi.py` and `model.joblib`, and runs `uvicorn` on port 8000.
3. **Artifact Registry**
   - GitHub Actions builds the image and pushes to **Google Artifact Registry** in `us-central1` (e.g. `us-central1-docker.pkg.dev/<PROJECT>/<REPO>/<IMAGE>:<TAG>`).
4. **Deployment**
   - Actions authenticates with GCP using a service account stored in `GCP_SA_KEY` GitHub Secret.
   - The workflow gets GKE credentials and applies the manifests in `k8s/`.
   - `kubectl set image` or `sed` replacement is used to point the Deployment at the pushed image tag, then `kubectl rollout status` waits for readiness.

---

## ⚠️ Deployed Failure: Quota Exceeded (Root Cause)

### Problem Summary
The cluster autoscaler attempted to provision nodes for the deployment but failed with:
```
FailedScaleUp: Node scale up in zones us-central1-a/us-central1-f associated with this pod failed: GCE quota exceeded.
```

Even though the pod resource requests were small, Autopilot tried to create node VMs that consume several vCPUs. Your project hit **Compute Engine CPU quota limits** (regional / zonal), preventing node creation and leaving pods in `Pending` state.

### Evidence Extracted
From `gcloud compute project-info describe` you observed:
- `CPUS_ALL_REGIONS`: limit = 12, usage = 2
- Region / zone-level CPU quotas were exhausted (events showed `us-central1-a`, `us-central1-f`, `us-central1-c` attempts).

---

## 🧠 Why this happens (short)
- Autopilot chooses node machine types; even small pods can trigger provisioning of multi-vCPU VMs.
- Quotas are enforced per region/zone; a new node creation consumes whole vCPUs from the quota.
- If those zone-level quotas are full, the autoscaler fails even if global usage appears low.

---

## ✅ Recommended Fixes

### 1) Immediate — Deploy to Cloud Run (no VM quota)
Use the image you already pushed for fast availability:

```bash
IMAGE_URI="us-central1-docker.pkg.dev/vivid-science-473308-m7/my-repo/iris-api:5e8611f"
gcloud services enable run.googleapis.com --project=vivid-science-473308-m7

gcloud run deploy iris-api \
  --image="${IMAGE_URI}" \
  --platform=managed \
  --region=us-central1 \
  --allow-unauthenticated \
  --port=8000 \
  --project=vivid-science-473308-m7
```

Cloud Run returns a public URL quickly and avoids Compute Engine quota.

---

### 2) Long-term — Increase Compute Engine CPU quota (recommended for GKE)
Open **Console → IAM & Admin → Quotas**, filter metric `CPUS` and location `us-central1` or the specific zones (`us-central1-a`, `us-central1-f`, `us-central1-c`), and request an increase.

**Suggested justification (copy/paste):**
> Our GKE Autopilot cluster (autopilot-cluster-1) is failing to autoscale due to CPU quota limits in `us-central1`. The cluster-autoscaler reported `FailedScaleUp` in zones `us-central1-a`, `us-central1-f`, and `us-central1-c`. Please increase CPU quota by **+8 CPUs** in the `us-central1` region (or +4 CPUs per affected zone) to allow scheduling of a small ML inference deployment (2 replicas). We will monitor usage and request further increases if needed.

---

### 3) Alternative — Create a new cluster in a region/zone with free quota
If quota is low in `us-central1`, consider creating a standard GKE cluster in another region (e.g., `us-west1`). Standard clusters allow selecting small machine types (e2-small) which may fit your quota.

```bash
gcloud container clusters create iris-standard-cluster \
  --zone=us-west1-a \
  --num-nodes=1 \
  --machine-type=e2-small \
  --project=vivid-science-473308-m7
```

Apply k8s manifests after getting credentials:
```bash
gcloud container clusters get-credentials iris-standard-cluster --zone=us-west1-a --project=vivid-science-473308-m7
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl rollout status deployment/iris-deployment --timeout=300s
```

---

## 🔍 Troubleshooting Checklist

1. **Check deployment image**  
   ```bash
   kubectl get deployment iris-deployment -o=jsonpath='{.spec.template.spec.containers[0].image}'; echo
   ```

2. **Check pods & events**
   ```bash
   kubectl get pods -l app=iris -o wide
   kubectl get events --sort-by='.metadata.creationTimestamp' | tail -n 50
   ```

3. **Inspect quota**
   ```bash
   gcloud compute regions describe us-central1 --project=vivid-science-473308-m7 --format="table(quotas.metric,quotas.limit,quotas.usage)"
   ```

4. **If Pending with FailedScaleUp** → request quota increase (see above) or deploy to Cloud Run.

---

## 🧾 Example Kubernetes manifests (for reference)

**k8s/deployment.yaml**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: iris-deployment
  labels:
    app: iris
spec:
  replicas: 2
  selector:
    matchLabels:
      app: iris
  template:
    metadata:
      labels:
        app: iris
    spec:
      containers:
        - name: iris-api
          image: IMAGE_PLACEHOLDER
          ports:
            - containerPort: 8000
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "250m"
              memory: "256Mi"
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 5
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 30
            periodSeconds: 30
            timeoutSeconds: 2
            failureThreshold: 5
```

**k8s/service.yaml**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: iris-service
spec:
  selector:
    app: iris
  ports:
    - protocol: TCP
      port: 80
      targetPort: 8000
  type: ClusterIP
```

---

## ✅ Final Recommendations

- For immediate availability, deploy to **Cloud Run** (fastest).  
- For long-term stability on GKE Autopilot, **request CPU quota increases** for `us-central1` or create a cluster in a different region with spare quota.  
- Avoid committing secrets to git — use **GitHub Secrets** and bind minimal IAM roles to service accounts used in CI.

---

**Author:** Sahil Sharma  
**Project:** ML Model Deployment on GKE  
**Date:** November 2025
