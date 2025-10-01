# Create a Custom Operating System Image for OKE Node Pools
How to make custom images for OKE node pools using platform images. How to speed up cloud-init using parallelization.

Prerequisites:
 * OCI CLI Installed and configured
 * Existing OKE Cluster

## 1. Find a suitable platform image using the oci cli

### For all x86 (AMD and Intel Shapes)
```bash
oci ce node-pool-options get --node-pool-option-id all | jq '.data.sources[] | select(."source-name" | test("GPU|aarch") | not )'
```

### For all ARM images
```bash
oci ce node-pool-options get --node-pool-option-id all | jq '.data.sources[] | select(."source-name" | contains("aarch"))'
```

### For GPU images

```bash
oci ce node-pool-options get --node-pool-option-id all | jq '.data.sources[] | select(."source-name" | contains("GPU"))'
```

### Example: 
Find the most recent image for AMD that runs Kubernetes 1.33.1 on Oracle Linux 8.10:

```bash
oci ce node-pool-options get --node-pool-option-id all | jq '.data.sources[] | select(."source-name" | test("GPU|aarch") | not ) | select(."source-name" | contains("8.10") and contains("1.33.1"))' | head -n 5
# Get a list of all OKE platform images and query the image source name for anything not containing "GPU" or "aarch" that has Oracle Linux 8.10 for Kubernetes v1.33.1. Just the first 5 lines (first record)
{
  "image-id": "ocid1.image.oc1.iad.aaaaaaaa5edwbg2opjm527dp3t2zymrnv72dwrqubmxlh4v7jljj3ww2nuva",
  "source-name": "Oracle-Linux-8.10-2025.08.31-0-OKE-1.33.1-1191",
  "source-type": "IMAGE"
}
```

I can then note the OCID for the platform image I want to use as a base for my custom image:

`ocid1.image.oc1.iad.aaaaaaaa5edwbg2opjm527dp3t2zymrnv72dwrqubmxlh4v7jljj3ww2nuva`

## 2. Create an Instance using this ocid

You can do this in the console by selecting My Images 



