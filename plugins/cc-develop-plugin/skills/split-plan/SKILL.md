---
name: split-plan
description: Analyze a master plan file and split it into 8 phase-specific implementation plans organized by feature tracks. Automatically identifies tracks, classifies tasks by phase, scores complexity, and generates detailed phase plan files following clean architecture principles.
user-invocable: false
arguments:
  - name: master-plan-path
    description: Path to the master plan file to analyze
    required: true
  - name: base-name
    description: Base name for output files (extracted from master plan filename)
    required: true
---

# Split Plan

Transform a master plan into 8 phase-specific implementation plans organized by feature tracks with complexity scoring.

## Purpose

Analyze a master plan file and generate 8 separate plan files, one for each phase of clean architecture (Foundational, Models, Services, Data, Rules, State Management, UI, Tests).

## Overview

Analyze a master plan file and generate 8 separate plan files, one for each phase of clean architecture:

1. **Foundational** - Base abstractions, utilities, infrastructure
2. **Models** - Data entities, DTOs, value objects
3. **Services** - External APIs, service integrations
4. **Data** - Repositories, DAOs, local storage
5. **Rules** - Business logic, use cases, validation
6. **State Management** - ViewModels, presenters, state handlers
7. **UI** - Screens, components, widgets
8. **Tests** - Unit tests, integration tests, test utilities

## Inputs

- **Master Plan**: `${master-plan-path}` - The comprehensive plan to analyze
- **Base Name**: `${base-name}` - Prefix for all generated files

## Outputs

Eight phase plan files in `.trackers/${base-name}/plans/`:
- `${base-name}-01-foundational.md`
- `${base-name}-02-models.md`
- `${base-name}-03-services.md`
- `${base-name}-04-data.md`
- `${base-name}-05-rules.md`
- `${base-name}-06-state-management.md`
- `${base-name}-07-ui.md`
- `${base-name}-08-tests.md`

## Workflow

### 1. Analyze Master Plan

Read the master plan from `${master-plan-path}` and:

**Extract tasks**: Identify all implementation tasks from the plan
- Look for numbered lists, bullet points, sections
- Extract task titles and descriptions
- Note dependencies and relationships

**Identify feature tracks**: Group related tasks by feature/module
- Use lowercase-with-hyphens naming (e.g., "authentication", "user-profile")
- Prefer broader groupings over granular ones
- Ensure tracks can span multiple phases
- Common tracks: authentication, products, cart, notifications, settings

**Classify tasks by phase**: Determine which phase each task belongs to

**Classification decision tree**:
1. Sets up base infrastructure? → Phase 1 (Foundational)
2. Defines data structures? → Phase 2 (Models)
3. Calls external APIs? → Phase 3 (Services)
4. Accesses local storage? → Phase 4 (Data)
5. Contains business logic? → Phase 5 (Rules)
6. Manages app state? → Phase 6 (State Management)
7. Renders UI? → Phase 7 (UI)
8. Writes tests (unit, integration, e2e)? → Phase 8 (Tests)

**Score complexity** for each task (1-3):
- **1 (Low)**: Simple, straightforward (add field, create model, basic utility)
- **2 (Medium)**: Moderate effort (implement feature, build component, API integration)
- **3 (High)**: Complex (auth system, real-time features, payment integration)

Increase complexity for: security-critical, multiple integrations, unclear requirements
Decrease complexity for: similar existing code, well-defined, isolated, simple CRUD

**Create output directory**:
```bash
mkdir -p .trackers/${base-name}/plans
```

### 2. Generate Phase Plan Files

For each phase (1-8), create a plan file using the template below.

**File naming**: `.trackers/${base-name}/plans/${base-name}-{NN}-{name}.md`
- Use zero-padded numbers: 01, 02, ..., 08
- Use lowercase phase names: foundational, models, services, data, rules, state-management, ui, tests

**If phase has no tasks**: Use the empty phase template (below)

**If phase has tasks**:
- Group tasks by track
- Include full task details with complexity scores
- Add implementation guidance and dependencies
- Provide acceptance criteria

