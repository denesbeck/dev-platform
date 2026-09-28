data "aws_ami" "talos" {
  most_recent = true
  owners      = ["540036508848"]

  filter {
    name   = "name"
    values = ["talos-v${var.talos_version}*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "master" {
  ami                    = data.aws_ami.talos.id
  instance_type          = "t3a.medium"
  subnet_id              = aws_subnet.main_sn.id
  vpc_security_group_ids = [aws_security_group.cluster.id]

  # Bring the public routing path (IGW + route table + association) up before
  # the node launches, and tear it down after. On create this guarantees the
  # IGW is attached before the EIP association (else Gateway.NotAttached) and
  # before Talos config-apply dials the node's public IP. On destroy it reverses:
  # the node (and its public IP) is gone before the IGW detaches, so the detach
  # doesn't hit DependencyViolation and retry for ~15 min.
  depends_on = [aws_route_table_association.main_rta]

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  # Increasing hop limit for EBS CSI Driver: 
  # https://github.com/kubernetes-sigs/aws-ebs-csi-driver/blob/master/docs/install.md#imds-ec2-metadata
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # enforces IMDSv2 only
    http_put_response_hop_limit = 3
  }

  tags = {
    Name = "dev-platform-master"
    Role = "control-plane"
  }
}

resource "aws_eip" "master" {
  domain = "vpc"

  tags = {
    Name = "dev-platform-master"
  }
}

resource "aws_eip_association" "master" {
  instance_id   = aws_instance.master.id
  allocation_id = aws_eip.master.id
}

resource "aws_instance" "worker" {
  count = 2

  ami                    = data.aws_ami.talos.id
  instance_type          = "t3a.medium"
  subnet_id              = aws_subnet.main_sn.id
  vpc_security_group_ids = [aws_security_group.cluster.id]

  # See aws_instance.master — routing up before launch, down after termination.
  depends_on = [aws_route_table_association.main_rta]

  instance_market_options {
    market_type = "spot"
    spot_options {
      spot_instance_type             = "persistent"
      instance_interruption_behavior = "stop"
    }
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  # Increasing hop limit for EBS CSI Driver: 
  # https://github.com/kubernetes-sigs/aws-ebs-csi-driver/blob/master/docs/install.md#imds-ec2-metadata
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # enforces IMDSv2 only
    http_put_response_hop_limit = 3
  }

  tags = {
    Name = "dev-platform-worker-${count.index}"
    Role = "worker"
  }
}

# Persistent spot requests survive instance termination — AWS treats it as a
# recoverable event and re-launches the worker. terraform destroy then hangs
# (IGW won't detach while ENIs hold public IPs) and the cluster won't actually
# go away. This destroy-time hook cancels each worker's spot request *before*
# the aws_instance.worker is terminated, so AWS can't bring it back.
#
# Why this works: the trigger reads aws_instance.worker[*].spot_instance_request_id
# at create time and persists it in state. At destroy time, Terraform reverses
# the dependency graph, so this null_resource is destroyed first (running the
# local-exec), then the worker instance is terminated. Persistent semantics
# (auto-recovery from spot interruption) remain intact for normal operation —
# we only undo them when intentionally tearing the cluster down.
resource "null_resource" "cancel_worker_spot_request" {
  count = length(aws_instance.worker)

  triggers = {
    spot_request_id = aws_instance.worker[count.index].spot_instance_request_id
    region          = "eu-central-1"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "aws ec2 cancel-spot-instance-requests --region ${self.triggers.region} --spot-instance-request-ids ${self.triggers.spot_request_id}"
  }
}
