apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: ${EFS_ID}
  directoryPerms: "700"
  basePath: /openclaw
  uid: "1000"
  gid: "1000"
mountOptions:
  - tls
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
