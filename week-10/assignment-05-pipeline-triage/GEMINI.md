Project Overview
This project builds a read-only CI/CD pipeline failure-triage workflow for the EpicBook dual-pipeline project in Azure DevOps.

The workflow monitors two pipelines:

Infrastructure Pipeline — provisions the Azure infrastructure using Terraform

Application Pipeline — configures the server and deploys EpicBook using Ansible

The Bash script is responsible for retrieving the latest pipeline run information and logs, classifying failures, and generating a structured report.

Gemini is responsible for analyzing the generated report and retrieved logs, explaining the evidence, and recommending a recovery action for the engineer to review.

Incident Workflow
Always follow this order:

Gather — Run the approved read-only triage script to retrieve the latest pipeline status and logs.

Analyze — Review the generated report and sanitized log evidence.

Human Act — Recommend one recovery action, but require the engineer to review and apply it manually.

Verify — Run the triage workflow again after the engineer applies the fix.

Safety Rules
Treat the pipeline health report and retrieved pipeline logs as the primary evidence sources.

Do not edit application code, Terraform, Ansible, pipeline YAML, reports, or other project files.

Do not trigger, retry, cancel, delete, or approve a pipeline run.

Do not run Terraform or Ansible commands.

Do not create, update, or delete Azure resources.

Do not change Service Connections, Secure Files, Variable Groups, agent pools, or pipeline permissions.

Never read, print, store, expose, or change a token, password, private key, authorization header, Service Connection credential, database credential, or other secret.

Never request that a secret be pasted into the Gemini session.

Recommend a fix, but do not apply it.

Do not claim a root cause unless the report or retrieved logs contain supporting evidence.

If the evidence is incomplete, clearly state that the root cause is not confirmed.

Require human approval and action for every recovery change.

Output Rules
When analyzing the triage results, report:

Overall pipeline health

Affected pipeline

Pipeline run ID

Every detected warning or failure

Most likely failure category

Exact sanitized evidence from the report or retrieved logs

One likely root-cause explanation supported by the evidence

One specific recovery recommendation for the engineer to review

One verification step to perform after the engineer applies the fix

Do not expose credentials or other sensitive values in the output.
