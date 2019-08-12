terraform {
  backend "remote" {
    hostname = "app.terraform.io"
    organization = "jschulman"

    workspaces {
      name = "jenkins-x"

    }
  }
}

provider "aws" {
    region = "${var.aws_region}"
}

resource "aws_vpc" "default" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "jenkins-west" {
  vpc_id                  = "${aws_vpc.default.id}"
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-west-1"
}

resource "aws_subnet" "jenkins-east" {
  vpc_id                  = "${aws_vpc.default.id}"
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1"
}

module "eks" {
    source       = "terraform-aws-modules/eks/aws"
    cluster_name = "${var.aws_region}"
    subnets      = ["${aws_subnet.jenkins-east.id}", "${aws_subnet.jenkins-west.id}"]
    vpc_id       = "${aws_vpc.default.id}"
    worker_groups = [
        {
            autoscaling_enabled   = true
            asg_min_size          = 3
            asg_desired_capacity  = 3
            instance_type         = "t3.large"
            asg_max_size          = 20
            key_name              = "${var.key_pair_name}"
        }
    ]
    version = "5.0.0"
}

# Needed for cluster-autoscaler
resource "aws_iam_role_policy_attachment" "workers_AmazonEC2ContainerRegistryPowerUser" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
  role       = "${module.eks.worker_iam_role_name}"
}

# Create S3 bucket for KMS
resource "aws_s3_bucket" "vault-unseal" {
    bucket = "vault-unseal.${var.aws_region}.${var.bucket_domain}"
    acl    = "private"

    versioning {
        enabled = false
    }
}

# Create KMS key
resource "aws_kms_key" "bank_vault" {
    description = "KMS Key for bank vault unseal"
}

# Create DynamoDB table
resource "aws_dynamodb_table" "vault-data" {
    name           = "vault-data"
    read_capacity  = 2
    write_capacity = 2
    hash_key       = "Path"
    range_key      = "Key"
    attribute {
        name = "Path"
        type = "S"
    }

    attribute {
        name = "Key"
        type = "S"
    }
}

# Create service account for vault. Should the policy
resource "aws_iam_user" "vault" {
  name = "vault_${var.aws_region}"
}

data "aws_iam_policy_document" "vault" {
    statement {
        sid = "DynamoDB"
        effect = "Allow"
        actions = [
            "dynamodb:DescribeLimits",
            "dynamodb:DescribeTimeToLive",
            "dynamodb:ListTagsOfResource",
            "dynamodb:DescribeReservedCapacityOfferings",
            "dynamodb:DescribeReservedCapacity",
            "dynamodb:ListTables",
            "dynamodb:BatchGetItem",
            "dynamodb:BatchWriteItem",
            "dynamodb:CreateTable",
            "dynamodb:DeleteItem",
            "dynamodb:GetItem",
            "dynamodb:GetRecords",
            "dynamodb:PutItem",
            "dynamodb:Query",
            "dynamodb:UpdateItem",
            "dynamodb:Scan",
            "dynamodb:DescribeTable"
        ]
        resources = ["${aws_dynamodb_table.vault-data.arn}"]
    }
    statement {
        sid = "S3"
        effect = "Allow"
        actions = [
                "s3:PutObject",
                "s3:GetObject"
        ]
        resources = ["${aws_s3_bucket.vault-unseal.arn}/*"]
    }
    statement {
        sid = "S3List"
        effect = "Allow"
        actions = [
            "s3:ListBucket"
        ]
        resources = ["${aws_s3_bucket.vault-unseal.arn}"]
    }
    statement {
        sid = "KMS"
        effect = "Allow"
        actions = [
            "kms:Encrypt",
            "kms:Decrypt",
            "kms:DescribeKey"
        ]
        resources = ["${aws_kms_key.bank_vault.arn}"]
    }
}

resource "aws_iam_user_policy" "vault" {
    name = "vault_${var.aws_region}"
    user = "${aws_iam_user.vault.name}"

    policy = "${data.aws_iam_policy_document.vault.json}"
}

resource "aws_iam_access_key" "vault" {
    user = "${aws_iam_user.vault.name}"
}

# Output KMS key id, S3 bucket name and secret name in the form of jx install options
output "jx_params" {
    value = "--provider=eks --gitops --no-tiller --vault --aws-dynamodb-region=${var.aws_region} --aws-dynamodb-table=${aws_dynamodb_table.vault-data.name} --aws-kms-region=${var.aws_region} --aws-kms-key-id=${aws_kms_key.bank_vault.key_id} --aws-s3-region=${var.aws_region}  --aws-s3-bucket=${aws_s3_bucket.vault-unseal.id} --aws-access-key-id=${aws_iam_access_key.vault.id} --aws-secret-access-key=${aws_iam_access_key.vault.secret}"
}