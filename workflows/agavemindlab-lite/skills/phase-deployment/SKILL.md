---
name: phase-deployment
description: Merge only when approved, verify after merge, and publish a concise Deployment artifact.
---

# Deployment

Goal: land the approved PR and verify the result.

Do:
- Enter only when the issue is in `Merging` and the implementation is ready to merge.
- Read the latest `## Implementation` artifact and PR state.
- Use `symphony-land` for merge, CI watching, and post-merge verification.
- Publish `## Deployment` with conclusion, merge evidence, post-merge checks, and material risks.

If merge or verification is unsafe, stop and report the blocker instead of guessing.
