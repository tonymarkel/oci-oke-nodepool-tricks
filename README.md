# OKE Node Pool Tricks

If you've ever had an issue with optimizing OKE clusters, this repo is intended to gather some of the tips and tricks I've gathered.

## Take me to the scripts:

* [Make a custom image](./Make_a_custom_node_image.md) and also [Build an Image Pipeline](https://github.com/yogendradevaraju/oci-devops-pipeline-terraform)
* [Make cloud-init operations parallelized](./Make_cloud-init_faster.sh)

## Making a Custom Image
If your OKE node pool requires the installation of the OCI CLI, or other custom programs, you may have noticed that it takes a long time to spin up your node pool. In some cases as long as 15 minutes. You can save a ton of time when deploying an OKE Node pool by simply creating an image from an existing OKE Image, and adding your custom programming to it. If you have large container images, you can also pre-pull those using an image pipeline. Regardless making a custom image can eliminate the following time intensive operations:
* Operating System Updates: 2-3 minutes
* Operating System Package Installation (i.e. the oci-cli): 1-2 minutes
* Container Images > 10GB: 1-2 minutes per container image over 10GB

## Parallelize Cloud-Init
If, after making a custom image, you still have a lot of operations that must happen to an individual node like:
* Creating and mounting volumes
* Creating and attaching additional vnics
* Node-specific software configurations (like registering a node with external monitoring)
performing them in parallel may save additional time.
[!CAUTION] - If a pod requires all resources to be present before becoming active, this method may not work for you.
The example linked to this method places the oke-init portion of the cloud-init in parallel with other actions.
