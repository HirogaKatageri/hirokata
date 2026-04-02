# Software Plugin

A Claude Code plugin for automated requirements-to-implementation workflows using a phase-based clean architecture approach.

## Overview

The **develop** plugin transforms requirements documents into working code through a structured, automated workflow. It analyzes requirements, creates implementation plans, organizes work into architectural phases, and spawns developer agents to implement features in parallel.

### Key Features

- **Automated Planning**: Converts requirements into comprehensive master plans
- **Phase-Based Architecture**: Organizes implementation into 8 sequential clean architecture phases
- **Feature Tracking**: Groups related tasks into feature tracks across phases
- **Complexity Scoring**: Analyzes task complexity for better estimation
- **Fixed Parallelism**: Spawns up to 3 developer agents per phase based on task count
- **Resume Capability**: Continue work from any point if interrupted

## Architecture

This plugin implements an **8-phase clean architecture** workflow:

```
Foundational → Models → Services → Data → Rules → State Management → UI → Tests
```

### The 8 Phases

1. **Foundational** - Base abstractions, utilities, infrastructure, and tooling setup
2. **Models** - Data entities, model classes, DTOs, and value objects
3. **Services** - External APIs, service integrations, and network layer
4. **Data** - Repositories, DAOs, data access layer, and local storage
5. **Rules** - Business logic, use cases, validation, and domain rules
6. **State Management** - View models, presenters, state handlers, and controllers
7. **UI** - Screens, components, views, and user interface
8. **Tests** - Unit tests, integration tests, e2e tests, and test utilities

**Why This Order?**

Phases must be executed sequentially because each phase builds on the previous ones, following clean architecture dependency flow: UI depends on State Management, which depends on Rules, which depends on Data, and so on.

### Feature Tracks

**Tracks** represent complete features that span multiple phases:

- **authentication**: Login, signup, session management across all layers
- **profile**: User profile management from models to UI
- **products**: Product catalog from data to display
- **cart**: Shopping cart functionality end-to-end

Within each phase, tasks are organized by track. For example, Phase 2 (Models) might have:
- Track: authentication (User model, Token model)
- Track: products (Product model, Category model)
- Track: cart (CartItem model)

## Commands

### `/software:develop-project`

Complete requirements-to-implementation workflow with 8-phase architecture.

**Usage:**
```
/software:develop-project [file-path-or-query]
```

**Arguments:**
- `[file-path-or-query]` - Path to requirements document (markdown) or search query (optional)

**Examples:**
```bash
# Start with requirements file
/software:develop-project requirements.md

# Search for requirements file
/software:develop-project app-requirements

# Interactive mode (prompts for file)
/software:develop-project
```

**Workflow:**

1. **Parse arguments** and resolve requirements file path
2. **software:software-architect Agent** creates comprehensive master plan from requirements
3. **User Reviews** and approves the master plan *(only user gate)*
4. **software:split-plan Skill** splits master plan into 8 phase plan files and builds `TASKS.md`
5. **software:senior-developer Agents** execute all 8 phases sequentially:
   - Phases run sequentially (1→2→3→4→5→6→7→8)
   - Within each phase, up to 3 agents run in parallel based on task count
   - After all phases: runs `software:comprehensive-review` and fixes issues (max 2 iterations)
6. **Generate final summary report** with progress and next steps

**Files Generated:**
```
.trackers/{BASE_NAME}/
├── TASKS.md                               # Progress tracker
└── plans/
    ├── {BASE_NAME}-master-plan.md         # Comprehensive master plan
    ├── {BASE_NAME}-01-foundational.md     # Phase 1 plan
    ├── {BASE_NAME}-02-models.md           # Phase 2 plan
    ├── {BASE_NAME}-03-services.md         # Phase 3 plan
    ├── {BASE_NAME}-04-data.md             # Phase 4 plan
    ├── {BASE_NAME}-05-rules.md            # Phase 5 plan
    ├── {BASE_NAME}-06-state-management.md # Phase 6 plan
    ├── {BASE_NAME}-07-ui.md               # Phase 7 plan
    ├── {BASE_NAME}-08-tests.md            # Phase 8 plan
    └── {BASE_NAME}-SUMMARY.md             # Summary report
```

## Skills

The plugin includes skills for development workflow support:

### `software:comprehensive-review`

