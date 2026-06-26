# Requirements Document

## Introduction

Today the dashboard surfaces CodePipeline status visually, but a failed
pipeline only gets noticed when someone is looking at the UI. This feature
adds proactive notifications: when a CodePipeline run fails (or recovers)
in any tracked account, an alert is published to SNS and fanned out to
Slack and/or email. Operators can tune noise by attaching a severity to
each pipeline — high-severity pipelines page on every failure, low-severity
ones only alert on repeated failures.

**Defaults assumed in this draft** (call out anything to change):

- Channels: SNS topic with both **email** and **Slack** subscriptions supported.
- Severity model: per-pipeline via an AWS resource **tag** (`AlertSeverity = high|medium|low`), with `medium` as the default.
- Origin: alerts fire from the **central account** by consuming EventBridge events forwarded from each tracked account. This keeps the existing `cross-account-reader` pattern.

## Glossary

- **AlertEvent**: A structured event emitted by the alerting system in response to a CodePipeline state transition. Contains pipeline name, account ID, region, execution ID, failed stage, timestamp, and event type (e.g. `FAILED`, `RECOVERY`, `HEARTBEAT_LOST`).
- **AlertSeverity tag**: An AWS resource tag (`AlertSeverity`) applied to a CodePipeline pipeline whose value (`high`, `medium`, or `low`) drives the routing and suppression decision for that pipeline's alerts. Defaults to `medium` when missing or unrecognized.
- **Tracked account**: An AWS account that has been onboarded via `make track-account` and forwards CodePipeline events to the central account's event bus.
- **Central account**: The AWS account that hosts the alerting system (SNS topic, Slack Lambda, central EventBridge bus) and consumes events from all tracked accounts.
- **SNS topic**: The central Amazon SNS topic in the central account to which `AlertEvent` payloads are published and from which email and Slack subscribers receive messages.
- **RECOVERY**: An `AlertEvent` type emitted when a pipeline's most recent execution transitions to `SUCCEEDED` after a previous `FAILED` execution.
- **HEARTBEAT_LOST**: An `AlertEvent` type emitted when a previously active tracked account has sent no events for 24 hours, indicating event forwarding may be broken.
- **EARS**: Easy Approach to Requirements Syntax — the patterned phrasing used for acceptance criteria in this document (e.g. `WHEN … THE … SHALL …`).

## Requirements

### Requirement 1: Detect pipeline failures across tracked accounts

**User Story:** As an on-call engineer, I want pipeline failures in any tracked AWS account to be detected within seconds, so that I can react before customers notice.

#### Acceptance Criteria

1. WHEN a CodePipeline execution in a tracked account transitions to state `FAILED` THEN the system SHALL emit an `AlertEvent` containing pipeline name, account ID, region, execution ID, failed stage, and timestamp within 60 seconds of the state change.
2. WHEN a CodePipeline execution transitions to state `SUCCEEDED` AND the previous execution for the same pipeline was `FAILED` THEN the system SHALL emit a recovery `AlertEvent` of type `RECOVERY`.
3. WHEN a CodePipeline execution transitions to `SUPERSEDED` or `CANCELED` THEN the system SHALL NOT emit any alert.
4. IF a tracked account stops forwarding events (no events received for 24 hours from an account that previously sent events) THEN the system SHALL emit one `HEARTBEAT_LOST` alert and SHALL NOT repeat it until events resume.

### Requirement 2: Severity rules per pipeline

**User Story:** As a platform owner, I want to assign a severity to each pipeline so that noisy non-prod pipelines don't drown out real prod incidents.

#### Acceptance Criteria

1. WHEN evaluating an `AlertEvent` THEN the system SHALL read the `AlertSeverity` tag from the source pipeline AND map its value (`high`, `medium`, `low`) to a routing decision.
2. IF the `AlertSeverity` tag is missing or has an unrecognized value THEN the system SHALL default to `medium`.
3. WHEN severity is `high` THEN the system SHALL deliver the alert on the **first** failure.
4. WHEN severity is `medium` THEN the system SHALL deliver the alert on the **first** failure but suppress duplicate `FAILED` events for the same pipeline within a 15-minute window.
5. WHEN severity is `low` THEN the system SHALL deliver the alert only after **2 consecutive** `FAILED` executions for the same pipeline.
6. WHEN severity is any value THEN the system SHALL always deliver `RECOVERY` alerts (no suppression).

