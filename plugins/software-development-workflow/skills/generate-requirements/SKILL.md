---
name: generate-requirements
description: This skill should be used when the user asks to "generate requirements", "create requirements", "write requirements", "define requirements", "document requirements", "requirements for feature", or wants to transform ideas into structured requirements documents. Launches the product-owner agent to gather requirements and outputs a single requirements file in a requirements/ folder.
version: 0.1.0
---

# Generate Requirements

## Purpose

Transform ambiguous feature ideas into crystal-clear, actionable requirements documents. This skill launches the product-owner agent to conduct requirements discovery, ask clarifying questions, and generate comprehensive requirements documentation in a standardized format.

**Key outcome:** A single, well-structured requirements file in `requirements/[FEATURE_NAME]_REQUIREMENTS.md` containing all user stories, acceptance criteria, edge cases, and technical considerations.

## When to Use This Skill

Use this skill when:
- Starting a new feature or project phase
- User describes a feature idea that needs clarification
- Requirements need to be documented before implementation
- Stakeholders need clear specifications for development
- Planning meetings require structured requirements output

**Do NOT use this skill when:**
- Requirements are already clearly documented
- User just wants to discuss ideas without documentation
- Task is purely technical (implementation, debugging, refactoring)

## How This Skill Works

### Step 1: Initialize Requirements Directory

Check if a `requirements/` directory exists in the current working directory. If not, create it:

```bash
mkdir -p requirements
```

All requirements files will be stored in this directory.

### Step 2: Launch Product-Owner Agent

Launch the product-owner agent using the Task tool to conduct requirements discovery:

```
Task tool with:
- subagent_type: "develop:product-owner"
- description: "Generate requirements for [feature name]"
- prompt: "Generate requirements for [feature description]. Create a single requirements file in requirements/[FEATURE_NAME]_REQUIREMENTS.md. The file should include all user stories, acceptance criteria, edge cases, technical considerations, and definition of done. Do NOT create separate checklist, summary, or index files."
```

**Critical constraints to pass to agent:**
- **Single file output only**: `requirements/[FEATURE_NAME]_REQUIREMENTS.md`
- **No auxiliary files**: No checklists, summaries, or index files
- **Uppercase naming**: Feature name in UPPERCASE with underscores (e.g., `BIOMETRIC_SIGNIN_REQUIREMENTS.md`)

### Step 3: Agent Execution

The product-owner agent will:
1. Read existing project context (CLAUDE.md, related files)
2. Ask clarifying questions using AskUserQuestion tool
3. Validate understanding and fill knowledge gaps
4. Generate comprehensive requirements in a single file
5. Save to `requirements/[FEATURE_NAME]_REQUIREMENTS.md`

**The agent is constrained to create only ONE file.**

### Step 4: Verify Output

After the agent completes:
1. Verify the requirements file exists in `requirements/`
2. Check that no auxiliary files were created
3. Confirm the file contains all required sections

If auxiliary files were created by mistake, consolidate them into the single requirements file and delete the extras.

## Requirements File Structure

The generated requirements file should follow this structure:

```markdown
# [Feature Name] Requirements

## Summary
Brief overview of the feature and its business value.

## User Stories

### Story 1: [Title]
As a [user role]
I want to [action]
So that [benefit]

**Acceptance Criteria:**
1. Given [precondition]
   When [action]
   Then [expected result]

**Edge Cases:**
- [Scenario]: [Expected behavior]

**Technical Considerations:**
- [Constraint or requirement]

**Definition of Done:**
- [ ] [Testable criterion]
- [ ] [Testable criterion]

### Story 2: [Title]
[Repeat structure...]

## Technical Considerations

### Architecture
[Architectural decisions and patterns]

### Dependencies
[External dependencies and integration points]

### Performance Requirements
[Performance metrics and expectations]

### Security Considerations
[Security requirements and constraints]

## Out of Scope
[Explicitly define what is NOT included]

## Success Metrics
[How to measure feature success]
```

## File Naming Convention