Orchestrates a complete multi-dimensional review of code changes, running five specialized review agents in parallel.

**Responsibilities:**
- Run all five code review agents simultaneously (product, business-logic, edge-case, architecture, security)
- Collect and consolidate reports from all agents
- Present comprehensive analysis with prioritized action items
- Provide executive summary across all review dimensions

**Trigger Phrases:**
- "review my changes"
- "run comprehensive review"
- "review against requirements"
- "check all my code"
- "run all reviewers"
- "comprehensive code review"

**Review Dimensions:**
1. **Requirements Compliance** - Verify all requirements are implemented
2. **Test Coverage** - Ensure business logic is testable and tested
3. **Edge Case Handling** - Identify unhandled edge cases
4. **Architectural Alignment** - Check clean architecture compliance
5. **Security** - Identify security vulnerabilities and risks

**Features:**
- Parallel agent execution for fast reviews (2-5 minutes)
- Consolidated reporting with priority rankings
- Detailed interpretation guides and decision matrices
- Go/no-go assessment for PR readiness
- Evidence-based findings with file paths and line numbers

**Supporting Resources:**
- `references/agent-capabilities.md` - Detailed agent documentation
- `references/review-interpretation.md` - How to interpret findings
- `examples/phase-completion-review.md` - Phase completion example
- `examples/pr-readiness-review.md` - PR readiness example with security issue

**Workflow:**
1. Identify review scope (requirements, recent changes)
2. Launch all 5 agents in parallel
3. Collect agent reports
4. Present consolidated report with executive summary and prioritized actions

**Output Format:**
- Executive summary (overall status, critical issues, warnings)
- Review dimensions summary (compliance %, test coverage, edge cases, architecture, security)
- Priority actions (Must Fix/Should Fix/Consider)
- Detailed reports from each agent

### `software:split-plan`

Analyzes a master plan file and splits it into 8 phase-specific implementation plans organized by feature tracks.

**Responsibilities:**
- Automatically identifies feature tracks
- Classifies tasks by phase
- Scores task complexity (1-3)
- Generates detailed phase plan files following clean architecture principles

**Used by:** `software:develop-project` skill during plan splitting (Step 4)

### `software:categorize-task`

Reference guide for classifying development tasks into the 8-phase clean architecture structure.

**Classification System:**
- **Phase 1 (Foundational)**: Infrastructure, utilities, abstract classes, base setup
- **Phase 2 (Models)**: Entities, DTOs, data structures, value objects
- **Phase 3 (Services)**: External APIs, third-party integrations, network layer
- **Phase 4 (Data)**: Repositories, DAOs, data access, local storage
- **Phase 5 (Rules)**: Business logic, use cases, validation, domain rules
- **Phase 6 (State Management)**: View models, presenters, state handlers, controllers
- **Phase 7 (UI)**: Screens, components, views, user interface
- **Phase 8 (Tests)**: Unit tests, integration tests, e2e tests, test utilities

### `software:conventional-commit`

Generates properly formatted conventional commits by analyzing changes, grouping related modifications, and creating semantic commit messages.

**Responsibilities:**
- Analyze staged and unstaged changes
- Group related changes logically (by purpose, type, scope)
- Ask user for commit strategy (separate/combined/single)
- Generate conventional commit messages following specification
- Stage and commit changes with proper formatting
- Handle edge cases (pre-commit hooks, conflicts, large changesets)

**Trigger Phrases:**
- "create a conventional commit"
- "generate conventional commits"
- "commit with conventional format"
- "group my changes for commits"
- "make a conventional commit message"

**Features:**
- Interactive commit grouping with user choice
- Follows Conventional Commits specification
- Supports breaking changes, issue references, co-authors

**Supporting Resources:**
- `references/conventional-commits-spec.md` - Full specification
- `references/commit-patterns.md` - Patterns and anti-patterns

### `software:generate-requirements`

Transforms feature ideas into structured requirements documents using the product-owner agent.

**Responsibilities:**
- Launch product-owner agent for requirements discovery
- Conduct clarifying questions with user
- Generate comprehensive requirements documentation
- Output single requirements file in `requirements/[FEATURE_NAME]_REQUIREMENTS.md`
- Ensure all user stories, acceptance criteria, edge cases, and technical considerations are included