### 3. Verify and Report

**Verify all 8 files exist**:
```bash
ls -la .trackers/${base-name}/plans/
```

**Report execution results**:
- Files created (8/8)
- Total tracks identified
- Total tasks across all phases
- Complexity distribution
- Any errors or warnings

**Report to caller**:
Output a brief summary of results so the orchestrator can continue.

## Phase Plan File Template

```markdown
# Phase {N}: {Phase Name} - ${base-name}

**Phase Number**: {N}
**Status**: Pending
**Dependencies**: {Previous phase name or "None"}

## Phase Overview

{Brief description of what this phase accomplishes}

This phase includes tasks for the following tracks:
- **{track-1}**: {brief description}
- **{track-2}**: {brief description}

## Implementation Context

{How this phase builds on previous phases}
{Architectural patterns to follow}
{Important considerations}

---

## Track: {track-name}

### Task {M}: {Task Title}

**Complexity**: {1|2|3} ({Low|Medium|High})
**Track**: {track-name}
**Status**: Pending
**Estimated Effort**: {Small|Medium|Large}

#### Description

{Detailed description of what needs to be implemented}
{Purpose and context}
{How it fits into the larger feature}

#### Acceptance Criteria

- [ ] {Specific, testable criterion 1}
- [ ] {Specific, testable criterion 2}
- [ ] {Specific, testable criterion 3}

#### Implementation Details

{Specific implementation guidance}

**Files to Create/Modify**:
- `path/to/file1.ext` - {what to do}
- `path/to/file2.ext` - {what to do}

**Key Considerations**:
- {Important technical detail or edge case}
- {Pattern to follow or constraint to respect}

**Dependencies**:
- {Task dependencies within phase or from previous phases}

**Testing**:
- {What should be tested}
- {Test scenarios to cover}

---

{Repeat for all tasks in track}
{Repeat for all tracks in phase}

---

## Phase Completion Checklist

After completing all tasks in this phase, verify:

- [ ] All tasks in this phase are implemented
- [ ] Code follows project patterns and conventions
- [ ] Tests are written and passing
- [ ] Documentation is updated
- [ ] No errors or warnings
- [ ] Ready to proceed to Phase {N+1} (or "Complete" if Phase 8)

## Notes

{Additional notes, warnings, or important information}
```

## Empty Phase Template

For phases with no tasks:

```markdown
# Phase {N}: {Phase Name} - ${base-name}

**Phase Number**: {N}
**Status**: Pending
**Dependencies**: {Previous phase name or "None"}

## Phase Overview

No tasks have been identified for this phase in the current master plan.

## Implementation Context

This phase may be populated in future iterations as the project evolves. {Phase Name} typically includes {brief description based on phase type}.

---

## Phase Completion Checklist

- [ ] Phase marked as complete (no tasks to implement)
- [ ] Ready to proceed to Phase {N+1} (or "Complete" if Phase 8)

## Notes

This phase will be skipped during implementation as no tasks are currently planned.
```

## Phase Classification Guide

### Phase 1: Foundational
- Base abstractions, utilities, infrastructure
- Dependency injection, environment config
- Abstract base classes, project scaffolding
- Build tools, shared utilities

### Phase 2: Models
- Data entities, model classes, DTOs
- Value objects, enums, constants
- Data serialization/deserialization
- JSON classes, data structures

### Phase 3: Services
- External APIs, third-party integrations
- REST/GraphQL clients, network layer
- HTTP communication, API error handling
- Service integrations

### Phase 4: Data
- Repositories, DAOs, data access layer
- Local storage (SQLite, file system)
- Cache implementations
- Data source abstractions

### Phase 5: Rules
- Business logic, use cases, workflows
- Domain validation, business rules
- Complex algorithms, domain events
- Application-specific logic

### Phase 6: State Management
- ViewModels, presenters, controllers
- State handlers (Bloc, Provider, Redux)
- Reactive state management
- Application state transitions

