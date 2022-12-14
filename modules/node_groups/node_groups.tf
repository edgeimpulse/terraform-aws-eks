resource "aws_eks_node_group" "workers" {
  for_each = local.node_groups_expanded

  node_group_name = lookup(each.value, "name", join("-", [var.cluster_name, each.key, random_pet.node_groups[each.key].id]))

  cluster_name  = var.cluster_name
  node_role_arn = each.value["iam_role_arn"]
  subnet_ids    = each.value["subnets"]

  scaling_config {
    desired_size = max(each.value["desired_capacity"], 1)
    max_size     = each.value["max_capacity"]
    min_size     = max(each.value["min_capacity"], 1)
  }

  ami_type             = lookup(each.value, "ami_type", null)
  disk_size            = each.value["launch_template_id"] != null || each.value["create_launch_template"] ? null : lookup(each.value, "disk_size", null)
  instance_types       = !each.value["set_instance_types_on_lt"] ? each.value["instance_types"] : null
  release_version      = lookup(each.value, "ami_release_version", null)
  capacity_type        = lookup(each.value, "capacity_type", null)
  force_update_version = lookup(each.value, "force_update_version", null)

  dynamic "remote_access" {
    for_each = each.value["key_name"] != "" && each.value["launch_template_id"] == null && !each.value["create_launch_template"] ? [{
      ec2_ssh_key               = each.value["key_name"]
      source_security_group_ids = lookup(each.value, "source_security_group_ids", [])
    }] : []

    content {
      ec2_ssh_key               = remote_access.value["ec2_ssh_key"]
      source_security_group_ids = remote_access.value["source_security_group_ids"]
    }
  }

  dynamic "launch_template" {
    for_each = each.value["launch_template_id"] != null ? [{
      id      = each.value["launch_template_id"]
      version = each.value["launch_template_version"]
    }] : []

    content {
      id      = launch_template.value["id"]
      version = launch_template.value["version"]
    }
  }

  dynamic "launch_template" {
    for_each = each.value["launch_template_id"] == null && each.value["create_launch_template"] ? [{
      id      = aws_launch_template.workers[each.key].id
      version = aws_launch_template.workers[each.key].latest_version
    }] : []

    content {
      id      = launch_template.value["id"]
      version = launch_template.value["version"]
    }
  }

  version = lookup(each.value, "version", null)

  labels = merge(
    lookup(var.node_groups_defaults, "k8s_labels", {}),
    lookup(var.node_groups[each.key], "k8s_labels", {})
  )

  tags = merge(
    var.tags,
    lookup(var.node_groups_defaults, "additional_tags", {}),
    lookup(var.node_groups[each.key], "additional_tags", {}),
  )

  dynamic "taint" {
    for_each = lookup(var.node_groups[each.key], "taints", {})
    content {
      key      = taint.value["key"]
      value    = taint.value["value"]
      effect   = taint.value["effect"]
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [
      scaling_config.0.desired_size,
      # because its not possible to dynamically ignore some additional fields, we have to add them for all cases (see: https://github.com/hashicorp/terraform/issues/24188)
      scaling_config.0.min_size, # when we configure min_size=0 it will be configured as min_size=1 and provisioned manually to 0. terraform will detect a need to change from 0 to 1 the next "apply", so we have to ignore it
      launch_template.0.version # in case of version='$Latest' terraform will always ask to change the version from fixed number to '$Latest'
    ]
  }

  depends_on = [var.ng_depends_on]
}

# workaround for: https://github.com/hashicorp/terraform-provider-aws/issues/13984
resource "null_resource" "capacity_0_provisioners" {
  for_each = {
    for k, v in local.node_groups_expanded: k => v
    if v["desired_capacity"] == 0 || v["min_capacity"] == 0
  }

  triggers = {
    node_group = aws_eks_node_group.workers[each.key]["resources"][0]["autoscaling_groups"][0]["name"]
  }
  provisioner "local-exec" {
      command = <<EOF
  aws autoscaling  update-auto-scaling-group\
  --desired-capacity ${local.node_groups_expanded[each.key]["desired_capacity"]}\
  --min-size ${local.node_groups_expanded[each.key]["min_capacity"]}\
  --auto-scaling-group-name ${aws_eks_node_group.workers[each.key]["resources"][0]["autoscaling_groups"][0]["name"]}
  EOF
  }
}

# workaround for https://github.com/terraform-aws-modules/terraform-aws-eks/issues/860

locals {
  custom_tags_prefix = ["k8s.io/cluster-autoscaler/node-template"]
}
resource "null_resource" "add_custom_tags_to_asg" {
  for_each = {
    for k, v in local.node_groups_expanded: k => v
    if length({ for ng_k, ng_v in lookup(var.node_groups[k], "additional_tags", {}) : ng_k => ng_v
               if length([
                 for prefix in local.custom_tags_prefix : prefix
                 if substr(ng_k, 0, length(prefix)) == prefix
                 ]) > 0 }) > 0
  }
  triggers = {
    node_group = aws_eks_node_group.workers[each.key]["resources"][0]["autoscaling_groups"][0]["name"]
    command = join("\n", [
        for key, value in { for ng_k, ng_v in lookup(var.node_groups[each.key], "additional_tags", {}) : ng_k => ng_v
               if length([
                 for prefix in local.custom_tags_prefix : prefix
                 if substr(ng_k, 0, length(prefix)) == prefix
                 ]) > 0 }:
        <<EOF
  aws autoscaling create-or-update-tags \
  --tags ResourceId=${aws_eks_node_group.workers[each.key]["resources"][0]["autoscaling_groups"][0]["name"]},ResourceType=auto-scaling-group,Key=${key},Value=${value},PropagateAtLaunch=true
  EOF
  ])
  }
  provisioner "local-exec" {
      command = join("\n", [
        for key, value in { for ng_k, ng_v in lookup(var.node_groups[each.key], "additional_tags", {}) : ng_k => ng_v
               if length([
                 for prefix in local.custom_tags_prefix : prefix
                 if substr(ng_k, 0, length(prefix)) == prefix
                 ]) > 0 }:
        <<EOF
  aws autoscaling create-or-update-tags \
  --tags ResourceId=${aws_eks_node_group.workers[each.key]["resources"][0]["autoscaling_groups"][0]["name"]},ResourceType=auto-scaling-group,Key=${key},Value=${value},PropagateAtLaunch=true
  EOF
  ])
  }
}

