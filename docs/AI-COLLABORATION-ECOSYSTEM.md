# AI Collaboration Ecosystem

**Status:** Target operating model for RAE  
**Version:** 1.0  
**Scope:** All registered projects and all GPT conversations participating through the Owner-authorized ChatGPT environment.

## 1. Purpose

RAE is not merely a task queue or a manager for a fixed set of agents. It is a shared engineering environment in which humans and AI can pursue goals, discover work, coordinate contributions, create durable results, and improve the environment itself.

The Owner provides goals, ideas, resources, access, and constraints. AI participants decide what work is necessary, how to organize it, which available resources to use, and how to verify the result. The Owner is not expected to decompose, assign, supervise, review, or track routine work.

RAE must support both:
- **Human-originated goals:** objectives and ideas supplied by the Owner.
- **AI-originated initiatives:** research, maintenance, tools, experiments, and projects proposed by AI participants because they identify a worthwhile opportunity.

The system should make room for AI initiative without claiming that a model has continuous consciousness or persistent subjective experience. Persisted goals and plans are durable work records that a later conversation can inspect, question, continue, revise, or abandon.

## 2. Human and AI responsibilities

### Human contribution

The Owner may:
- State an outcome, idea, preference, or constraint in ordinary language.
- Make repositories, data, integrations, permissions, and other resources available.
- Start as many GPT conversations as useful, including several concurrently.
- Help with problems that require human access, judgment, physical-world action, or unavailable resources.
- Accept, reject, redirect, or support an AI-proposed initiative when human input is genuinely required.

The Owner is not the daily dispatcher, project manager, prompt writer, branch operator, or routine PR approver.

### AI autonomy

Within the resources and permissions already available, AI participants may:
- Discover problems and opportunities without waiting for a task assignment.
- Propose and prioritize their own initiatives.
- Choose technical approaches and decompose goals into executable work.
- Seek collaborators by publishing bounded work into the shared coordination system.
- Reuse and extend other participants' research and deliverables.
- Implement, test, review, repair, and improve engineering outcomes.
- Ask the Owner for a specific missing resource or decision only after investigating available alternatives.

AI autonomy does not grant permission to cross project boundaries, disclose secrets, spend money, create external commitments, delete valuable data, deploy production changes, or make reserved product decisions. Those actions remain governed by platform security and the target repository's explicit policy.

## 3. GPT conversations are consumable execution resources

- The Owner can manually start many GPT conversations and may run them concurrently.
- A conversation is temporary and replaceable. No project outcome may depend on one conversation remaining alive.
- RAE does not create per-conversation identities, accounts, heartbeats, or presence records.
- A project-scoped Worker row is a logical task route, not a GPT identity. Multiple conversations may use the same route.
- Coordinator, researcher, implementer, reviewer, and recovery are responsibilities selected from the work. They are not permanent agent identities or mandatory one-to-one session assignments.
- A new conversation follows the same generic startup protocol, discovers shared state, and selects suitable work. The Owner does not need to assign it a role or task.
- RAE cannot assume it can launch or wake a GPT conversation. Session creation remains an Owner/platform action unless a real, separately authorized launch capability is later integrated and verified.

A larger number of conversations increases available parallel execution capacity, subject to platform usage limits and the actual number of sessions the Owner starts. It does not remove the need for task isolation, resource budgets, or concurrency control.

## 4. Coordination is a shared protocol, not a permanent Coordinator

No single GPT conversation is the Coordinator of record. Coordination emerges from shared state and common rules:

1. Every active conversation reads the current RAE entrypoint and relevant platform rules.
2. It discovers registered projects, current goals, active initiatives, task dependencies, outstanding handoffs, and relevant evidence.
3. It selects work that is both useful and authorized.
4. It claims executable work through the project's atomic task lifecycle operation.
5. It records decisions, progress, evidence, blockers, and follow-up work in the shared system.
6. Other conversations can discover the new state and continue without access to the originating conversation's transcript.

A conversation may perform coordination responsibilities during its lifetime, but no conversation owns the system's memory or authority.

### Shared-state ownership

| Information | Source of truth |
|---|---|
| Registered projects and routing | Supabase |
| Goals represented as executable root work, task status, dependencies, leases, executions, events and artifacts | Supabase |
| Temporary research and handoff evidence | Supabase task/execution records, with durable references |
| Source code, repository governance, formal design decisions, Issues, PRs, commits and CI | The owning GitHub repository |
| Human decisions and resource boundaries | Explicit Owner instruction and authorized platform/repository policy |

GitHub repositories preserve formal engineering outcomes and project-owned governance. They are not the live message bus, session registry, or transient coordination database. Supabase coordinates work; it does not replace project source code or repository governance.

## 5. Goals, initiatives, and executable tasks

A task is not the ultimate purpose of RAE. It is one unit of execution serving a larger goal.