**Trigger Phrases:**
- "generate requirements"
- "create requirements"
- "write requirements"
- "define requirements"
- "document requirements"
- "requirements for feature"

**Features:**
- Single file output (no auxiliary files)
- Comprehensive requirements template
- User story patterns and best practices
- Example requirements for reference
- Integration with product-owner agent

**File Output:**
- **Location**: `requirements/` directory
- **Naming**: `[FEATURE_NAME]_REQUIREMENTS.md` (uppercase with underscores)
- **Format**: Single markdown file with all sections

**Supporting Resources:**
- `references/requirements-template.md` - Complete template structure
- `references/user-story-patterns.md` - User story formats and examples
- `examples/BIOMETRIC_SIGNIN_REQUIREMENTS.md` - Complete requirements example

## Agents

### Code Review Agents

The plugin includes five specialized code review agents that work together to provide comprehensive code quality analysis:

#### `software:product-reviewer`

Verifies implementation satisfies all documented requirements from master plans, phase plans, and requirements documents.

**Responsibilities:**
- Compare recent changes against requirements documents
- Verify all requirements are implemented
- Identify missing or incomplete functionality
- Report gaps between planned features and implementation
- Validate features match intended specifications

**Color:** Magenta

**Model:** Haiku (fast, cost-effective reviews)

**Tools:** Read, Grep, Glob, Bash

**Output:**
- Implementation percentage (Implemented/Partial/Missing)
- Detailed requirements status with evidence
- Prioritized recommendations to close gaps

#### `software:code-reviewer-business-logic`

Ensures business logic is designed for testability and has adequate unit test coverage.

**Responsibilities:**
- Review business logic for testability patterns
- Identify missing unit tests
- Find testability anti-patterns (tight coupling, hard-coded dependencies)
- Provide refactoring suggestions for improved testability
- Verify test coverage adequacy

**Color:** Green

**Model:** Haiku (fast, cost-effective reviews)

**Tools:** Read, Grep, Glob, Bash

**Output:**
- Test coverage percentage
- Testability issues with refactoring recommendations
- Missing test scenarios by function/method
- Test quality assessment

#### `software:code-reviewer-edge-case`

Identifies unhandled edge cases, boundary conditions, error scenarios, and exceptional situations.

**Responsibilities:**
- Analyze input handling and validation
- Identify boundary conditions (null, empty, overflow)
- Find error scenarios not properly handled
- Review data structure edge cases
- Check concurrency and resource management issues

**Color:** Yellow

**Model:** Haiku (fast, cost-effective reviews)

**Tools:** Read, Grep, Glob, Bash

**Output:**
- Critical edge cases (high likelihood × high impact)
- Warning edge cases (medium risk)
- Info edge cases (low risk)
- Specific code examples and recommended fixes
- Testing suggestions

**Edge Case Categories:**
- Null/undefined handling
- Empty collections
- Numeric boundaries
- String edge cases
- Date/time issues
- Concurrency problems
- External dependency failures

#### `software:code-reviewer-architecture`

Reviews code for alignment with clean architecture principles and the 8-phase development structure.

**Responsibilities:**
- Verify dependency rule (dependencies point inward)
- Check layer separation and boundaries
- Identify architectural violations and anti-patterns
- Ensure code is in correct architectural phase
- Provide architectural improvement recommendations

**Color:** Cyan

**Model:** Haiku (fast, cost-effective reviews)

**Tools:** Read, Grep, Glob, Bash

**Output:**
- Dependency direction compliance percentage
- Critical architectural violations
- Layer misplacements
- Architectural warnings and recommendations
- Architectural debt assessment

**Checks:**
- Dependency Rule compliance
- Layer separation
- Business logic independence
- Framework coupling
- Interface design
- God classes and circular dependencies

#### `software:code-reviewer-security`

Identifies security vulnerabilities, weaknesses, and anti-patterns aligned with OWASP Top 10 and security best practices.

**Responsibilities:**
- Review code for injection vulnerabilities (SQL, command, LDAP, template)
- Identify authentication and session management flaws
- Detect sensitive data exposure (unencrypted PII, hardcoded secrets, logging)
- Find broken access control and authorization issues
- Check cryptographic usage and key management
- Provide OWASP-referenced remediation guidance

**Color:** Red

**Model:** Haiku (fast, cost-effective reviews)

**Tools:** Read, Grep, Glob, Bash

