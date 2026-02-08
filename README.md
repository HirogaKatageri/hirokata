# HiroKata Claude Code Plugin Marketplace

A curated collection of Claude Code plugins for enhanced development workflows, featuring intelligent task tracking and automated requirements-to-implementation pipelines.

## Overview

This marketplace provides production-ready Claude Code plugins that extend Claude's capabilities with specialized agents, skills, and workflows designed for software development teams.

## Available Plugins

### 1. Tracker Plugin (v0.2.0)

A comprehensive project and task management system with intelligent agents and structured tracking.

**Features:**
- Phase-based project organization (Planning, Implementation, Testing, etc.)
- Feature-based tracks that span across phases
- Intelligent tracker agent for conversational project management
- Individual skills for direct control (/create-tracker, /add-task, /mark-status, etc.)
- Progress reports with visual indicators
- Task dependencies and complexity tracking

**Use Cases:**
- Managing multi-phase software projects
- Coordinating parallel feature development
- Sprint planning and progress tracking
- Team task organization

[View Documentation →](plugins/cc-tracker-plugin/README.md)

### 2. Develop Plugin (v0.2.3)

Automated requirements-to-implementation workflow using a 7-phase clean architecture approach with intelligent commit generation, dedicated software architecture planning, and comprehensive code review system.

**Features:**
- Converts requirements documents into working code
- 7-phase clean architecture (Foundational → Models → Services → Data → Rules → State Management → UI)
- Adaptive parallelism (1-8 developer agents based on task complexity)
- **NEW in 0.2.3: Four specialized code review agents**
  - Product reviewer for requirements compliance
  - Business logic reviewer for testability and test coverage
  - Edge case reviewer for boundary conditions and error handling
  - Architecture reviewer for clean architecture alignment
- **NEW in 0.2.3: Comprehensive review skill** - Parallel multi-dimensional code review in 2-5 minutes
- Software architect agent for comprehensive master plan creation
- Conventional commit generator with intelligent change grouping
- Resume capability for interrupted workflows
- Integrates with tracker system for real-time progress
- Specialized agents: software architect, product owner, development planner, senior developer, and 4 code reviewers

**Use Cases:**
- Transforming requirements into implementation plans
- Automated code generation following clean architecture
- Large-scale feature development
- Structured refactoring projects
- Creating semantic, well-organized commit history
- Pre-PR comprehensive code quality reviews
- Requirements compliance verification
- Test coverage and edge case analysis

[View Documentation →](plugins/cc-develop-plugin/README.md)

## Installation

### Option 1: Clone the Entire Marketplace

```bash
git clone https://github.com/hirogakatageri/hirokata-cc-marketplace.git
cd hirokata-cc-marketplace
```

Then use with Claude Code:

```bash
cc --plugin-dir ./plugins/cc-tracker-plugin
# or
cc --plugin-dir ./plugins/cc-develop-plugin
```

### Option 2: Install Individual Plugins

Copy specific plugins to your project:

```bash
# Install tracker plugin
cp -r hirokata-cc-marketplace/plugins/cc-tracker-plugin /path/to/your-project/.claude-plugin/tracker

# Install develop plugin
cp -r hirokata-cc-marketplace/plugins/cc-develop-plugin /path/to/your-project/.claude-plugin/develop
```

### Option 3: Use Multiple Plugins

To use both plugins simultaneously:

```bash
# Create a .claude-plugin directory in your project
mkdir -p /path/to/your-project/.claude-plugin

# Copy both plugins
cp -r hirokata-cc-marketplace/plugins/cc-tracker-plugin /path/to/your-project/.claude-plugin/tracker
cp -r hirokata-cc-marketplace/plugins/cc-develop-plugin /path/to/your-project/.claude-plugin/develop
```

Claude Code will automatically load all plugins in `.claude-plugin/`.

## Quick Start

### Using Tracker Plugin

```bash
# Create a new tracker
/tracker:create-tracker my-project

# Add tasks
/tracker:add-task my-project --phase=1 --track=authentication

# Update status
/tracker:mark-status my-project

# Review progress
/tracker:review-tracker my-project
```

Or use the intelligent agent:

```
You: Help me set up tracking for my new web app with authentication and dashboard features

tracker:tracker Agent: [Guides you through structured project setup with intelligent recommendations]
```

### Using Develop Plugin

```bash
# Start from requirements
/develop:develop-project requirements.md

# The plugin will:
# 1. Create a comprehensive master plan
# 2. Wait for your review
# 3. Organize tasks into 7 phases
# 4. Let you select which phases to execute
# 5. Spawn developer agents to implement code
# 6. Track progress in real-time

# View progress anytime
/tracker:review-tracker my-project
```

### Using Both Together

```bash
# Use develop plugin for complete project workflow
/develop:develop-project requirements/my-app.md

# The develop plugin automatically:
# - Creates a tracker for the project
# - Organizes work into phases and tracks
# - Updates tracker as implementation progresses

# Review overall progress anytime
/tracker:review-tracker my-app

# Or use tracker skills directly for manual task management
/tracker:add-task my-app --phase=1 --track=authentication
```

## Plugin Architecture

Both plugins follow Claude Code plugin best practices:

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
│   ├── cc-tracker-plugin/   # Task tracking plugin
│   └── cc-develop-plugin/   # Development workflow plugin
├── LICENSE                  # MIT License
└── README.md               # This file
```

## Roadmap

### Planned Plugins

- **Test Plugin**: Automated test generation and execution
- **Review Plugin**: Code review assistance and suggestions
- **Deploy Plugin**: Deployment automation workflows
- **Docs Plugin**: Documentation generation from code

### Enhancements

- Web-based marketplace browser
- Plugin dependency management
- Version compatibility checking
- Community plugin submissions

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

- [Claude Code Documentation](https://docs.anthropic.com/claude/docs)
- [Plugin Development Guide](https://docs.anthropic.com/claude/docs/claude-code-plugins)
- [Tracker Plugin Docs](plugins/cc-tracker-plugin/README.md)
- [Develop Plugin Docs](plugins/cc-develop-plugin/README.md)