### Requirement 3: Slack and email delivery via SNS

**User Story:** As an operator, I want failure alerts in Slack and email so that I see them where I already work.

#### Acceptance Criteria

1. WHEN an `AlertEvent` passes severity rules THEN the system SHALL publish a message to a central SNS topic with the event payload as JSON.
2. WHEN the SNS topic receives a message THEN it SHALL fan out to (a) an email subscription list and (b) a Slack webhook via a Lambda subscriber.
3. WHEN the Slack subscriber posts a message THEN the message SHALL include pipeline name, account alias, severity, failed stage, a link to the CodePipeline console, and (for `RECOVERY`) a green check indicator.
4. IF the Slack webhook returns a non-2xx response THEN the subscriber SHALL retry up to 3 times with exponential backoff AND SHALL log the failure to CloudWatch Logs.
5. WHEN an email is delivered THEN it SHALL include the same fields as the Slack message in plain text plus a console link.

### Requirement 4: Configuration and onboarding

**User Story:** As an operator adding a new account or pipeline, I want alerts to start working without bespoke setup, so that onboarding stays a single `make` command.

#### Acceptance Criteria

1. WHEN `make track-account` succeeds THEN the reader role in the target account SHALL include permission to put events on the central event bus.
2. WHEN a new CodePipeline is created in a tracked account with no `AlertSeverity` tag THEN the system SHALL still alert it at the default `medium` severity (Requirement 2.2).
3. WHEN an operator runs `make deploy-alerts EMAIL=ops@example.com SLACK_WEBHOOK=https://hooks.slack.com/...` THEN the central SNS topic and Slack Lambda SHALL be provisioned or updated AND existing subscriptions SHALL not be duplicated.
4. WHEN an operator runs `make disable-alerts` THEN inbound alerting SHALL stop within 1 minute AND no Terraform state SHALL be destroyed (only the EventBridge rule is disabled).

### Requirement 5: Observability of the alerting system itself

**User Story:** As a platform owner, I want to know when the alerting pipeline itself is broken, so that silent failures don't go undetected.

#### Acceptance Criteria

1. WHEN any Lambda in the alerting path errors THEN it SHALL emit a CloudWatch metric `AlertingErrors` AND a CloudWatch alarm SHALL fire if errors exceed 5 in 5 minutes.
2. WHEN the central event bus rejects an event from a tracked account THEN the rejection SHALL be logged with the source account ID and pipeline name.
3. WHEN the dashboard `/accounts` endpoint is queried THEN each account entry SHALL include `last_alert_event_at` so operators can confirm an account is still reporting.

### Requirement 6: Security and least privilege

**User Story:** As a security reviewer, I want the alerting system to follow the same least-privilege patterns as the existing reader role, so that adding this feature doesn't widen our blast radius.

#### Acceptance Criteria

1. WHEN the reader role in a tracked account is updated for alerting THEN it SHALL only gain `events:PutEvents` on the central event bus ARN AND SHALL NOT gain any new read scope on CodePipeline.
2. WHEN the central account creates the cross-account event bus policy THEN it SHALL scope the `Principal` to the explicit list of tracked account IDs (no wildcards).
3. WHEN the Slack webhook URL is stored THEN it SHALL be held in AWS Secrets Manager (or SSM SecureString) AND SHALL NOT appear in Terraform state in plaintext, Lambda environment variables in plaintext, or CloudWatch logs.

## Out of scope (for v1)

- PagerDuty/Opsgenie integration (SNS extensibility leaves room for this later).
- Per-stage alerts (only pipeline-level FAILED/SUCCEEDED transitions trigger alerts in v1).
- Mobile push or SMS.
- Historical alert search UI in the dashboard (handled by CloudWatch Logs Insights for now).
