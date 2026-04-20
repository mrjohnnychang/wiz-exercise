# Uses a bucket to save the state file to make iterative updates. Empty the S3 to recreate AWS resources from scratch
terraform {
  backend "s3" {
    bucket = "johnny-terraform-state-12345"
    key    = "wiz-exercise/terraform.tfstate"
    region = "us-west-2"
  }
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

data "aws_caller_identity" "current" {}

locals {
  # Dynamically strips the temporary STS Session ID so EKS maps the permanent IAM Role
  arn_parts       = split("/", data.aws_caller_identity.current.arn)
  is_assumed_role = strcontains(data.aws_caller_identity.current.arn, "assumed-role")
  base_arn        = local.is_assumed_role ? "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.arn_parts[1]}" : data.aws_caller_identity.current.arn
}

# 1. VPC Network
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"
  name    = "wiz-vpc"
  cidr    = "10.0.0.0/16"
  azs     = ["us-west-2a", "us-west-2b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]
  enable_nat_gateway = true
}

# 2. EKS Cluster, including LB and ingress controller via helm
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"
  cluster_name    = "wiz-cluster"
  cluster_version = "1.35"
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets
  cluster_endpoint_public_access = true
  #Grant permanent admin access to the base pipeline role
  access_entries = {
    pipeline_admin = {
      principal_arn = local.base_arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }
  eks_managed_node_groups = {
    wiz_nodes = {
      ami_type       = "AL2023_x86_64_STANDARD"  # Explicitly use AL2023 for 1.35+
      instance_types = ["t3a.medium"]
      min_size     = 2
      max_size     = 2
      desired_size = 2
    }
  }
}

# Fetch the authentication token natively
data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

resource "helm_release" "nginx_ingress" {
  name             = "nginx-ingress"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  depends_on       = [module.eks] # Forces Terraform to wait for the cluster to be fully online
}

# 3. Vulnerable S3 Bucket
resource "aws_s3_bucket" "vulnerable_bucket" {
  bucket = "wiz-demo-vulnerable-bucket-${data.aws_caller_identity.current.account_id}"
}

#  Allows attaching a public policy
resource "aws_s3_bucket_public_access_block" "public_access" {
  bucket = aws_s3_bucket.vulnerable_bucket.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Policy that grants public read and list access
resource "aws_s3_bucket_policy" "public_read_list" {
  bucket = aws_s3_bucket.vulnerable_bucket.id
  depends_on = [aws_s3_bucket_public_access_block.public_access] # Forces Terraform to wait for the block to be lifted
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.vulnerable_bucket.arn,
          "${aws_s3_bucket.vulnerable_bucket.arn}/*"
        ]
      }
    ]
  })
}

# 4. Vulnerable IAM Role for EC2
resource "aws_iam_role" "vulnerable_role" {
  name = "wiz-vulnerable-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "admin_attach" {
  role       = aws_iam_role.vulnerable_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "vulnerable_profile" {
  name = "wiz-vulnerable-profile"
  role = aws_iam_role.vulnerable_role.name
}

# Grants the VM full control over EC2 (Required: able to create VMs)
resource "aws_iam_role_policy_attachment" "db_ec2_full" {
  role       = aws_iam_role.vulnerable_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

# Grants the VM full control over all S3 buckets
resource "aws_iam_role_policy_attachment" "db_s3_full" {
  role       = aws_iam_role.vulnerable_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

# Add SSM access so you can actually log in to test these permissions
resource "aws_iam_role_policy_attachment" "db_ssm_core" {
  role       = aws_iam_role.vulnerable_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Create Interface Endpoints so the EC2 can talk to SSM privately
resource "aws_vpc_endpoint" "ssm" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.us-west-2.ssm"
  vpc_endpoint_type = "Interface"
  subnet_ids        = [module.vpc.public_subnets[0]] # Matches EC2 subnet
  security_group_ids = [aws_security_group.mongo_sg.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.us-west-2.ssmmessages"
  vpc_endpoint_type = "Interface"
  subnet_ids        = [module.vpc.public_subnets[0]]
  security_group_ids = [aws_security_group.mongo_sg.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.us-west-2.ec2messages"
  vpc_endpoint_type = "Interface"
  subnet_ids        = [module.vpc.public_subnets[0]]
  security_group_ids = [aws_security_group.mongo_sg.id]
  private_dns_enabled = true
}

# 5. Outdated MongoDB EC2 Instance
data "aws_ami" "ubuntu_18_04" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu-pro-server/images/hvm-ssd/ubuntu-bionic-18.04-amd64-pro-server-20251001"]
  }
}

resource "aws_security_group" "mongo_sg" {
  name   = "wiz-mongo-sg"
  vpc_id = module.vpc.vpc_id
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 27017
    to_port     = 27017
    protocol    = "tcp"
    security_groups = [module.eks.node_security_group_id] # Strictly limits to K8s nodes    
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "mongodb" {
  ami           = data.aws_ami.ubuntu_18_04.id
  instance_type = "t3a.small"
  subnet_id     = module.vpc.public_subnets[0]
  vpc_security_group_ids = [aws_security_group.mongo_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.vulnerable_profile.name
  associate_public_ip_address = true

  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y mongodb awscli

              # Open MongoDB to external connections and enforce auth
              sed -i 's/bind_ip = 127.0.0.1/bind_ip = 0.0.0.0/' /etc/mongodb.conf
              echo "auth = true" >> /etc/mongodb.conf
              systemctl restart mongodb
              sleep 5 # Wait a few seconds for the database to fully boot

              # 1. Create the MongoDB Database and User
              mongo tasky --eval "db.createUser({user: 'taskyuser', pwd: 'taskypassword', roles: [{role: 'readWrite', db: 'tasky'}]})"

              # 2. Create the backup script locally on the EC2
              cat << 'SCRIPT' > /home/ubuntu/backup.sh
              #!/bin/bash
              /usr/bin/mongodump --username taskyuser --password taskypassword --authenticationDatabase tasky --out /tmp/mongobackup
              # Notice how Terraform automatically injects your dynamic bucket name below!
              /usr/bin/aws s3 cp /tmp/mongobackup s3://${aws_s3_bucket.vulnerable_bucket.bucket}/ --recursive
              SCRIPT

              # Make the script executable
              chmod +x /home/ubuntu/backup.sh

              # 3. Create the cronjob to run daily at midnight
              (crontab -l 2>/dev/null; echo "0 0 * * * /home/ubuntu/backup.sh") | crontab -
EOF
}

# 6. Internal DNS for MongoDB
resource "aws_route53_zone" "private" {
  name = "wiz.internal"
  vpc {
    vpc_id = module.vpc.vpc_id
  }
}

resource "aws_route53_record" "mongodb" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "mongodb.wiz.internal"
  type    = "A"
  ttl     = "300"
  records = [aws_instance.mongodb.private_ip]
}