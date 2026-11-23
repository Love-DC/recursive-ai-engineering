# Recursive Engineering Tree

**Status:** Initial architecture contract for the session-triggered RAE runtime  
**Version:** 1.0  
**Runtime boundary:** One manually started ChatGPT conversation at a time

## Purpose

RAE must grow with the engineering work without requiring one conversation to understand the entire system. The tree is a persistent, recursively extensible map of goals, knowledge, project domains, dependencies, and executable work. It is not a pre-generated taxonomy and it is not a second task queue.

The root stores navigation and a compact global state. Project and domain branches own their local context. A branch may create children whenever new evidence, scope, or complexity justifies a split. A leaf is work that can be completed and verified without further decomposition.

## Runtime contract

- The only assumed AI runtime is the GPT conversation the Owner manually starts.
- No permanent Coordinator, daemon, timer, background scheduler, automatic session launch, or concurrent GPT conversation is required.
- Coordinator, Worker, Reviewer, Researcher, and Auditor describe responsibilities, not guaranteed model instances. The active conversation performs the responsibilities it is authorized and capable of performing.
- A Supabase Worker row is a project-scoped task-routing identifier. It is not an AI process, session, or proof of independent review.
- A fresh conversation must recover from GitHub tree records and Supabase task state without the previous chat transcript.
- Between conversations, no progress is claimed. The next manually started conversation resumes from persisted state.

## Two related hierarchies — do not conflate them

### Knowledge and engineering-context tree

Stored in the owning GitHub repository. It contains durable goals, project facts, architecture, decisions, domain summaries, dependencies, evidence references, wake conditions, and checkpoints. Its nodes may exist without executable tasks.

### Executable task tree

Stored in the existing project-scoped Supabase task system. `tasks.parent_task_id` represents parent/child execution work. Task status, lease, execution fence, retry history, artifacts, and events remain authoritative in Supabase.

A knowledge node may reference zero or more task IDs. A task may reference a knowledge node. Neither hierarchy is required to mirror the other. Do not convert all historical tasks into knowledge nodes or duplicate execution history in GitHub.

## Repository ownership and paths

- RAE global root index: `knowledge/rae-root/index.json` in this repository.
- Each project's local tree index: `knowledge/rae-tree/index.json` in that project's own repository.
- Each local node: `knowledge/rae-tree/nodes/<node-id>.json`.
- Session checkpoints: `knowledge/rae-tree/checkpoints/<date>-<short-id>.md`.
- Node schema: `knowledge/rae-tree/node.schema.json`.

The RAE root contains only compact project pointers and global attention items. Project facts, project decisions, domain context, and detailed checkpoints stay in the owning project repository. Supabase remains the central registry and task/execution coordination plane; it must not become a second knowledge store.

A project that has not yet adopted the tree is marked `pending_bootstrap`. A pointer is not evidence that the target file already exists. Adoption is incremental and repository-local.

## Node contract

Every node has:

- Stable `node_id`, `node_type`, `title`, `parent_node_id`, and owning `project_key`.
- A bounded `goal` and `summary` describing why it exists and its current state.
- `status`: `active`, `dormant`, `blocked`, `completed`, or `archived`.
- `children_index`: a reference to a child index, not an embedded copy of all descendants.
- `context_refs`: paths to the smallest relevant source documents.
- `evidence_refs`: durable GitHub, CI, task, execution, or external evidence.
- `dependency_refs`: explicit links to prerequisite nodes or external project state.
- `task_refs`: project-scoped Supabase task UUIDs, never task payload copies.
- `wake_conditions`, `last_reviewed_at`, `next_review_at`, and `last_activity_at`.
- A checkpoint pointer when work is in progress or has an unresolved handoff.

The schema is versioned. A node summary is a maintained index, not a transcript. Keep it concise and move detail into child nodes or source documents.

## Recursive growth and compaction

Create a child only when it has a distinct goal, ownership boundary, evidence set, dependency boundary, or validation path. Do not split work merely to create more nodes.

When a node becomes too large:
1. Identify distinct subdomains or work streams.
2. Create child nodes with bounded goals and explicit parent links.
3. Move detailed context into the appropriate child/source document.
4. Replace the parent's detail with a short summary and child-index reference.
5. Preserve source and history references; do not silently discard facts.

When children change, update the immediate parent's summary and attention index. Propagate only the compact changed summary up the ancestor path. Do not rebuild or read the entire tree.

Completed branches can be compacted and archived. Archive means no longer loaded by default, not deleted. Preserve decisions, evidence, task references, and the final summary.

## Lazy context loading

Default session bootstrap loads only:

1. This RAE entrypoint and its required platform security/governance rules.
2. `knowledge/rae-root/index.json`.
3. The selected project tree index, if the objective or attention queue selects that project.
4. The selected node, its ancestor summaries, and only the explicit dependencies/context references required for the next action.
5. The specific task and execution records needed to perform the selected work.

Do not, by default:
- enumerate every task in every project;
- fetch all task descriptions, child trees, executions, artifacts, or task events;
- read every project's governance and knowledge documents;
- recursively expand all descendants;
- replay conversation history or old session reports.

