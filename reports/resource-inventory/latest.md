# Cross-project resource inventory

- Generated: 2026-11-23T01:42:00Z
- Current repository: Love-DC/recursive-ai-engineering
- Mode: read-only inventory; dry-run by default
- Registered active projects: 2
- GitHub branches: 281
- Open PR references: 29
- Supabase projects: 2
- Eligible batch candidates: 0
- Owner decision required: 250
- Preserved / blocked / inventory-only: 62

## Project inventory

| Project | Repository | Branches | Open PRs |
|---|---|---:|---:|
| colony-sim | Love-DC/colony-sim | 260 | 28 |
| recursive-ai-engineering | Love-DC/recursive-ai-engineering | 21 | 1 |

## Risk summary

| Risk class | Count |
|---|---:|
| eligible_batch | 0 |
| owner_decision_required | 250 |
| preserve_or_blocked | 62 |

## Findings

All branch tips except default branches have not yet had ancestry compared with the current default tip in this initial snapshot. They are therefore decision-required, not cleanup candidates. Open PR refs and default branches are preserved.
All returned GitHub branch protection flags were false; the API field was available for every branch in the paginated result. This does not independently prove the absence of organization-wide policy outside the branch endpoint.
Supabase development-branch and Edge Function inventories were empty for both accessible Supabase projects. One Supabase project has no mapping in the active RAE registry; its ownership mapping remains uncertain.
Supabase project deletion, development-branch deletion and Edge Function deletion/deployment are disabled. Cross-repository GitHub deletion is disabled.
ChatGPT conversation history is outside RAE platform access and is not inventoried.

## Resource detail

