`python
import boto3
import json
import urllib.request
import urllib.error
import os
import logging
from datetime import datetime, timezone, timedelta

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get('REGION', 'eu-west-2')
STABILITY_WAIT_MINUTES = int(os.environ.get('STABILITY_WAIT_MINUTES', '15'))
CDC_LATENCY_WARNING_SECONDS = int(os.environ.get('CDC_LATENCY_WARNING_SECONDS', '3600'))
SLACK_WEBHOOK_URL = os.environ.get('SLACK_WEBHOOK_URL')

# Example structure - replace with your own monitored tasks
DMS_TASKS = [
    {'arn': 'arn:aws:dms:eu-west-2:ACCOUNT_ID:task:EXAMPLE1', 'name': 'Example Replication Task', 'description': 'source-to-target-example'},
]

HEALTHY_STATES = ['running', 'replication-ongoing', 'ongoing-replication']
FAILED_STATES = ['failed', 'stopped']

dms_client = boto3.client('dms', region_name=REGION)
cloudwatch = boto3.client('cloudwatch', region_name=REGION)


def send_slack_alert(message):
    if not SLACK_WEBHOOK_URL:
        logger.warning("No Slack webhook configured, skipping alert: %s", message)
        return
    payload = json.dumps({'text': message}).encode('utf-8')
    req = urllib.request.Request(SLACK_WEBHOOK_URL, data=payload, headers={'Content-Type': 'application/json'})
    try:
        urllib.request.urlopen(req, timeout=5)
    except urllib.error.URLError as e:
        logger.error("Failed to post to Slack: %s", e)


def get_task_status(task_arn):
    response = dms_client.describe_replication_tasks(
        Filters=[{'Name': 'replication-task-arn', 'Values': [task_arn]}]
    )
    tasks = response.get('ReplicationTasks', [])
    return tasks[0] if tasks else None


def is_stable_long_enough(task_info, wait_minutes):
    stop_date = task_info.get('ReplicationTaskStats', {}).get('StopDate')
    if not stop_date:
        return True
    minutes_stopped = (datetime.now(timezone.utc) - stop_date).total_seconds() / 60
    return minutes_stopped >= wait_minutes


def get_cdc_latency(task_arn, task_id):
    end_time = datetime.now(timezone.utc)
    start_time = end_time - timedelta(minutes=10)
    metrics = cloudwatch.get_metric_statistics(
        Namespace='AWS/DMS',
        MetricName='CDCLatencyTarget',
        Dimensions=[{'Name': 'ReplicationTaskIdentifier', 'Value': task_id}],
        StartTime=start_time,
        EndTime=end_time,
        Period=300,
        Statistics=['Maximum']
    )
    datapoints = metrics.get('Datapoints', [])
    if not datapoints:
        return None
    return max(datapoints, key=lambda d: d['Timestamp'])['Maximum']


def resume_task(task_arn, task_name):
    try:
        dms_client.start_replication_task(
            ReplicationTaskArn=task_arn,
            StartReplicationTaskType='resume-processing'
        )
        send_slack_alert(f":arrows_counterclockwise: Self-healing: resumed DMS task {task_name} after detecting a failed state.")
    except Exception as e:
        send_slack_alert(f":x: Self-healing FAILED to resume DMS task {task_name}: {str(e)}")


def lambda_handler(event, context):
    results = []
    for task in DMS_TASKS:
        task_info = get_task_status(task['arn'])
        if task_info is None:
            continue

        status = task_info.get('Status')

        if status in FAILED_STATES:
            if is_stable_long_enough(task_info, STABILITY_WAIT_MINUTES):
                resume_task(task['arn'], task['name'])
        elif status in HEALTHY_STATES:
            latency = get_cdc_latency(task['arn'], task_info.get('ReplicationTaskIdentifier'))
            if latency is not None and latency > CDC_LATENCY_WARNING_SECONDS:
                send_slack_alert(f":warning: DMS task {task['name']} CDC latency is {int(latency)}s, exceeding threshold.")

        results.append({'task': task['name'], 'status': status})

    return {'statusCode': 200, 'body': json.dumps(results)}