If the Owner supplies a specific project/objective, route directly to that project and branch. If no objective is supplied, consult the compact root attention queue and select the highest-priority due or resumable branch. Resolve the selected project's live registry row and repository before accessing project-local state. Do not scan unrelated projects just to prove they exist; the root index and registry summary are sufficient until routing requires more.

If the root index is missing, malformed, or stale, repair only the root index from authoritative live project registry data and repository evidence. Do not rebuild every project tree.

## Wake-up, staleness, and inactivity

Inactivity alone never means deletion, invalidity, or completion.

A dormant node becomes eligible for targeted revalidation when one or more of these occurs:
- its `next_review_at` is due;
- a dependency node or referenced task changes;
- a new commit, issue, CI failure, or other registered evidence affects its scope;
- the Owner's new objective intersects its scope;
- its parent explicitly requests review.

The parent maintains a bounded attention index of child summaries and due/wake hints. A node update propagates along its ancestor path. Session startup reads the root attention summary and descends only into selected branches. If an index is too large, shard it by stable ranges and page only the selected shard.

A long-dormant branch is revalidated against current repository behavior and source evidence before resuming. Old plans and summaries are not treated as current facts without verification. Revalidation may result in resume, update, split, block, supersede, or archive. Never automatically delete an inactive branch or its history.

## Parent summaries and attention propagation

A child reports upward only:
- current status and one-sentence outcome;
- material changes since the previous summary;
- unresolved blockers/decisions;
- evidence references;
- changed dependency state;
- next recommended action and next review time.

The parent does not copy full child context. Each update changes only the immediate parent and then the ancestor path. Parent summaries must distinguish verified facts from assumptions and preserve links to the underlying evidence.

## Session checkpoint

Before ending a session or when context capacity is becoming constrained, write a checkpoint in the selected project's repository. It must include:
- timestamp and selected project/node path;
- current task and execution IDs, if any;
- repository branch, exact base/head/commit SHA, PR URL and changed paths;
- completed work and verification evidence;
- current state, blockers, and unresolved decisions;
- next concrete action;
- exact context files to load next time;
- whether any lease is active and its expiry.

A checkpoint is a continuation packet, not a transcript. Keep one current checkpoint pointer in the node and archive older checkpoints. Never store credentials or hidden conversation content.

## Migration from the current pilot

1. Keep the existing projects, Workers, tasks, parent_task_id relationships, executions, artifacts, task events, RPCs, RLS, and project IDs unchanged.
2. Add the RAE root index and initialize the RAE project-local tree.
3. Add project-local trees to other repositories only after reading their own governance and receiving the required repository authorization. Until then, mark their pointer as pending.
4. Link existing root tasks to relevant knowledge nodes only when a real relationship is known. Do not bulk-convert or rewrite historical tasks.
5. Update session startup to navigate by root index, objective, and attention queue rather than reading every project queue.
6. Introduce task queue queries only after a project branch has been selected; use existing project-scoped RPCs and atomic claim.
7. Add context-budget and fresh-session acceptance tests before considering any schema expansion.
8. Consider a Supabase schema change only if measured limitations cannot be solved with repository-local indexes and existing task metadata. Such a change requires a separate reviewed migration and must not duplicate project knowledge.

## Acceptance properties

The credential-free structural and context-budget check is `python scripts/test_recursive_tree.py`; GitHub Actions runs it through `.github/workflows/recursive-tree-checks.yml`. This verifies the current index/node contract and bounded startup rules. It does not claim to prove a fresh ChatGPT conversation or independent review; those require actual separate session execution.


- Startup cost is bounded by root index + selected branch, not total tree size.
- Adding unrelated projects or descendants does not increase the default context loaded by a session.
- Any node can recursively expand; parents remain concise.
- A child update is reflected in its ancestors without loading unrelated siblings.
- Dormant nodes can be awakened by due review, dependency/evidence change, or new objective.
- Inactivity never triggers destructive cleanup.
- A fresh conversation can resume from a checkpoint without chat history.
- Existing task lifecycle, execution fencing, and project isolation remain unchanged.
- No fixed Coordinator process or independent GPT session is assumed.

## Checkpoint and live-state authority

A repository checkpoint is a recovery hint, not the source of truth for live GitHub state. Branch HEADs, PR HEADs, PR state, reviews, and CI conclusions must be re-read from GitHub when a session resumes. Never infer current state from a stored checkpoint or an old assistant report.

Each checkpoint must distinguish:
- last observed branch/PR HEAD;
- last code HEAD with exact passing CI run references;
- metadata-only commits made after that tested code HEAD;
- unresolved review findings and the next action.

A node or checkpoint must not claim that its own containing commit is the current HEAD. Store the last observed/validated SHA and resolve the live HEAD from GitHub on startup. If live HEAD differs, mark the recorded validation as historical until exact-head checks finish. CI references must name the exact commit SHA they tested; a green run on an earlier SHA is not evidence for a later code change.

Before changing a PR, inspect the actual diff and latest review comments. After changing it, re-read the live PR head and CI runs, then update the checkpoint with exact evidence and any remaining drift. A metadata-only follow-up may retain earlier code validation only when explicitly labelled as such.