| Project | Platform | Kind | Identity | State | Risk | Action |
|---|---|---|---|---|---|---|
| Supabase account | supabase | project | rgztxilqcfuclkekyojl | ACTIVE_HEALTHY | preserve_or_blocked | inventory only |
| Supabase account | supabase | project | xplphdljxpnlnlpdoioy | ACTIVE_HEALTHY | preserve_or_blocked | inventory only |
| colony-sim | github | branch | ai/100-context-pack-v2-budget-ledger | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/104-m1b-fatigue-needs | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/105-m1b-rest-zone-gridworld | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/105-rest-zone-validation | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/106-m1b-rest-job-simulation | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/106-rest-job-validation | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/107-m1b-rest-ui | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/109-fatigue-validation | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/117-m1b-seven-day-scenario | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/118-m1b-focused-ci | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/125-m2-job-contract | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/126-construction-storage-brief | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/127-first-production-brief | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/131-m2-contention-characterization | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/133-m2-claim-release | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/135-m2-active-job-creation | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/136-m2-wood-target-validation | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/138-m2-terminal-outcomes | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/140-m2-diagnostic-snapshot | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/142-m2-manual-order-lifecycle | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/144-m2-autonomous-wood-lifecycle | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/145-m2-needs-food-ci | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/154-meal-schedule-brief | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/155-resource-flow-balance | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/156-renewable-ecology-brief | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/164-prepared-task-draft-v1 | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/166-m3-implementation-contract | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/168-ecology-lifecycle-core | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/170-prepared-context-integration | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/171-ecology-world-runtime | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/181-grid-occupancy-navigation | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/189-multifield-geography-profile | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/191-offline-commit-tree-resolver | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/194-connected-inland-hydrology | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/199-wood-site-escrow | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/209-equipment-store-fixed-slots | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/210-food-seed-granary-transactions | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/211-audio-foundation | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/214-hydrology-world-integration | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/216-combat-pd017-record | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/216-record-pd016-combat-equipment | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/218-colonist-health-down-state | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/226-combat-rules-kernel | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/229-sfx-design-proposal | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | ai/234-seeded-encounter-alarm-policy | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/236-season-climate-design | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | ai/238-equipment-combat-profiles | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/240-hidden-valley-playtest | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | ai/240-hidden-valley-playtest-frontier | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | ai/241-calendar-60-day-core | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/244-secret-scanner-benchmark | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/246-regional-climate-design | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/248-corrupted-lands-design | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/249-climate-c1-contract | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/250-corruption-state-contract | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/252-climate-c1-runtime | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/252-granary-site-construction | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/254-corruption-runtime-foundation | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/262-enemy-type-architecture-contract | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/263-frontier-start-decision | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/266-enemy-type-catalog-foundation | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/267-g5-09-remote-benchmark-runner | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/267-g5-09-runtime-socket-probe | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/270-enemy-instance-state | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/272-corrupted-creature-death-policy | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/290-deterministic-multisource-distance-field | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | ai/34-resource-state-map | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/344-world-history-corruption-lore | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | ai/35-resource-task-lifecycle | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/355-social-civilization-framework | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | ai/357-social-patterns-relations | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | ai/359-player-directed-species-framework | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | ai/36-resources-module-contract | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/366-initial-societies-contact-web | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | ai/370-everyday-life-material-culture | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | ai/386-carrier-capacity-policy | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/387-food-seed-haul-target-claim | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | ai/392-seed-granary-withdrawal | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/40-wood-resource-accounting | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/408-carrier-policy-focused-smoke | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/409-coordinator-ready-validation-gate | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/417-m3-simulation-economy-subcoord | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/418-world-systems-subcoord | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/42-wood-resource-store | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/45-ground-pile-store-integration | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/47-stockpile-deposit-store-integration | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/50-wood-source-store-api | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/52-live-harvest-source-integration | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/55-cargo-store-api | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/57-live-colonist-cargo-integration | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/64-needs-job-integration-research | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/65-food-resource-research | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/73-food-resource-store | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/74-colonist-needs | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/75-eat-job-integration | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/81-serena-gdscript-evaluation | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/82-repomix-context-audit | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/83-repository-map-research | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/84-context-pack-v2-proposal | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/85-record-ai-governance-decision | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/93-context-pack-v2-schema-provenance | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/95-ci-checkout-exact-pr-head | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/a2-03-owner-gated-issue-publication | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/a2-04-queue-integration-report-refresh | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/ai-pr-review-authority-20261123 | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/climate-profile-preview-report | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | ai/continuous-ai-orchestration-proposal | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/cs-a1-01-candidate-contract | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/cs-a1-02-readonly-snapshot-collector | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/cs-a1-03-deterministic-signal-analyzer | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/cs-a1-04-task-radar-report | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/cs-a1-05-task-radar-workflow | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/first-principles-simulation | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/g3-hidden-valley-design | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/g3-open-basin-geometry-proposal | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/g5-06-github-read-only-transport | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/g5-07-secret-scanner-policy-20261121 | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/g5-08-allow-loopback-probe | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/g5-08-enable-loopback-in-netns | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/g5-08-local-ipv6-bind-probe | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/g5-08-second-round-fixtures | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/g5-08-trace-diagnostics | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/g5-09-namespace-diagnostics | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/g5-security-contract-proposal | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/m1-closeout-status-sync | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/m1b-progress-status-sync | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | ai/season-system-master-design | present | owner_decision_required | reinspect |
| colony-sim | github | branch | ai/season-system-master-design-current | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | art/art-direction-proposal | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | chore/colony-governance-in-ai-context-ci | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/238-equipment-main-af1d | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/276-battle-organization-main-352647 | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | coordinator/283-world-navigation-v2-main-352647 | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | coordinator/302-combat-runtime-current-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/302-combat-runtime-integration-contract | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/302-combat-runtime-integration-main-352647 | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | coordinator/302-combat-runtime-main-af1d | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/304-colonist-health-damage-events | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/305-colonist-health-damage-events | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/305-health-main-af1d | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/336-enemy-behavior-intents-current-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/336-enemy-behavior-intents-main-352647 | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | coordinator/336-enemy-behavior-intents-main-63c | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/344-world-history-lore-draft-main-545a | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | coordinator/a3-general-worker-control-panel | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | coordinator/climate-c1-current-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/colonist-health-current-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/colonist-health-event-idempotency-latest-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/combat-rules-after-health | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/combat-rules-current-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/corrupted-death-policy-current-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/corrupted-death-policy-latest-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/encounter-state-current-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/encounter-state-main-current | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/enemy-catalog-current-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/enemy-catalog-latest-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/enemy-instance-latest-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/enemy-PD023-optionA-final-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/enemy-PD023-optionA-latest-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/enemy-PD023-optionA-record | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/enemy-type-PD023-contract | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/equipment-profiles-latest-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/equipment-store-current-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/frontier-start-PD022-current-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/frontier-start-PD022-latest-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/g5-02-v1-context-hardening | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/g5-03-ci-action-pinning | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/g5-04-commit-tree-design | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/g5-08-allow-urllib3-failed-loopback-probe | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/g5-08-allow-urllib3-ipv6-loopback-probe | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/g5-08-candidate-stage-diagnostics | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/g5-08-explicit-ipv6-loopback | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/g5-08-stage-diagnostics-latest-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/g5-08-strict-ipv6-loopback-current-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/g5-08-strict-ipv6-loopback-latest-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/g5-08-strict-loopback-current-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/g5-09-runner-current-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/health-damage-events-latest-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/health-damage-events-post-loopback | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/hidden-valley-g3-docs-current-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/hidden-valley-g3-docs-latest-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/integration-docs-2026-11-21 | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/m3-c2b-docs-current | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/m3-c2b-docs-main-current | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/m3-d4-pd015-docs | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/m3-d4-pd015-docs-current | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/m3-d4-pd015-docs-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/m3-granary-capacity-lifecycle | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/m3-r1-food-seed-ground-cargo | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/m3-r1-food-seed-ground-cargo-current | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/m3-w1-post-merge-status | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/pd-007-physical-seed-input | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/PD023-corrupted-roster-record | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | coordinator/project-state-2026-11-21-current-main | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/project-state-current-main-2026-11-21 | present | owner_decision_required | reinspect |
| colony-sim | github | branch | coordinator/project-state-current-main-2026-11-21-v2 | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | coordinator/readme-project-status-current-main | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | coordinator/record-first-combat-release-decisions | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | coordinator/world-generation-v1-design | present | owner_decision_required | reinspect |
| colony-sim | github | branch | docs/ai-agent-merge-ownership | present | owner_decision_required | reinspect |
| colony-sim | github | branch | docs/ai-ci-trigger-protocol | present | owner_decision_required | reinspect |
| colony-sim | github | branch | docs/approve-m1a-hunger-decision | present | owner_decision_required | reinspect |
| colony-sim | github | branch | docs/close-world-geography-phase-one | present | owner_decision_required | reinspect |
| colony-sim | github | branch | docs/colony-development-roadmap | present | owner_decision_required | reinspect |
| colony-sim | github | branch | docs/context-recursive-orchestration | present | owner_decision_required | reinspect |
| colony-sim | github | branch | docs/explicit-agent-assignment | present | owner_decision_required | reinspect |
| colony-sim | github | branch | docs/g5-issue-dispatch-activation-v2 | present | owner_decision_required | reinspect |
| colony-sim | github | branch | docs/issue-based-worker-dispatch | present | owner_decision_required | reinspect |
| colony-sim | github | branch | docs/m1-survival-planning | present | owner_decision_required | reinspect |
| colony-sim | github | branch | docs/m1a-integrated-contract | present | owner_decision_required | reinspect |
| colony-sim | github | branch | docs/m1a-pd002-approved-rules | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | docs/m3-eco02-post-merge-state | present | owner_decision_required | reinspect |
| colony-sim | github | branch | docs/update-world-generation-roadmap | present | owner_decision_required | reinspect |
| colony-sim | github | branch | docs/web-first-ai-development | present | owner_decision_required | reinspect |
| colony-sim | github | branch | docs/world-and-starting-land-design | present | owner_decision_required | reinspect |
| colony-sim | github | branch | docs/world-persistence-research | present | owner_decision_required | reinspect |
| colony-sim | github | branch | feat/ai-recursive-development-framework | present | owner_decision_required | reinspect |
| colony-sim | github | branch | feat/repository-local-governance-v1 | present | owner_decision_required | reinspect |
| colony-sim | github | branch | feature/375-ammunition-resource-store | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | feature/autonomous-work-priorities | present | owner_decision_required | reinspect |
| colony-sim | github | branch | feature/colonist-direct-orders | present | owner_decision_required | reinspect |
| colony-sim | github | branch | feature/composed-world-chunk-fields | present | owner_decision_required | reinspect |
| colony-sim | github | branch | feature/composite-world-chunk-state | present | owner_decision_required | reinspect |
| colony-sim | github | branch | feature/configurable-geography-classification | present | owner_decision_required | reinspect |
| colony-sim | github | branch | feature/deterministic-world-sampling | present | owner_decision_required | reinspect |
| colony-sim | github | branch | feature/deterministic-world-value-noise | present | owner_decision_required | reinspect |
| colony-sim | github | branch | feature/harvest-work-zones | present | owner_decision_required | reinspect |
| colony-sim | github | branch | feature/phase-2-exploration-map-baseline | present | owner_decision_required | reinspect |
| colony-sim | github | branch | feature/wood-work-goals | present | owner_decision_required | reinspect |
| colony-sim | github | branch | feature/world-cell-access-routing | present | owner_decision_required | reinspect |
| colony-sim | github | branch | feature/world-cell-geography-query | present | owner_decision_required | reinspect |
| colony-sim | github | branch | feature/world-chunk-data-model | present | owner_decision_required | reinspect |
| colony-sim | github | branch | feature/world-chunk-field-generation | present | owner_decision_required | reinspect |
| colony-sim | github | branch | feature/world-chunk-runtime-manager | present | owner_decision_required | reinspect |
| colony-sim | github | branch | feature/world-coordinate-primitives | present | owner_decision_required | reinspect |
| colony-sim | github | branch | feature/world-coordinate-roundtrip | present | owner_decision_required | reinspect |
| colony-sim | github | branch | feature/world-field-mixer | present | owner_decision_required | reinspect |
| colony-sim | github | branch | feature/world-generation-identity | present | owner_decision_required | reinspect |
| colony-sim | github | branch | feature/world-geography-catalog-v1 | present | owner_decision_required | reinspect |
| colony-sim | github | branch | fix/g5-06-base64-linewrap | present | owner_decision_required | reinspect |
| colony-sim | github | branch | fix/g5-06-smoke-import-path | present | owner_decision_required | reinspect |
| colony-sim | github | branch | fix/g5-08-ipv6-trace-decoding | present | owner_decision_required | reinspect |
| colony-sim | github | branch | fix/g5-08-ipv6-trace-decoding-2 | present | owner_decision_required | reinspect |
| colony-sim | github | branch | fix/g5-08-ipv6-trace-diagnostics | present | owner_decision_required | reinspect |
| colony-sim | github | branch | fix/g5-08-semantic-ipv6-loopback | present | owner_decision_required | reinspect |
| colony-sim | github | branch | fix/g5-08-strace-inet-pton-pointer | present | owner_decision_required | reinspect |
| colony-sim | github | branch | fix/g5-08-strace-probe-diagnostics | present | owner_decision_required | reinspect |
| colony-sim | github | branch | integration/m1b-rest-ui | present | owner_decision_required | reinspect |
| colony-sim | github | branch | integration/m1b-seven-day-survival | present | owner_decision_required | reinspect |
| colony-sim | github | branch | issue-76-m1a-seven-day-validation | present | owner_decision_required | reinspect |
| colony-sim | github | branch | main | present | preserve_or_blocked | preserve |
| colony-sim | github | branch | perf/cache-world-noise-stream-hashes | present | owner_decision_required | reinspect |
| colony-sim | github | branch | perf/prepare-world-fields-once | present | owner_decision_required | reinspect |
| colony-sim | github | branch | perf/reduce-world-field-hot-loop-allocations | present | owner_decision_required | reinspect |
| colony-sim | github | branch | perf/streamline-chunk-field-generation | present | owner_decision_required | reinspect |
| colony-sim | github | branch | refactor/simulation-model-view-separation | present | owner_decision_required | reinspect |
| colony-sim | github | branch | research/world-chunking-architecture | present | owner_decision_required | reinspect |
| colony-sim | github | branch | test/pending-order-stale-target | present | owner_decision_required | reinspect |
| colony-sim | github | branch | validation/m1a-pr77-pr78 | present | owner_decision_required | reinspect |
| colony-sim | github | branch | worker/g5-01-v2-resource-bounds | present | owner_decision_required | reinspect |
| colony-sim | github | open_pr_reference | 111 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 196 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 232 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 239 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 245 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 293 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 334 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 335 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 341 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 342 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 345 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 346 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 348 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 349 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 352 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 354 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 356 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 358 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 361 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 367 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 369 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 371 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 375 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 376 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 377 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 413 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 423 | open | preserve_or_blocked | preserve referenced branch |
| colony-sim | github | open_pr_reference | 72 | open | preserve_or_blocked | preserve referenced branch |
| recursive-ai-engineering | github | branch | ai/80fe5a60-resource-lifecycle-center | present | owner_decision_required | reinspect |
| recursive-ai-engineering | github | branch | ai/autonomous-task-discovery-fcd2194 | present | owner_decision_required | reinspect |
| recursive-ai-engineering | github | branch | ai/governance-fixture-fcdee35 | present | owner_decision_required | reinspect |
| recursive-ai-engineering | github | branch | ai/guarded-batch-branch-cleanup | present | owner_decision_required | reinspect |
| recursive-ai-engineering | github | branch | ai/guarded-batch-branch-cleanup-v2 | present | owner_decision_required | reinspect |
| recursive-ai-engineering | github | branch | docs/deployed-failure-retry-contract | present | owner_decision_required | reinspect |
| recursive-ai-engineering | github | branch | docs/explicit-owner-input-and-autonomy-contract | present | owner_decision_required | reinspect |
| recursive-ai-engineering | github | branch | feat/github-app-gateway | present | owner_decision_required | reinspect |
| recursive-ai-engineering | github | branch | feat/multi-project-colony-sim-onboarding | present | owner_decision_required | reinspect |
| recursive-ai-engineering | github | branch | feat/repository-local-governance-v1 | present | owner_decision_required | reinspect |
| recursive-ai-engineering | github | branch | main | present | preserve_or_blocked | preserve |
| recursive-ai-engineering | github | branch | rae/docs-heartbeat-coverage-map | present | owner_decision_required | reinspect |
| recursive-ai-engineering | github | branch | rae/p0-heartbeat-coverage-docs-current-main-20261123 | present | owner_decision_required | reinspect |
| recursive-ai-engineering | github | branch | rae/p0-heartbeat-lease-tests | present | owner_decision_required | reinspect |
| recursive-ai-engineering | github | branch | rae/p0-heartbeat-lease-tests-current-main | present | owner_decision_required | reinspect |
| recursive-ai-engineering | github | branch | rae/p0-heartbeat-lease-tests-current-main-20261123 | present | owner_decision_required | reinspect |
| recursive-ai-engineering | github | branch | rae/p1-claim-race-distinct-workers | present | owner_decision_required | reinspect |
| recursive-ai-engineering | github | branch | rae/p1-failure-repair-child-dedupe | present | owner_decision_required | reinspect |
| recursive-ai-engineering | github | branch | rae/p1-failure-retry-contract | present | owner_decision_required | reinspect |
| recursive-ai-engineering | github | branch | revert/branch-cleanup-feature | present | owner_decision_required | reinspect |
| recursive-ai-engineering | github | branch | rules/independent-reviewer-merge | present | preserve_or_blocked | preserve |
| recursive-ai-engineering | github | open_pr_reference | 26 | open | preserve_or_blocked | preserve referenced branch |

No resources were deleted during inventory or implementation.
