# Changelog

All notable changes to the Develop Plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] - 2026-03-23

### Fixed
- **develop-project skill** - Replaced `TodoWrite` todos with TASKS.md task entries in the post-implementation review loop; review fix issues are now tracked as a `## Review Fixes` section in `TASKS.md` using the same `[ ]`/`[~]`/`[x]` markers as the rest of the workflow

## [0.6.0] - 2026-03-06

### Changed
- **senior-developer agent** - Added Phase 0 (Understand Requirements): agent now reads the requirements document before any documentation or code analysis; maps each task to its requirements section and notes acceptance criteria as the definition of done
- **develop-project skill** - Switched from batch-per-task execution to team-based execution: 3 senior-developer agents are spawned once per phase, tasks distributed round-robin, each developer works tasks sequentially — no repeated spawning between batches
- **senior-developer agent model** - Upgraded from Haiku to inherit for improved implementation quality

## [0.5.0] - 2026-03-03

### Summary

Consolidation release covering the full 0.3.x development cycle. All changes below were delivered incrementally across 0.3.0–0.3.2 and are now collected here as a stable milestone.

### Added
- **code-reviewer-security agent** - Dedicated OWASP Top 10 security review (injection, broken auth, XSS, sensitive data exposure, access control, cryptography)
- **Phase 8 (Tests)** - Dedicated testing phase added to the clean architecture workflow (unit, integration, e2e)
- **comprehensive-review skill** - Orchestrates all 5 review agents (product, business-logic, edge-case, architecture, security) in parallel; produces consolidated report with prioritized action items and executive summary

### Changed
- **develop-project workflow** - Streamlined from 8 to 6 steps with a single user gate (master plan review only); all phases and post-implementation review run automatically
- **Progress tracking** - Switched from tracker plugin integration to TASKS.md for phase and task tracking
- **development-planner agent** - Removed; split-plan skill is now called directly from develop-project
- **senior-developer agent model** - Downgraded from Sonnet to Haiku for cost efficiency during parallel phase execution
- **Resume support** - Three-state detection: (1) TASKS.md exists → resume execution; (2) master plan exists without TASKS.md → resume from split-plan; (3) neither exists → fresh run
- **develop-project** - Moved from commands to skills for consistency
- **split-plan skill** - Complexity scoring integrated; estimate-task removed
- **categorize-task skill** - Updated to reflect 8-phase architecture

### Removed
- **estimate-task skill** - Complexity scoring consolidated into split-plan
- **Tracker plugin dependency** - Progress tracking is now self-contained via TASKS.md

### Fixed
- **Agent frontmatter YAML** - Converted single-line description strings to proper YAML block scalar format across all 8 agents

### Parallelism
- Fixed rule: 3 `develop:senior-developer` agents when phase has ≥3 tasks, 1 agent otherwise

## [0.3.2] - 2026-03-03

### Fixed
- **Agent frontmatter** - Converted single-line description strings to proper YAML block scalar format across all agents (code-reviewer-architecture, code-reviewer-business-logic, code-reviewer-edge-case, code-reviewer-security, product-owner, product-reviewer, senior-developer, software-architect)

## [0.3.1] - 2026-03-02

### Changed
- **develop-project workflow** - Streamlined from 8 steps to 6 steps with a single user gate (master plan review only); execution auto-continues across all phases with a post-implementation review after completion
- **Progress tracking** - TASKS.md replaces tracker plugin integration for phase and task tracking; tracker-based tracking removed
- **development-planner agent** - Removed; split-plan skill is now called directly from develop-project, with results reported back to the caller instead of prompting the user for confirmation
- **senior-developer agent model** - Downgraded from Sonnet to Haiku to reduce cost during parallel phase execution where multiple senior-developer agents run concurrently
- **Resume support** - Expanded to three-state detection: (1) TASKS.md exists → show per-phase task summary and jump to execution; (2) master plan exists without TASKS.md → skip plan regeneration and go to split-plan; (3) neither exists → fresh run from Step 1

### Improved
- **Post-implementation review** - Comprehensive review loop runs once after all phases complete, with a maximum of 2 fix iterations and auto-continuation
- **Parallelism model** - Simplified to fixed rule: 3 agents when task count is ≥ 3, 1 agent otherwise (replaces previous adaptive system)

## [0.3.0] - 2026-02-22

### Added
- **code-reviewer-security agent** - Dedicated security review agent expanding parallel review from 4 to 5 agents
  - OWASP Top 10 vulnerability detection (injection, broken auth, XSS, etc.)
  - Sensitive data exposure and hardcoded secrets identification
  - Cryptography and authentication flaw analysis
  - Security findings prioritized above all other review categories
  - Integrated into comprehensive-review skill for automated security checks
- **Phase 8 (Tests)** - Added dedicated testing phase to clean architecture workflow
  - Separate phase for unit tests, integration tests, and e2e tests
  - Cleaner separation between production code phases and test phases
  - Updated all agents and skills to reflect 8-phase structure

