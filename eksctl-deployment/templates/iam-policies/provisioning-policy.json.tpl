{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManageUserIAMRoles",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:TagRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:ListAttachedRolePolicies"
      ],
      "Resource": "arn:aws:iam::${AWS_ACCOUNT}:role/openclaw-user-*"
    },
    {
      "Sid": "PassRoleToServiceAccounts",
      "Effect": "Allow",
      "Action": [
        "iam:PassRole"
      ],
      "Resource": [
        "arn:aws:iam::${AWS_ACCOUNT}:role/OpenClawBedrockRole",
        "arn:aws:iam::${AWS_ACCOUNT}:role/openclaw-user-*"
      ]
    },
    {
      "Sid": "GetSharedBedrockRole",
      "Effect": "Allow",
      "Action": [
        "iam:GetRole"
      ],
      "Resource": "arn:aws:iam::${AWS_ACCOUNT}:role/OpenClawBedrockRole"
    },
    {
      "Sid": "ManagePodIdentityAssociations",
      "Effect": "Allow",
      "Action": [
        "eks:CreatePodIdentityAssociation",
        "eks:DeletePodIdentityAssociation",
        "eks:DescribePodIdentityAssociation",
        "eks:ListPodIdentityAssociations"
      ],
      "Resource": "*"
    }
  ]
}
