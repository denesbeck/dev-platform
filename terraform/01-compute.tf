data "aws_ami" "talos" {
  most_recent = true
  owners      = ["540036508848"]

  filter {
    name   = "name"
    values = ["talos-v*"]
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

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
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

  tags = {
    Name = "dev-platform-worker-${count.index}"
    Role = "worker"
  }
}
