# HiroKata Claude Code Plugin Marketplace

A curated collection of Claude Code plugins for enhanced development workflows, featuring automated requirements-to-implementation pipelines.

**[View Changelog](CHANGELOG.md)** | **Version 2.1.2**

## What's New

### v2.1.0 - Apr 2026

**Guild Plugin v1.1.0** - Added `guild:release` skill; architect now has a research gate that auto-dispatches the researcher when it can't plan responsibly; added evergreen `.guild/docs/` knowledge base maintained by the researcher and read by the architect; check-in keeps `CHANGELOG.md`'s `[Unreleased]` section current as requirements complete. Commit workflow now uses `software:conventional-commit`.

**Software Plugin v1.0.4** - Refactored `conventional-commit` skill for cleaner structure (Best Practices moved to reference file).

[View Full Changelog](CHANGELOG.md)

## Overview

This marketplace provides production-ready Claude Code plugins that extend Claude's capabilities with specialized agents, skills, and workflows designed for software development teams.

## Available Plugins

### 1. Software Plugin (v1.0.4)

Automated requirements-to-implementation workflow using an 8-phase clean architecture approach with intelligent commit generation, dedicated software architecture planning, and comprehensive code review system.

**Features:**
- Converts requirements documents into working code
- 8-phase clean architecture (Foundational → Models → Services → Data → Rules → State Management → UI → Tests)
- Fixed parallelism (up to 3 developer agents per phase)
- Five specialized code review agents
  - Product reviewer for requirements compliance
  - Business logic reviewer for testability and test coverage
  - Edge case reviewer for boundary conditions and error handling
  - Architecture reviewer for clean architecture alignment
  - Security reviewer for OWASP Top 10 vulnerability detection
- Comprehensive review skill - Parallel multi-dimensional code review in 2-5 minutes
- Post-implementation review loop with auto-fix (up to 2 iterations)
- Software architect agent for comprehensive master plan creation
- Conventional commit generator with intelligent change grouping
- Three-state resume capability for interrupted workflows (TASKS.md, master plan only, or fresh start)
- Progress tracked via TASKS.md file
- 8 specialized agents: software architect, product owner, senior developer, and 5 code reviewers

**Use Cases:**
- Transforming requirements into implementation plans
- Automated code generation following clean architecture
- Large-scale feature development
- Structured refactoring projects
- Creating semantic, well-organized commit history
- Pre-PR comprehensive code quality reviews
- Requirements compliance verification
- Test coverage and edge case analysis

[View Documentation](plugins/software-project/README.md)

### 2. Guild Plugin (v1.1.0)

Continuous agent orchestration through a persistent board-driven work cycle. The guild tracks requirements, tasks, and progress across sessions — no per-session setup required. Say "check in" to begin.

**How it works:**

A new requirement flows through an automatic chain of specialized agents:

```
product-owner → architect → developers (up to 3 parallel)
    → test-writer → 4 reviewers in parallel
    → [fix cycle if issues found]
```

**Skills:**

| Skill | Trigger Phrases |
|-------|----------------|
| `guild:check-in` | "check in", "clock in", "standup", "guild check in", "let's get to work", "start working", "daily standup", "I'm here", "reporting in" |
| `guild:guild-status` | "guild status", "board status", "show the board", "what's on the board", "project status", "guild board", "what's happening" |
| `guild:new-requirement` | "add a requirement", "new requirement", "I need a feature", "add to the guild", "create requirement", "queue a feature", "I want to build" |
| `guild:clear-board` | "clear the board", "reset the guild", "start fresh", "wipe the board", "clear all tasks", "reset the board" |
| `guild:release` | "cut a release", "release the guild", "ship it", "tag a version", "guild release" |

**Agents:**

9 specialized agents — product-owner, architect, developer, test-writer, and 4 code reviewers (security, architecture, business-logic, edge-case) plus a researcher for technology investigation.

**Use Cases:**
- Long-running multi-session feature development
- Autonomous planning and implementation from high-level requirements
- Projects requiring structured requirement → plan → code → test → review cycles
- Teams wanting persistent work state across Claude Code sessions

[View Documentation](plugins/guild/README.md)

## Installation

### Option 1: Clone the Entire Marketplace