**Output:**
- Vulnerability counts by severity (Critical/High/Medium/Low/Info)
- Overall security posture assessment
- Hardcoded secrets and sensitive data audit
- Concrete remediation code examples
- Security strengths already in use

### `software:software-architect`

Analyzes requirements and creates comprehensive master implementation plans.

**Responsibilities:**
- Analyze requirements documents to understand scope, constraints, and success criteria
- Investigate existing codebase to understand current architecture and patterns
- Design comprehensive implementation strategies
- Create single, well-structured master plan documents
- Write plans directly to `.trackers/{BASE_NAME}/plans/{BASE_NAME}-master-plan.md`

**Color:** Red

**Model:** Sonnet (comprehensive analysis and planning)

**Tools:** Read, Grep, Glob, Write, Bash

**Triggers:**
- Called by `/software:develop-project` command in Step 2 for master plan creation
- Can be invoked manually to analyze requirements and create implementation plans

**Output:**
- Single master plan markdown file with comprehensive implementation roadmap
- Structured with phases, technical specifications, and architectural decisions

### `software:product-owner`

Transforms ambiguous ideas into well-structured requirements, user stories, and clear project scope.

**Responsibilities:**
- Translate feature requests into structured requirements
- Create comprehensive user stories with acceptance criteria
- Identify edge cases, dependencies, and constraints
- Define success metrics and KPIs
- Validate requirements against project patterns (CLAUDE.md)
- Bridge communication between business and technical stakeholders
- Ensure requirements are testable and complete

**Color:** Pink

**Model:** Haiku (fast, efficient for requirements gathering)

**Tools:** TaskCreate, TaskGet, TaskUpdate, TaskList, Glob, Grep, Read, WebFetch, WebSearch, ListMcpResourcesTool, ReadMcpResourceTool, Edit, Write, NotebookEdit, Bash

**Triggers:**
- When users describe new features without clear requirements
- When existing features need improvement or clarification
- When starting new project phases that need scope definition
- Can be invoked manually for requirements gathering

**Output Formats:**
- User Stories (primary): As a [role], I want [action], so that [value]
- Use Cases (secondary): Detailed workflow documentation for complex scenarios

### `software:senior-developer`

Implements features and writes production-ready code following project patterns.

**Responsibilities:**
- Review documentation and codebase patterns
- Implement tasks from phase plans
- Follow existing architectural decisions
- Write clean, maintainable code
- Handle errors appropriately
- Integrate with existing code

**Color:** Blue

**Model:** Haiku (fast, cost-effective implementation)

**Tools:** TaskCreate, TaskGet, TaskUpdate, TaskList, Glob, Grep, Read, Write, Edit, NotebookEdit, Bash, Skill, AskUserQuestion

**Triggers:**
- Spawned by `/software:develop-project` command during phase execution
- Up to 3 agents run in parallel per phase (3 when ≥3 tasks, 1 when <3 tasks)
- Can be invoked manually for specific implementation tasks

## Parallelism

Within each phase, the number of parallel developer agents is fixed based on task count:

- **≥ 3 pending tasks** → spawn **3** `software:senior-developer` agents in parallel
- **< 3 pending tasks** → spawn **1** `software:senior-developer` agent

## Complexity Scoring

Tasks are assigned complexity scores used for estimation and plan organization:

### Low Complexity (Score: 1)
Simple, straightforward tasks:
- Add constants or configuration
- Create simple model classes
- Add utility functions
- Update documentation

### Medium Complexity (Score: 2)
Implementation tasks requiring moderate effort:
- Implement new features
- Create services with multiple methods
- Build UI components
- Implement repository patterns
- Add validation logic

### High Complexity (Score: 3)
Complex or architectural tasks:
- Implement authentication systems
- Set up state management frameworks
- Integrate payment gateways
- Implement real-time features
- Complex business logic

## Example Usage

### Complete Workflow

```bash
# 1. Start with requirements
/software:develop-project requirements/my-app.md

# The plugin will:
# - Create master plan using software:software-architect agent
# - Wait for your review and approval
# - Split plan into 8 phase files using software:split-plan skill
# - Execute all phases with software:senior-developer agents
# - Run comprehensive review and fix any issues
# - Generate final summary report

# 2. Resume interrupted work
/software:develop-project requirements/my-app.md
# Detects existing TASKS.md and resumes from where it stopped
```

