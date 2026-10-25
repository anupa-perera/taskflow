"""Runs the handler against stubbed AWS clients, which validate every request against the real API
model, so a field RegisterTaskDefinition rejects fails here.
Run: python -m unittest test_handler (with boto3 installed, from this directory).
"""

import json
import os
import unittest

os.environ.update(
    AWS_DEFAULT_REGION="ap-south-1",
    CLUSTER="cluster",
    SERVICE="api",
    AT_MAX_TASKS_ALARM="api-at-max-tasks",
    TASK_SIZE_PARAMETER="/taskflow/api/task-size",
    TASK_SIZES=json.dumps([{"cpu": 256, "memory": 512}, {"cpu": 512, "memory": 768}]),
)

from botocore.stub import Stubber  # noqa: E402

import handler  # noqa: E402

OLD_ARN = "arn:aws:ecs:ap-south-1:123456789012:task-definition/api:1"
NEW_ARN = "arn:aws:ecs:ap-south-1:123456789012:task-definition/api:2"
CONTAINERS = [{"name": "api", "image": "repo:abc1234", "essential": True}]


def task_definition(cpu, memory, arn=OLD_ARN):
    return {
        "taskDefinitionArn": arn,
        "family": "api",
        "revision": 1,
        "status": "ACTIVE",
        "networkMode": "awsvpc",
        "requiresCompatibilities": ["EC2"],
        "compatibilities": ["EC2"],
        "requiresAttributes": [{"name": "ecs.capability.task-eni"}],
        "containerDefinitions": CONTAINERS,
        "cpu": cpu,
        "memory": memory,
    }


class HandlerTest(unittest.TestCase):
    def setUp(self):
        self.cloudwatch = Stubber(handler.cloudwatch)
        self.ecs = Stubber(handler.ecs)
        self.ssm = Stubber(handler.ssm)
        for stubber in (self.cloudwatch, self.ecs, self.ssm):
            stubber.activate()
            self.addCleanup(stubber.deactivate)

    def tearDown(self):
        self.cloudwatch.assert_no_pending_responses()
        self.ecs.assert_no_pending_responses()
        self.ssm.assert_no_pending_responses()

    def stub_service(self, deployments):
        self.ecs.add_response(
            "describe_services",
            {"services": [{"taskDefinition": OLD_ARN, "deployments": [{}] * deployments}]},
            {"cluster": "cluster", "services": ["api"]},
        )

    def test_steps_to_the_next_size(self):
        self.stub_service(deployments=1)
        self.ecs.add_response(
            "describe_task_definition",
            {"taskDefinition": task_definition("256", "512")},
            {"taskDefinition": OLD_ARN},
        )
        self.ecs.add_response(
            "register_task_definition",
            {"taskDefinition": task_definition("512", "768", NEW_ARN)},
            {
                "family": "api",
                "networkMode": "awsvpc",
                "requiresCompatibilities": ["EC2"],
                "containerDefinitions": CONTAINERS,
                "cpu": "512",
                "memory": "768",
            },
        )
        self.ssm.add_response(
            "put_parameter",
            {"Version": 2},
            {"Name": "/taskflow/api/task-size", "Value": '{"cpu":512,"memory":768}', "Overwrite": True},
        )
        self.ecs.add_response(
            "update_service", {}, {"cluster": "cluster", "service": "api", "taskDefinition": NEW_ARN}
        )

        self.assertEqual(handler.handler({}, None)["action"], "scaled")

    def test_stops_at_the_largest_size(self):
        self.stub_service(deployments=1)
        self.ecs.add_response(
            "describe_task_definition",
            {"taskDefinition": task_definition("512", "768")},
            {"taskDefinition": OLD_ARN},
        )

        self.assertEqual(handler.handler({}, None)["reason"], "largest size")

    def test_rearms_the_alarm_during_a_deployment(self):
        self.stub_service(deployments=2)
        self.cloudwatch.add_response(
            "set_alarm_state",
            {},
            {
                "AlarmName": "api-at-max-tasks",
                "StateValue": "OK",
                "StateReason": "Vertical scaler retrying after a deployment in progress",
            },
        )

        self.assertEqual(handler.handler({}, None)["action"], "deferred")


if __name__ == "__main__":
    unittest.main()
