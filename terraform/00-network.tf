resource "aws_vpc" "main_vpc" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "dev-platform"
    # Marks VPC resources as owned by this cluster (AWS cloud-provider convention).
    "kubernetes.io/cluster/dev-platform" = "owned"
  }
}

resource "aws_subnet" "main_sn" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.10.1.0/24"
  availability_zone       = "eu-central-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "dev-platform-public-a"
    # LB Controller subnet auto-discovery — WITHOUT these, Ingress/type=LoadBalancer
    # can't place ALBs/NLBs and fails with "couldn't auto-discover subnets".
    # role/elb=1 = internet-facing LBs go here. Docs:
    # https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/subnet_discovery/
    "kubernetes.io/cluster/dev-platform" = "owned"
    "kubernetes.io/role/elb"             = "1"
  }
}

resource "aws_internet_gateway" "main_igw" {
  vpc_id = aws_vpc.main_vpc.id

  tags = {
    Name = "dev-platform"
  }
}

resource "aws_route_table" "main_rt" {
  vpc_id = aws_vpc.main_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main_igw.id
  }

  tags = {
    Name = "dev-platform-public"
  }
}

resource "aws_route_table_association" "main_rta" {
  subnet_id      = aws_subnet.main_sn.id
  route_table_id = aws_route_table.main_rt.id
}