Requirements files use this naming pattern:
- **Format**: `[FEATURE_NAME]_REQUIREMENTS.md`
- **Case**: UPPERCASE with underscores
- **Examples**:
  - `BIOMETRIC_SIGNIN_REQUIREMENTS.md`
  - `SHOPPING_CART_REQUIREMENTS.md`
  - `USER_PROFILE_REQUIREMENTS.md`
  - `API_AUTHENTICATION_REQUIREMENTS.md`

## Quality Standards

Requirements files must be:
- **Complete**: All user stories have acceptance criteria
- **Testable**: Every criterion is measurable and verifiable
- **Clear**: No ambiguous language or assumptions
- **Scoped**: Explicit boundaries of what's included/excluded
- **Actionable**: Developers know exactly what to build

## Edge Cases and Troubleshooting

### Agent Creates Multiple Files

**Problem**: Agent creates checklist, summary, or index files in addition to requirements.

**Solution**:
1. Read all created files
2. Consolidate content into the main requirements file
3. Delete auxiliary files
4. Remind the agent about the single-file constraint

### Requirements File Missing Sections

**Problem**: Generated requirements lack key sections (edge cases, technical considerations, etc.)

**Solution**:
1. Review the requirements file
2. Identify missing sections
3. Ask the agent to update the requirements file with missing content
4. Ensure updates go into the same file, not new files

### Feature Name Unclear

**Problem**: Feature name is ambiguous or too generic.

**Solution**:
1. Use AskUserQuestion to clarify the feature name
2. Suggest a specific, descriptive name
3. Use that name for the requirements file

## Example Usage

### Example 1: New Feature

**User request**: "We need biometric authentication for mobile login"

**Execution**:
1. Create `requirements/` directory if needed
2. Launch product-owner agent with prompt:
   ```
   "Generate requirements for biometric authentication mobile login feature.
   Create a single file: requirements/BIOMETRIC_SIGNIN_REQUIREMENTS.md.
   Include all user stories, acceptance criteria, edge cases, and technical
   considerations. Do NOT create separate files."
   ```
3. Agent asks clarifying questions:
   - Which biometric types? (Face ID, Touch ID, both?)
   - Fallback authentication method?
   - Platform support (iOS, Android, both?)
4. Agent generates `requirements/BIOMETRIC_SIGNIN_REQUIREMENTS.md`
5. Verify single file created

### Example 2: Feature Enhancement

**User request**: "Improve the search functionality with filters and sorting"

**Execution**:
1. Check for existing requirements in `requirements/SEARCH_*.md`
2. Launch product-owner agent with context:
   ```
   "Generate requirements for enhanced search functionality with filters
   and sorting. Review existing search implementation in [files]. Create
   single file: requirements/SEARCH_ENHANCEMENT_REQUIREMENTS.md."
   ```
3. Agent reviews existing code and requirements
4. Agent generates comprehensive requirements
5. Single file output: `requirements/SEARCH_ENHANCEMENT_REQUIREMENTS.md`

## Additional Resources

### Reference Files

For detailed requirements patterns:
- **`references/requirements-template.md`** - Complete template with all sections
- **`references/user-story-patterns.md`** - User story formats and examples

### Example Files

Working examples in `examples/`:
- **`BIOMETRIC_SIGNIN_REQUIREMENTS.md`** - Complete requirements example
- **`API_INTEGRATION_REQUIREMENTS.md`** - Technical requirements example

## Integration with Other Skills

This skill integrates with:
- **`develop-project`** skill: Generate requirements before project planning
- **`split-plan`** skill: Requirements inform phase-based planning
- **`categorize-task`** skill: Use requirements to categorize implementation tasks

## Critical Reminders

1. **Single file output only** - No checklists, summaries, or auxiliary files
2. **Requirements folder** - Always in `requirements/` directory
3. **Uppercase naming** - `[FEATURE_NAME]_REQUIREMENTS.md` format
4. **Comprehensive content** - All sections in one file
5. **Agent-driven** - Let product-owner agent handle discovery and generation

Focus on launching the product-owner agent with clear constraints and verifying single-file output compliance.