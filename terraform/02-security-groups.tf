variable "operator_cidr" {
  description = "Public CIDR allowed to reach the Talos and Kubernetes APIs (set to your laptop's public IP /32 in terraform.tfvars)"
  type        = string
}

resource "aws_security_group" "cluster" {
  name        = "dev-platform-cluster"
  description = "Talos + Kubernetes cluster nodes"
  vpc_id      = aws_vpc.main_vpc.id

  tags = {
    Name = "dev-platform-cluster"
  }
}

resource "aws_vpc_security_group_ingress_rule" "cluster_self" {
  security_group_id            = aws_security_group.cluster.id
  referenced_security_group_id = aws_security_group.cluster.id
  ip_protocol                  = "-1"
  description                  = "All traffic between cluster nodes"
}

resource "aws_vpc_security_group_ingress_rule" "talos_api" {
  security_group_id = aws_security_group.cluster.id
  cidr_ipv4         = var.operator_cidr
  from_port         = 50000
  to_port           = 50000
  ip_protocol       = "tcp"
  description       = "Talos machine API"
}

resource "aws_vpc_security_group_ingress_rule" "kube_api" {
  security_group_id = aws_security_group.cluster.id
  cidr_ipv4         = var.operator_cidr
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
  description       = "Kubernetes API server"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.cluster.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All egress"
}