### Starting Without a File Path

```bash
# Interactive mode (prompts for file)
/software:develop-project

# Search by keyword
/software:develop-project my-feature
```

## Installation

### Local Development

1. Clone this repository:
   ```bash
   git clone <repository-url>
   cd software-project
   ```

2. Use the plugin with Claude Code:
   ```bash
   cc --plugin-dir /path/to/software-project
   ```

### Project-Specific

1. Copy plugin to your project:
   ```bash
   cp -r software-project /path/to/your-project/.claude-plugin/software
   ```

2. The plugin will be automatically loaded by Claude Code

## Requirements

- **Claude Code**: Latest version
- **Requirements Format**: Markdown files with clear feature descriptions

## Best Practices

### Requirements Documents

Structure your requirements for best results:

```markdown
# Project Requirements

## Overview
Brief description of the project

## Features

### Feature 1: User Authentication
- User can sign up with email/password
- User can log in
- Sessions are maintained
- Passwords are securely hashed

### Feature 2: Product Catalog
- Display list of products
- Filter by category
- Search by name
- View product details

## Technical Requirements
- Use JWT for authentication
- RESTful API architecture
- PostgreSQL database
- React frontend
```

### Resuming Work

- The plugin tracks progress automatically in `TASKS.md`
- You can pause at any time (Ctrl+C)
- Resume picks up exactly where you left off — runs that find an existing `TASKS.md` skip plan generation and jump straight to execution

### Reviewing Plans

Always review the master plan before execution:
- Verify feature groupings make sense
- Check task assignments to phases
- Confirm complexity scores are reasonable
- Adjust if needed before proceeding

## File Structure

```
software-project/
├── .claude-plugin/
│   └── plugin.json                      # Plugin manifest
├── agents/
│   ├── software-architect.md            # Software architect agent
│   ├── product-owner.md                 # Product owner agent
│   ├── senior-developer.md              # Senior developer agent
│   ├── product-reviewer.md              # Requirements compliance reviewer
│   ├── code-reviewer-business-logic.md  # Testability and test coverage reviewer
│   ├── code-reviewer-edge-case.md       # Edge case and boundary reviewer
│   ├── code-reviewer-architecture.md    # Architecture alignment reviewer
│   └── code-reviewer-security.md        # Security vulnerability reviewer
├── skills/
│   ├── split-plan/                      # Split master plan into phases
│   ├── categorize-task/                 # Task categorization reference
│   ├── develop-project/                 # Main workflow skill
│   │   ├── SKILL.md
│   │   └── references/
│   │       ├── workflow-steps.md
│   │       └── summary-report.md
│   ├── comprehensive-review/            # Multi-dimensional code review
│   │   ├── SKILL.md
│   │   ├── references/
│   │   │   ├── agent-capabilities.md
│   │   │   └── review-interpretation.md
│   │   └── examples/
│   │       ├── phase-completion-review.md
│   │       └── pr-readiness-review.md
│   ├── conventional-commit/             # Conventional commit generator
│   │   ├── SKILL.md
│   │   ├── references/
│   │   │   ├── conventional-commits-spec.md
│   │   │   └── commit-patterns.md
│   │   └── examples/
│   └── generate-requirements/           # Requirements generator
│       ├── SKILL.md
│       ├── references/
│       │   ├── requirements-template.md
│       │   └── user-story-patterns.md
│       └── examples/
│           └── BIOMETRIC_SIGNIN_REQUIREMENTS.md
├── .gitignore
├── LICENSE                      # MIT License
└── README.md                    # This file
```

## Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test with Claude Code
5. Submit a pull request

## License

MIT License - See LICENSE file for details.

## Author