```bash
git clone https://github.com/hirogakatageri/hirokata-cc-marketplace.git
cd hirokata
```

Then use with Claude Code:

```bash
cc --plugin-dir ./plugins/software-project
```

### Option 2: Install Individual Plugins

Copy a plugin to your project:

```bash
cp -r hirokata/plugins/software-project /path/to/your-project/.claude-plugin/software
```

Claude Code will automatically load all plugins in `.claude-plugin/`.

## Quick Start

### Using Develop Plugin

```bash
# Start from requirements
/software:develop-project requirements.md

# The plugin will:
# 1. Create a comprehensive master plan (software-architect agent)
# 2. Wait for your review and approval
# 3. Split plan into 8 phases and build TASKS.md
# 4. Execute all 8 phases sequentially (up to 3 agents per phase)
# 5. Run comprehensive review and fix issues (up to 2 iterations)
# 6. Generate final summary report
```

## Plugin Architecture

Plugins follow Claude Code plugin best practices:

```
plugin-name/
├── .claude-plugin/
│   └── plugin.json          # Plugin manifest
├── agents/                  # Intelligent agents
│   └── agent-name/
│       └── AGENT.md
├── skills/                  # Invokable skills
│   └── skill-name/
│       └── SKILL.md
├── commands/                # Command definitions
│   └── command-name.md
└── README.md               # Plugin documentation
```

## Requirements

- **Claude Code**: Latest version
- **Git**: For version control integration
- **Node.js/npm** (optional): For some development workflows

## Contributing

We welcome contributions to existing plugins or new plugin additions.

### Adding a New Plugin

1. Fork this repository
2. Create your plugin in `plugins/your-plugin-name/`
3. Follow the plugin architecture structure
4. Add comprehensive README.md
5. Update marketplace.json in `.claude-plugin/`
6. Submit a pull request

### Plugin Guidelines

- Follow Claude Code plugin best practices
- Include comprehensive documentation
- Provide clear examples and use cases
- Test with Claude Code before submitting
- Use semantic versioning

### Improving Existing Plugins

1. Fork this repository
2. Create a feature branch
3. Make your improvements
4. Update relevant documentation
5. Test thoroughly
6. Submit a pull request

## Marketplace Structure

```
hirokata-cc-marketplace/
├── .claude-plugin/
│   └── marketplace.json     # Marketplace manifest
├── plugins/
│   ├── software-project/    # Software development workflow plugin
│   ├── project-management/  # Project management plugin
│   └── guild/               # Continuous agent orchestration plugin
├── LICENSE                  # MIT License
└── README.md               # This file
```

## Roadmap

See [CHANGELOG.md](CHANGELOG.md) for detailed version history and upcoming features.

### Planned Plugins

- **Test Plugin**: Automated test generation and execution
- **Deploy Plugin**: Deployment automation workflows
- **Docs Plugin**: Documentation generation from code

### Planned Enhancements

- Web-based marketplace browser
- Plugin dependency management
- Version compatibility checking
- Community plugin submissions
- Enhanced plugin discovery and search

## License

MIT License - see [LICENSE](LICENSE) file for details.

Copyright (c) 2026 Gian Patrick Quintana

## Author

**Gian Patrick Quintana**
- Email: gian.quintana@hirokata.dev
- GitHub: [@hirogakatageri](https://github.com/hirogakatageri)

## Support

For issues, questions, or feature requests:

1. Check the individual plugin documentation
2. Search existing issues
3. Open a new issue with details about your use case
4. Include relevant error messages or logs

## Acknowledgments

Built for the Claude Code ecosystem by developers who believe in:
- Automated workflows
- Intelligent agents
- Clean architecture
- Developer productivity

## Resources

### Documentation
- [Marketplace Changelog](CHANGELOG.md)
- [Software Plugin Docs](plugins/software-project/README.md) | [Changelog](plugins/software-project/CHANGELOG.md)
- [Guild Plugin Docs](plugins/guild/README.md)
- [Project Management Plugin Docs](plugins/project-management/README.md)

### Claude Code
- [Claude Code Documentation](https://docs.anthropic.com/claude/docs)
- [Plugin Development Guide](https://docs.anthropic.com/claude/docs/claude-code-plugins)