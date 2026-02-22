# Changelog

All notable changes to the HiroKata Claude Code Plugin Marketplace will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
- Test Plugin: Automated test generation and execution
- Review Plugin: Code review assistance and suggestions
- Deploy Plugin: Deployment automation workflows
- Docs Plugin: Documentation generation from code
- Web-based marketplace browser
- Plugin dependency management
- Version compatibility checking

## [0.4.0] - 2026-02-22

### Updated
- **Develop Plugin v0.3.0** - Security review and 8-phase architecture upgrade
  - New code-reviewer-security agent with OWASP Top 10 coverage
  - Phase 8 (Tests) added to clean architecture workflow
  - develop-project moved from commands to skills
  - estimate-task removed; complexity scoring integrated into split-plan
  - development-planner model updated to haiku for efficiency
  - senior-developer agent enhanced with strict documentation guidelines

### Improved
- Security posture with automated vulnerability detection in code reviews
- Architecture clarity by separating test tasks into dedicated Phase 8
- Workflow consistency with develop-project as a skill
- Developer documentation quality guidelines

## [0.3.0] - 2026-02-08

### Added
- Root changelog for tracking marketplace-level changes
- Enhanced documentation structure across all plugins

### Updated
- **Develop Plugin v0.2.3** - Comprehensive code review system
  - Four specialized review agents (product, business logic, edge case, architecture)
  - comprehensive-review skill for parallel multi-dimensional analysis
  - Complete code quality assurance workflow
  - Requirements compliance verification
  - Test coverage and edge case identification

### Improved
- Code quality tooling with systematic review capabilities
- Pre-PR validation workflows
- Requirements traceability from planning to implementation

## [0.2.0] - 2026-02-08

### Updated
- **Develop Plugin v0.2.2** - Software architect agent
  - New dedicated agent for master plan creation
  - Analyzes requirements and existing codebase
  - Creates comprehensive implementation strategies
  - Streamlined workflow with direct plan writing
- **Develop Plugin v0.2.1** - Requirements generation
  - generate-requirements skill for structured requirements documentation
  - Enhanced product-owner agent with single-file output policy
  - Comprehensive requirements template and examples

### Improved
- Master plan creation efficiency with specialized architect agent
- Requirements gathering workflow with structured templates
- Separation of concerns between planning and implementation

## [0.1.0] - 2026-02-07

### Updated
- **Tracker Plugin v0.2.0** - Enhanced documentation
  - Purpose sections for all 18 skills
  - Improved skill descriptions with trigger examples
  - Better skill discoverability and user guidance
- **Develop Plugin v0.2.0** - Documentation improvements
  - Critical concepts section in develop-project command
  - Enhanced workflow documentation with 8-step process
  - Action-oriented skill descriptions

### Improved
- Documentation consistency across both plugins
- User guidance and clarity in all skills
- Plugin discoverability and usage patterns

## [0.0.1] - 2026-01-27

### Added
- Initial marketplace structure
- **Tracker Plugin v0.1.0**
  - Phase-based project organization
  - Feature-based tracks
  - Intelligent tracker agent
  - 18 individual skills for direct control
  - Progress reports with visual indicators
  - Task dependencies and complexity tracking
- **Develop Plugin v0.1.0**
  - 7-phase clean architecture workflow
  - Adaptive parallel execution (1-8 agents)
  - Master plan and phase plan generation
  - Tracker integration
  - Development planning and execution agents
- Comprehensive marketplace README
- Individual plugin documentation
- MIT License
- Contributing guidelines

### Infrastructure
- Git repository initialization
- Plugin directory structure
- Marketplace manifest (.claude-plugin/marketplace.json)

## Release Notes

### Version Numbering
- Marketplace versions reflect the most significant plugin update
- Individual plugins maintain independent semantic versioning
- Major marketplace updates (new plugins, breaking changes) increment major version
- Plugin updates increment minor or patch versions accordingly

### Plugin Compatibility
- All plugins are designed to work independently or together
- Develop plugin integrates with Tracker plugin when both are installed
- No breaking changes between current versions

### Migration Notes
- **0.3.0 → 0.4.0**: Minor breaking change — estimate-task skill removed; develop-project moved to skills
- **0.2.0 → 0.3.0**: No breaking changes, new review features are additive
- **0.1.0 → 0.2.0**: No breaking changes, enhanced documentation and new agents
- **0.0.1 → 0.1.0**: No breaking changes, documentation improvements

## See Also
- [Tracker Plugin Changelog](plugins/cc-tracker-plugin/CHANGELOG.md)
- [Develop Plugin Changelog](plugins/cc-develop-plugin/CHANGELOG.md)
