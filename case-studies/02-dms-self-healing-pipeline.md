# Building a Self-Healing AWS DMS Replication Pipeline

*TL;DR:* Cross-cloud replication tasks powering our data pipeline would silently drop into a failed state whenever the underlying network path had any transient interruption — scheduled maintenance windows, brief connectivity blips — requiring manual detection and restart every time. I designed a serverless self-healing system that detects failures, waits out a stability window, and automatically resumes tasks, cutting manual intervention by 95%.

## The Problem

Several AWS DMS (Database Migration Service) replication tasks keep data flowing continuously between environments for a high-volume fintech platform. Whenever the network path between environments had any transient disruption — a scheduled maintenance window, a brief connectivity blip — the affected DMS task would drop into a failed or stopped state and simply stay there. DMS doesn't reliably self-recover from this.

That meant every such event required a human to notice (often hours later, since nothing else necessarily alerted on it) and manually resume the task. In the meantime, replication was silently broken — a real risk for data consistency across environments, and an unnecessary source of on-call burden for something that should have been routine.

## Design Considerations

The naive fix — "just immediately restart any failed task automatically" — has a real trap: if the underlying network issue is still ongoing when the automatic restart fires, the task just fails again immediately, potentially thrashing in a restart loop rather than actually healing.

I also wanted the system to do more than just react to outright failures — a task that's technically still running but showing rising CDC (Change Data Capture) latency is an early warning sign of a brewing problem, and catching that before it becomes a full failure is far cheaper than reacting after the fact.

## The Solution

A lightweight, serverless Lambda function, triggered on a recurring EventBridge schedule (every few minutes), that does two distinct things:

*1. Self-healing for failed tasks* — for any monitored task in a failed/stopped state, checks how long it's been in that state. Only once it's been stable for a configured wait period (avoiding restart-loop thrashing into a still-unstable network) does it automatically resume the task using DMS's resume-processing mode — continuing from the last checkpoint, not a disruptive full reload.

*2. Proactive latency warnings for healthy tasks* — for tasks still reporting as healthy, pulls CDC latency metrics from CloudWatch and posts a Slack warning if latency exceeds a threshold, surfacing a brewing problem before it becomes an outage.

Every action taken and every warning raised posts directly to Slack — nothing happens silently.

python
def lambda_handler(event, context):
    for task in DMS_TASKS:
        task_info = get_task_status(task['arn'])
        status = task_info.get('Status')

        if status in FAILED_STATES:
            if is_stable_long_enough(task_info, STABILITY_WAIT_MINUTES):
                resume_task(task['arn'], task['name'])
        elif status in HEALTHY_STATES:
            latency = get_cdc_latency(task['arn'], task_info.get('ReplicationTaskIdentifier'))
            if latency and latency > CDC_LATENCY_WARNING_SECONDS:
                send_slack_alert(f"CDC latency warning for {task['name']}: {int(latency)}s")

(Full implementation in scripts/dms-self-healing-lambda.py)
The Outcome

95% reduction in replication failures requiring manual intervention
Zero-touch recovery from routine network maintenance windows that previously required a human to notice and act
Early-warning visibility into latency degradation before it becomes an outage, not just after

Broader Takeaways

Self-healing isn't the same as "always restart immediately." A stability window is what separates genuine healing from restart-loop thrashing — automating recovery without understanding the failure mode it's recovering from can make things worse, not better.
Proactive warnings are as valuable as reactive fixes. Catching rising latency before a task actually fails is consistently cheaper than responding to a full outage.
Serverless is the right shape for this kind of problem. A periodic, stateless health-check-and-remediate pattern doesn't need a dedicated always-on server — Lambda + EventBridge is lightweight, cheap, and exactly matches the actual workload shape.


Connect with me on LinkedIn if you're solving similar operational reliability problems.
