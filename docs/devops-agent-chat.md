# DevOps Agent chat

Details for the chat drawer in the local React dashboard. For the overview,
see the [README](../README.md#devops-agent-chat).

## Key terms

- **AgentSpace:** the DevOps Agent workspace the chat sends questions to. It
  defines which AWS accounts the agent may investigate.
- **Account association:** the link that lets an AgentSpace read an account,
  through a monitoring role with the `AIDevOpsAgentAccessPolicy` managed
  policy. The AgentSpace needs an association with the account that runs
  your pipelines.

This stack does **not** create the AgentSpace. You create it once, then pass
its ID to the dashboard stack.

## Enable the chat

1. **Create an AgentSpace** in the same account and region as the
   `pipeline-dashboard` stack, and associate this account with it. Use the
   console guide,
   [Creating an Agent Space](https://docs.aws.amazon.com/devopsagent/latest/userguide/getting-started-with-aws-devops-agent-creating-an-agent-space.html),
   or the
   [CloudFormation guide](https://docs.aws.amazon.com/devopsagent/latest/userguide/getting-started-with-aws-devops-agent-getting-started-with-aws-devops-agent-using-aws-cloudformation.html).
   DevOps Agent is available in `us-east-1`, `us-west-2`, `ap-southeast-2`,
   `ap-northeast-1`, `eu-west-1` and `eu-central-1` (at time of writing).

2. **Find the AgentSpace ID.** It's shown in the DevOps Agent console. From
   the CLI:

   ```bash
   aws cloudcontrol list-resources \
     --type-name AWS::DevOpsAgent::AgentSpace \
     --query 'ResourceDescriptions[].Properties' --output text
   ```

3. **Redeploy the backend with the ID:**

   ```bash
   make deploy-cfn-dashboard DEVOPS_AGENT_SPACE_ID=<agent-space-id>
   ```

   The ID is stored as the stack's `DevOpsAgentSpaceId` parameter. Later
   `make deploy-cfn-dashboard` runs without `DEVOPS_AGENT_SPACE_ID` keep
   the current value.

4. **Check it's on.** The stack output `DevOpsAgentChat` reads
   `enabled (AgentSpace <id>)`:

   ```bash
   aws cloudformation describe-stacks --stack-name pipeline-dashboard \
     --query 'Stacks[0].Outputs[?OutputKey==`DevOpsAgentChat`].OutputValue' --output text
   ```

   Then open the dashboard, click **Ask DevOps Agent**, pick a pipeline and
   send a question.

## How it works

API Gateway HTTP APIs time out after 30 seconds, and investigations take
longer. So the chat returns a `chatId` right away, and the UI polls for the
answer:

```
POST /chat                                  (stats Lambda)
  ├─ no AgentSpace configured → 503 devops_agent_not_configured
  ├─ store { chatId, status: "processing" } in DynamoDB
  ├─ invoke the chat-worker Lambda asynchronously
  └─ return 202 { chatId }

chat-worker Lambda
  ├─ aidevops:GetAgentSpace    AgentSpace missing → devops_agent_not_configured
  ├─ aidevops:CreateChat       as the caller's IAM user ID
  ├─ aidevops:SendMessage      question + pipeline context; streamed response
  └─ store { status: "succeeded", answer } or { status: "failed", error }

GET /chat/{chatId}                          (stats Lambda)
  └─ return the stored state; the UI polls every 2 s, for up to 5 minutes
```

Both chat routes use `AWS_IAM` auth, like the rest of the API. The question
is sent with the selected pipeline's dashboard row (name, status, stages,
history) as context, capped at 20,000 characters.

## Why it isn't in the Amazon Quick app

The Quick connector is read-only. It calls only the JWT-authorized
`/connector/*` GET routes, and the Quick sandbox can't sign SigV4 requests
for the `AWS_IAM` chat routes. Adding the chat to Quick would need a
JWT-authorized chat route and a `POST` connector action. See
[`CONNECTOR_ROUTE_CONTRACT.md`](../cloudformation/dashboard-backend/CONNECTOR_ROUTE_CONTRACT.md#out-of-scope-for-v1).

## What the stack adds when enabled

| Resource | Purpose |
|---|---|
| DynamoDB table `pipeline-dashboard-chat` | Chat state. Encrypted at rest; records expire after 24 hours. |
| Lambda `pipeline-dashboard-chat-worker` | Calls DevOps Agent. 5-minute timeout. Automatic async retries are off, so a failure never starts a second billed investigation. |
| Worker IAM role | `aidevops:GetAgentSpace`, `aidevops:CreateChat` and `aidevops:SendMessage` on the configured AgentSpace ARN only, plus the chat table and its own log group. |
| Stats Lambda inline policy | Read and write the chat table; invoke the worker. |

## Troubleshooting

| What the chat shows | Cause | Fix |
|---|---|---|
| "AWS DevOps Agent isn't set up" | No `DevOpsAgentSpaceId` set, or the AgentSpace doesn't exist in this account and region | Create the AgentSpace or correct the ID, then redeploy with `DEVOPS_AGENT_SPACE_ID` |
| `devops_agent_sdk_unavailable` | The Lambda runtime's built-in boto3 doesn't include the `devops-agent` client | Package a newer boto3 with `lambda/chat_worker` |
| `AccessDeniedException` | The worker role can't reach the AgentSpace, or DevOps Agent isn't enabled in this region | Check the AgentSpace region and the worker role policy |
| `chat_timeout` | No answer within 5 minutes | Check the `/aws/lambda/pipeline-dashboard-chat-worker` logs |
| An answer that doesn't mention your resources | The AgentSpace has no association with this account | Associate the account in the AgentSpace |
