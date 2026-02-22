# Changelog

All notable changes to the Develop Plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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