**Gian Patrick Quintana**
- Email: gian.quintana@hirokata.dev
- GitHub: [@hirogakatageri](https://github.com/hirogakatageri)

## Support

For issues, questions, or feature requests:
1. Open an issue on the repository
2. Provide details about your use case
3. Include relevant error messages or logs

## Changelog

### 0.5.0
- Consolidation of the full 0.3.x development cycle — see [CHANGELOG.md](CHANGELOG.md) for full details

### 0.3.0
- **Streamlined develop-project workflow** - Reduced from 8 to 6 steps
  - Removed `development-planner` agent; `split-plan` skill is now called directly
  - Removed `tracker` plugin dependency; progress tracked via `TASKS.md` file
  - Removed adaptive parallelism modes (`--sequential`, `--aggressive`, `--max-parallel`); fixed parallelism: 3 agents when ≥3 tasks, 1 agent when <3 tasks
  - Added post-implementation comprehensive review loop (max 2 iterations with auto-fix)
  - Single user gate: only master plan review requires approval
- **New Agent: code-reviewer-security** - Security vulnerability analysis
  - Reviews against OWASP Top 10 categories
  - Identifies injection flaws, auth issues, sensitive data exposure, access control weaknesses
  - Provides severity-classified findings (Critical/High/Medium/Low/Info) with remediation code
- **Updated comprehensive-review skill** - Now orchestrates all 5 review agents (added security)
- **Updated senior-developer agent** - Downgraded to Haiku model for cost efficiency

### 0.2.3
- **Four Code Review Agents** - Comprehensive multi-dimensional code review system
  - **product-reviewer** - Verifies implementation against requirements
  - **code-reviewer-business-logic** - Ensures testability and test coverage
  - **code-reviewer-edge-case** - Identifies unhandled edge cases
  - **code-reviewer-architecture** - Reviews 8-phase architectural alignment
  - All agents use Haiku model for fast, cost-effective reviews
- **New Skill: comprehensive-review** - Orchestrates all four review agents in parallel
  - Runs complete analysis in single command (2-5 minutes)
  - Generates consolidated report with prioritized action items
  - Provides executive summary and detailed findings
  - Includes interpretation guides and decision matrices
  - Two comprehensive examples (phase completion, PR readiness)
  - Reference documentation for agent capabilities and review interpretation

### 0.2.2
- **New Agent: software-architect** - Dedicated agent for master plan creation
  - Analyzes requirements documents to understand scope and constraints
  - Investigates existing codebase to understand architecture and patterns
  - Designs comprehensive implementation strategies
  - Creates well-structured master plan documents with Write capabilities
  - Streamlines workflow by writing plans directly without returning content
- **Enhanced develop-project command** - Step 2 now uses software-architect agent
  - Better separation of concerns: software-architect for planning, development-planner for organization
  - Improved workflow efficiency with direct plan file creation

### 0.2.1
- **New Skill: generate-requirements** - Comprehensive requirements documentation generator
  - Launches product-owner agent for structured requirements gathering
  - Single file output: `requirements/[FEATURE_NAME]_REQUIREMENTS.md` (no auxiliary files)
  - Complete requirements template with all standard sections
  - User story patterns and acceptance criteria best practices
  - Full biometric authentication requirements example for reference
  - Comprehensive references for requirements engineering
- **Enhanced product-owner agent** - Strict single-file output policy
  - Now creates only ONE requirements file (eliminated checklists, summaries, indices)
  - Added File Output Policy and File Creation Policy sections
  - Consolidated all content into single comprehensive document

### 0.2.0
- **Enhanced Documentation** - Critical concepts and purpose sections added across all skills
  - Improved command frontmatter with workflow clarity
  - All skills updated with action-oriented, active voice descriptions
  - Better user guidance and documentation consistency

### 0.1.2
- **New Skill: conventional-commit** - Intelligent conventional commit message generator
  - Analyzes git changes and groups related modifications
  - Interactive commit strategy selection (separate/combined/single)
  - Generates properly formatted conventional commit messages
  - Follows Conventional Commits specification
  - Handles edge cases: pre-commit hooks, conflicts, large changesets
  - Supports breaking changes, issue references, and co-authors

### 0.1.1
- **New Agent: product-owner** - Expert requirements engineering agent for translating ideas into structured user stories
  - Proactive engagement when users describe new features
  - Comprehensive requirements gathering with edge cases and acceptance criteria
  - Integration with project context (CLAUDE.md) for pattern alignment
  - Support for both User Stories and Use Cases formats
  - Quality gates for testable, measurable requirements
- Enhanced agent ecosystem with specialized roles (product-owner, development-planner, senior-developer)

### 0.1.0 (Initial Release)
- 8-phase requirements-to-implementation workflow
- Development planner agent for plan analysis and task organization
- Senior developer agent for implementation
- Adaptive parallelism based on complexity
- Tracker integration for progress management
