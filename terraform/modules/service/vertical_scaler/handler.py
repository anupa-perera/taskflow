"""Moves the API service one step up its task size ladder.

Invoked by the vertical scaling composite alarm. Registers a copy of the service's current revision
with the next CPU and memory size, records that size in the SSM parameter the task definition is
built from (so the next Terraform release keeps it), and rolls the service out to the copy.
"""

import json
import logging
import os

import boto3

CLUSTER = os.environ["CLUSTER"]
SERVICE = os.environ["SERVICE"]
AT_MAX_TASKS_ALARM = os.environ["AT_MAX_TASKS_ALARM"]
TASK_SIZE_PARAMETER = os.environ["TASK_SIZE_PARAMETER"]
# Ordered smallest first, e.g. [{"cpu": 256, "memory": 512}, ...].
TASK_SIZES = json.loads(os.environ["TASK_SIZES"])

# Returned by DescribeTaskDefinition but rejected by RegisterTaskDefinition.
READ_ONLY_FIELDS = {
    "taskDefinitionArn",
    "revision",
    "status",
    "requiresAttributes",
    "compatibilities",
    "registeredAt",
    "registeredBy",
    "deregisteredAt",
}

cloudwatch = boto3.client("cloudwatch")
ecs = boto3.client("ecs")
ssm = boto3.client("ssm")
log = logging.getLogger()
log.setLevel(logging.INFO)


def next_size(cpu):
    return next((size for size in TASK_SIZES if size["cpu"] > cpu), None)


def handler(event, context):
    service = ecs.describe_services(cluster=CLUSTER, services=[SERVICE])["services"][0]
    # Sizing from a revision that a release or an earlier step is replacing could skip or undo it.
    if len(service["deployments"]) > 1:
        # The composite alarm acts only on entering ALARM. Resetting one of its inputs makes
        # CloudWatch re-evaluate it within a minute, so this invocation repeats until the deployment
        # ends, for as long as the load lasts.
        cloudwatch.set_alarm_state(
            AlarmName=AT_MAX_TASKS_ALARM,
            StateValue="OK",
            StateReason="Vertical scaler retrying after a deployment in progress",
        )
        log.warning("Deferred: a deployment is in progress on %s", SERVICE)
        return {"action": "deferred", "reason": "deployment in progress"}

    current = ecs.describe_task_definition(taskDefinition=service["taskDefinition"])["taskDefinition"]
    size = next_size(int(current["cpu"]))
    if size is None:
        log.warning("Skipped: %s already runs the largest size (cpu %s)", SERVICE, current["cpu"])
        return {"action": "skipped", "reason": "largest size"}

    revision = {key: value for key, value in current.items() if key not in READ_ONLY_FIELDS}
    revision.update(cpu=str(size["cpu"]), memory=str(size["memory"]))
    new_arn = ecs.register_task_definition(**revision)["taskDefinition"]["taskDefinitionArn"]

    # Recorded before the rollout: if the rollout call fails, the next release still applies the size.
    # Compact, like Terraform's jsonencode, because scripts/deploy.sh compares the text.
    value = json.dumps(size, separators=(",", ":"))
    ssm.put_parameter(Name=TASK_SIZE_PARAMETER, Value=value, Overwrite=True)
    ecs.update_service(cluster=CLUSTER, service=SERVICE, taskDefinition=new_arn)

    log.info("Scaled %s from %s to %s (%s)", SERVICE, current["taskDefinitionArn"], new_arn, size)
    return {"action": "scaled", "from": current["taskDefinitionArn"], "to": new_arn, "size": size}