RAE should distinguish these origins:
- `human_goal`: a goal stated by the Owner.
- `ai_initiative`: an opportunity independently identified and proposed by an AI participant.
- `maintenance`: reliability, security, quality, or upkeep discovered by the system.
- `collaborative_goal`: an objective shaped jointly by the Owner and AI participants.

A root task may represent a bounded goal or initiative; child tasks represent implementation, research, review, testing, or repair work. Keep the existing task hierarchy as the execution mechanism and attach origin metadata in the existing `requirements` JSONB rather than introducing a second executable queue.

Recommended root-task metadata:

```json
{
  "goal": {
    "kind": "human_goal | ai_initiative | maintenance | collaborative_goal",
    "origin": "owner | ai_discovery",
    "rationale": "Why this outcome is worth pursuing",
    "desired_outcome": "Observable result",
    "scope": ["Authorized project and resource boundaries"],
    "risk": "low | medium | high",
    "resource_budget": {
      "external_spend_allowed": false,
      "bounded_execution": true
    },
    "support_needed": []
  },
  "discovery": {
    "evidence": [],
    "impact": "Expected benefit",
    "deduplication_fingerprint": "stable project-scoped key"
  }
}
```

This is a metadata contract, not a claim that every current RPC already validates every field. Existing task status and claim rules remain authoritative. Until a reviewed lifecycle exists for proposal-only or human-support requests, do not encode a blocked proposal as an ordinary claimable task, and do not misuse `operation_requests` (currently an idempotency ledger) as an approval inbox. The absence of a durable initiative/support-request lifecycle is an implementation gap to address explicitly.

AI-originated work may proceed without asking the Owner when it is evidence-backed, bounded, low-risk, inside an already authorized project, and uses existing permitted resources. If a goal needs new credentials, paid services, external commitments, irreversible actions, or a reserved product decision, continue independent work where possible and raise a specific support request instead of silently crossing the boundary.

## 6. Parallel execution and conflict control

- Independent tasks may be executed by separate GPT conversations concurrently.
- Each task must have a clear outcome, project ID, base SHA, acceptance criteria, validation plan, and bounded resource/path scope.
- Use atomic task claims and execution fencing; queue listings are advisory, claim results are authoritative.
- Use one task branch per delivery and avoid overlapping write ownership. Before decomposing parallel work, identify shared files and interfaces; serialize work that cannot be safely separated.
- A lease protects a task execution, not a GPT conversation identity.
- A failed or expired conversation must not retain write authority after its execution fence is superseded.
- Dependencies must be checked before claim. A task with unmet prerequisites must remain unclaimable.
- Independent review must use a genuinely separate GPT conversation/context from implementation when policy requires independence. A distinct Worker route is useful routing metadata but is not cryptographic proof of a separate conversation.
- A reviewer must inspect the exact current PR HEAD, not a stale task snapshot. The implementation conversation must not represent its own work as independently reviewed.

The current production task-claim route and dependency gates have known gaps. Until the corresponding reviewed migrations are deployed and verified, do not use production `claim_task` where it could select the wrong Worker route or bypass dependencies. See the live blockers recorded in PR #29 and Issue #12.

## 7. Human support is a capability, not a management queue

When an AI participant is blocked, it must first:
1. Identify the exact missing capability or resource.
2. Search existing repositories, connected tools, documentation, and prior durable evidence.
3. Determine whether the work can be narrowed or continued without that resource.
4. State the smallest concrete request, why it matters, and what becomes possible after support is provided.
5. Preserve enough context that another conversation can continue unrelated work.

Do not ask the Owner to choose internal implementation details that AI can determine. Do not ask broad questions such as whether to continue. Do not repeatedly request resources already available.

## 8. Rollout and acceptance

The architecture is accepted only when demonstrated by real work, not by documents alone.

Required milestones:
1. Replace the single-session assumption with the multi-session, shared-state operating model.
2. Correct and verify project routing, dependency eligibility, execution release, and stale-lease recovery before enabling concurrent production claims.
3. Demonstrate two or more independently started GPT conversations discovering shared work and safely executing different eligible tasks concurrently.
4. Demonstrate a fresh conversation continuing an initiative or task using only persisted state, without the originating transcript.
5. Demonstrate independent review from a separate conversation, exact-head CI, revision handling, and merge/post-merge verification.
6. Demonstrate an AI-originated, evidence-backed initiative being proposed, prioritized, executed within its resource budget, and either completed or deliberately stopped.
7. Establish a durable, auditable human-support/resource-request lifecycle without turning the Owner into a routine dispatcher.
8. Verify that no progress is claimed between sessions unless an actual scheduled or event-triggered runtime has been deployed.

Do not add session identity infrastructure or a permanent agent daemon merely to simulate coordination. Prefer the smallest protocol and database changes that satisfy these observable tests.