### Changed
- **develop-project** - Moved from commands to skills for consistency
- **development-planner agent** - Updated model from sonnet to haiku
- **categorize-task skill** - Updated to reflect 8-phase architecture
- **split-plan skill** - Complexity scoring integrated; estimate-task removed
- **senior-developer agent** - Added comprehensive documentation and comment guidelines
  - Explicit prohibition of creating markdown files and READMEs
  - Rules for when to add inline comments (business logic, performance, edge cases)
  - Emphasis on self-documenting code with minimal comments

### Removed
- **estimate-task skill** - Complexity scoring consolidated into split-plan skill

### Improved
- Security coverage with automated OWASP-aligned review
- Architecture clarity with dedicated test phase
- Developer documentation guidelines for cleaner codebases

## [0.2.3] - 2026-02-08

### Added
- **Four Code Review Agents** - Comprehensive multi-dimensional code review system
  - **product-reviewer** (Magenta, Haiku) - Verifies implementation against requirements
    - Compares changes to master plans, phase plans, and requirements documents
    - Identifies missing or incomplete functionality
    - Reports implementation compliance with evidence
  - **code-reviewer-business-logic** (Green, Haiku) - Ensures testability and test coverage
    - Verifies business logic is designed for testability
    - Identifies missing unit tests and untestable code patterns
    - Provides refactoring suggestions for improved testability
  - **code-reviewer-edge-case** (Yellow, Haiku) - Identifies unhandled edge cases
    - Analyzes code for boundary conditions and error scenarios
    - Categorizes findings by severity (Critical/Warning/Info)
    - Suggests defensive programming improvements
  - **code-reviewer-architecture** (Cyan, Haiku) - Reviews architectural alignment
    - Verifies clean architecture principles and 8-phase structure
    - Identifies dependency violations and layer misplacements
    - Provides architectural improvement recommendations

- **comprehensive-review skill** - Orchestrates all four review agents in parallel
  - Runs complete multi-dimensional analysis in single command
  - Generates consolidated report with prioritized action items
  - Provides executive summary across all review dimensions
  - Includes detailed interpretation guides and decision matrices
  - Two comprehensive examples: phase completion and PR readiness reviews
  - Reference documentation: agent capabilities and review interpretation

### Improved
- Code quality assurance workflow with systematic multi-dimensional reviews
- Requirements compliance verification with automated tracking
- Test coverage analysis integrated into development workflow
- Edge case identification for production-ready code
- Architectural alignment verification throughout development

## [0.2.2] - 2026-02-08

### Added
- **software-architect agent** - New dedicated agent for master plan creation
  - Analyzes requirements documents to understand scope and constraints
  - Investigates existing codebase to understand architecture and patterns
  - Designs comprehensive implementation strategies
  - Creates single, well-structured master plan documents
  - Has Write capabilities to save plans directly without returning content

### Changed
- **develop-project command** - Updated Step 2 to use software-architect agent
  - Uses `develop:software-architect` subagent_type
  - Agent writes master plan directly to `.trackers/{BASE_NAME}/plans/{BASE_NAME}-master-plan.md`
  - Streamlined workflow proceeds directly to Step 3 after plan creation
  - No need to return plan content to main agent

### Improved
- Master plan creation workflow efficiency
- Separation of concerns: software-architect for planning, development-planner for organization
- Documentation clarity about agent roles and responsibilities

## [0.2.1] - 2026-02-07

### Added
- **generate-requirements skill** - Comprehensive requirements documentation generator
  - Launches product-owner agent for structured requirements gathering
  - Single file output: `requirements/[FEATURE_NAME]_REQUIREMENTS.md`
  - Complete requirements template with all sections
  - User story patterns and best practices
  - Full biometric authentication requirements example
  - References for requirements engineering and user story writing

### Changed
- **product-owner agent** - Enhanced with strict file output policy
  - Now creates only ONE requirements file (no auxiliary files)
  - Added File Output Policy section with explicit constraints
  - Added File Creation Policy section as critical constraint
  - Consolidated all content (summaries, checklists) into single file

### Improved
- Product-owner agent output consistency
- Requirements documentation workflow
- Single-file requirements approach eliminates clutter

## [0.2.0] - 2026-02-07

### Added
- Critical concepts section to develop-project command frontmatter
- Purpose sections to all reference skills (categorize-task, estimate-task, split-plan)
- Enhanced workflow documentation with 8-step process clarity

### Changed
- Improved skill descriptions to be more action-oriented and concise
- Enhanced conventional-commit skill documentation for better clarity
- Made all documentation more direct and user-focused
- Updated skill descriptions from passive to active voice

### Improved
- Documentation consistency across all skills
- Command frontmatter with critical workflow concepts
- User guidance in all skill files

## [0.1.2] - 2026-02-07

### Added
- Conventional commit skill for intelligent commit message generation
- Automated change grouping and commit strategy selection

### Changed
- Enhanced develop-project command documentation
- Improved README with conventional commit feature

## [0.1.1] - 2026-02-07

### Added
- Product owner agent for requirements gathering
- Enhanced documentation structure

### Changed
- Improved agent descriptions and triggering conditions

## [0.1.0] - 2026-01-27

### Added
- Initial release
- 8-phase clean architecture workflow
- Adaptive parallel execution (1-8 agents)
- Master plan and phase plan generation
- Tracker integration
- Development planning and execution agents