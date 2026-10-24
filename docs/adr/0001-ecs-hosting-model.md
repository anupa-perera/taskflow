# 0001. Host ECS on EC2 instances rather than Fargate

- Status: Accepted
- Date: 2026-10-24

## Context

TaskFlow runs as containers on Amazon ECS, which offers two capacity models:

- **Fargate**: AWS runs the hosts. You pay per task for vCPU and memory, and there is no host for
  you to reach, patch or configure.
- **EC2**: tasks run on an Auto Scaling Group of ECS-optimized instances that you own, configure
  and pay for whether or not they are full.

Our platform separates two concerns on purpose:

- **Infrastructure as code (Terraform)** decides _what exists_: the network, the cluster, the
  instances, the database.
- **Configuration management (Ansible)** decides _how each host behaves_: Docker and ECS agent
  settings, the CloudWatch agent that ships host logs, and OS hardening such as automatic security
  updates, a minimal firewall and key-only SSH. All of it applied idempotently from version control.

That second layer needs hosts to act on. We want host configuration to be explicit, reviewable and
repeatable rather than whatever a managed platform chooses, and we want host-level evidence for
incidents such as tasks stuck in `PENDING`. Fargate hides the host, so it would leave configuration
management with nothing to configure.

## Decision

Run the service on **ECS with the EC2 launch type**:

- An Auto Scaling Group of ECS-optimized Amazon Linux 2023 instances (2 × `t3.small` minimum, one
  per AZ, up to 4) in the private subnets. The service places tasks through a
  `capacity_provider_strategy` on a **capacity provider with managed scaling**, rather than
  `launch_type = "EC2"`, so ECS adds instances when tasks cannot be placed.
- **`awsvpc` network mode**: every task gets its own network interface and security group, so RDS
  admits only the task security group and the ALB targets task IPs directly.
- Instances are configured in two layers. Launch-template user data does only what an instance needs
  to join the cluster. Ansible owns everything else, and must also reach instances the ASG launches
  later, without anyone running a playbook by hand; that mechanism is part of the configuration
  management design.

## Consequences

- **Configuration is a first-class, versioned layer**: hosts are rebuilt the same way every time,
  and a playbook run that reports no changes is evidence that they match the code.
- **We own the hosts**: AMI updates, OS patching, the ECS agent version and instance right-sizing are
  our responsibility. If host-level control stops being a requirement, Fargate becomes the simpler
  choice.
- **Two scaling layers** must be kept consistent: task-level scaling (ECS Service Auto Scaling and the
  vertical-scaling mechanism) and instance-level scaling (the capacity provider). Adding instances
  fixes a lack of room, but not everything:
  - a task whose CPU or memory exceeds what a single `t3.small` can offer is never placed (it waits
    in `PROVISIONING` or `PENDING`) no matter how many instances exist, so every task size must fit
    the smallest instance type;
  - managed scaling stops at the ASG maximum of 4 instances.
- **Task density is limited by network interfaces**, not just CPU and memory: with `awsvpc`, each
  `t3.small` has 3 interfaces, one used by the host, so at most 2 tasks fit per instance. This is a
  documented cause of `PENDING` tasks in the runbook.
- **Cost is paid for idle capacity**: the two instances cost about $1.08/day even with no traffic,
  where Fargate would charge only for running tasks.
- **Availability is improved, not complete**: one instance per AZ means losing an instance or an AZ
  does not stop every task. The single NAT gateway and single-AZ RDS instance remain single points of
  failure (see the README's non-goals).
- **Debugging has a host to stand on**: on-call engineers can reach an instance through SSM Session
  Manager and use `docker logs` and `docker inspect`, which matters because the distroless image has
  no shell (ADR 0003).