### Phase 7: UI
- Screens, pages, components, widgets
- User interface rendering
- Navigation, layouts, styling
- Visual elements, user interactions

### Phase 8: Tests
- Unit tests for all layers (models, services, repositories, use cases, view models)
- Integration tests for API clients, repositories, and complex workflows
- UI tests, widget tests, component tests, end-to-end tests
- Test utilities, mocks, fakes, stubs, and fixtures
- Test configuration, test runners, CI test setup
- Performance tests, snapshot tests

## Dependency Flow

Dependencies flow inward in clean architecture:

```
Tests → UI → State Management → Rules → Data → Services → Models → Foundational
```

- Tests validate all layers (Tests may depend on any layer)
- Outer layers depend on inner layers
- Inner layers never depend on outer layers
- Each phase can only depend on earlier phases

## Track Organization

**Good track examples**:
- `authentication` - Login, signup, session (spans phases 2-7)
- `user-profile` - Profile data, editing, display (spans phases 2-7)
- `products` - Product catalog, details, search (spans phases 2-7)
- `shopping-cart` - Cart management, persistence (spans phases 2-7)
- `core` - Base infrastructure (phases 1-2)

**Track naming**:
- Use lowercase-with-hyphens
- Be descriptive but concise
- Prefer feature-based over technical-layer-based
- Ensure tracks span multiple phases when possible

## Complexity Scoring Reference

**Score 1 (Low)**:
- Single file, simple logic
- Standard patterns
- Minimal testing
- Examples: Add constant, create model, basic utility

**Score 2 (Medium)**:
- Multiple files, moderate integration
- Some architectural decisions
- Standard testing needs
- Examples: Implement feature, build component, API client

**Score 3 (High)**:
- Significant architecture impact
- Complex logic or multiple integrations
- Extensive testing required
- Security-critical or performance-sensitive
- Examples: Auth system, real-time features, payment integration

## Guidelines

**You MUST**:
- Read the entire master plan before generating any phase plans
- Create ALL 8 phase plan files (use empty template if no tasks)
- Use zero-padded numbers in filenames (01-08, not 1-8)
- Assign every task a complexity score (1, 2, or 3)
- Organize tasks by feature tracks within each phase
- Follow the naming convention: `${base-name}-{NN}-{name}.md`
- Verify all files exist before reporting completion
- Report results to caller upon completion

**You MUST NOT**:
- Skip any of the 8 phases
- Create custom phases outside the defined 8
- Assign tasks to incorrect phases
- Create overly granular tracks (prefer broader groupings)
- Forget complexity scores on tasks
- Use non-zero-padded numbers in filenames
- Report completion without verification

## Example Track Distribution

For a typical e-commerce app with tracks: authentication, products, cart, checkout

**Phase 1 (Foundational)**:
- core: Base repository interface, DI setup, utilities (3 tasks)

**Phase 2 (Models)**:
- authentication: User, Token models (2 tasks)
- products: Product, Category models (2 tasks)
- cart: CartItem, Cart models (2 tasks)
- checkout: Order, Payment models (2 tasks)

**Phase 3 (Services)**:
- authentication: Auth API client (1 task)
- products: Product API client (1 task)
- checkout: Payment service integration (1 task)

**Phase 4 (Data)**:
- authentication: Token repository (1 task)
- products: Product repository, cache (2 tasks)
- cart: Cart repository (1 task)

**Phase 5 (Rules)**:
- authentication: Login/logout use cases (2 tasks)
- products: Search, filter logic (2 tasks)
- cart: Add/remove items use cases (2 tasks)
- checkout: Checkout workflow (1 task)

**Phase 6 (State Management)**:
- authentication: AuthBloc (1 task)
- products: ProductListBloc (1 task)
- cart: CartBloc (1 task)

**Phase 7 (UI)**:
- authentication: Login screen (1 task)
- products: Product list, detail screens (2 tasks)
- cart: Cart screen (1 task)
- checkout: Checkout screen (1 task)

This shows how tracks span multiple phases building complete features.
