data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  cluster_instance_ids = concat(
    [aws_instance.master.id],
    aws_instance.worker[*].id,
  )

  cluster_instance_arns = [
    for id in local.cluster_instance_ids :
    "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/${id}"
  ]
}

resource "aws_iam_role" "scheduler" {
  name = "dev-platform-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "scheduler.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_ec2" {
  name = "dev-platform-scheduler-ec2"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:StopInstances",
        "ec2:StartInstances",
      ]
      Resource = local.cluster_instance_arns
    }]
  })
}

resource "aws_scheduler_schedule" "cluster_stop" {
  name        = "dev-platform-cluster-stop"
  description = "Stop the dev-platform cluster at 21:00 Europe/Berlin"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(0 21 * * ? *)"
  schedule_expression_timezone = "Europe/Berlin"

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      InstanceIds = local.cluster_instance_ids
    })
  }
}

resource "aws_scheduler_schedule" "cluster_start" {
  name        = "dev-platform-cluster-start"
  description = "Start the dev-platform cluster at 05:00 Europe/Berlin"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(0 5 * * ? *)"
  schedule_expression_timezone = "Europe/Berlin"

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      InstanceIds = local.cluster_instance_ids
    })
  }
}
