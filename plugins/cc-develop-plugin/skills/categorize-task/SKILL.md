---
name: categorize-task
description: Reference guide for classifying development tasks into the 8-phase clean architecture structure (Foundational → Models → Services → Data → Rules → State Management → UI → Tests). Use when you need to determine which architectural phase a task belongs to.
user-invocable: false
---

# Categorize Task

Classify development tasks into the 8-phase clean architecture structure. This helps organize work into the correct architectural layer.

## Purpose

Provide a reference guide for determining which architectural phase (Foundational → Models → Services → Data → Rules → State Management → UI → Tests) a development task belongs to.

## The 8 Phases

Tasks must be classified into one of these sequential phases:

### Phase 1: Foundational
**Purpose**: Abstract classes, base setup, toolings, utilities, infrastructure

**Belongs here if the task involves**:
- Setting up base infrastructure
- Creating abstract classes or interfaces
- Configuring tooling or build setup
- Dependency injection framework
- Environment configuration
- Shared utilities and helpers
- Project scaffolding

**Examples**:
- "Set up dependency injection container"
- "Create base repository interface"
- "Configure environment variables"
- "Add logging utility"
- "Set up project structure"

---

### Phase 2: Models
**Purpose**: Entities, models, JSON classes, data structures

**Belongs here if the task involves**:
- Defining a data structure
- Creating an entity or model class
- Data serialization/deserialization
- DTOs (Data Transfer Objects)
- Value objects
- Enums and constants

**Examples**:
- "Create User model with fields"
- "Define Product entity"
- "Add OrderStatus enum"
- "Create UserDTO for API responses"
- "Define Address value object"

---

### Phase 3: Services
**Purpose**: APIs, external services, network layer

**Belongs here if the task involves**:
- Calling an external API
- Integrating with a third-party service
- Network communication
- REST/GraphQL clients
- HTTP/networking layer
- API error handling

**Examples**:
- "Implement authentication API client"
- "Create payment service integration"
- "Add REST API endpoints for products"
- "Integrate with Stripe API"
- "Implement GraphQL query client"

---

### Phase 4: Data
**Purpose**: Repositories, DAOs, data access layer, local storage

**Belongs here if the task involves**:
- Accessing local storage
- Implementing a repository
- Data persistence or caching
- Database access objects
- Local storage (SQLite, SharedPreferences, etc.)
- Cache implementations

**Examples**:
- "Implement UserRepository"
- "Create ProductDAO for database access"
- "Add local cache for API responses"
- "Implement SQLite database schema"
- "Create data source abstraction"

---

### Phase 5: Rules
**Purpose**: Use cases, business rules, domain logic

**Belongs here if the task involves**:
- Business logic or validation
- Use case or workflow
- Domain-specific rules
- Business workflows
- Domain event handlers
- Complex validation rules

**Examples**:
- "Implement login use case"
- "Add business validation for orders"
- "Create checkout workflow"
- "Implement password strength validator"
- "Add discount calculation logic"

---

### Phase 6: State Management
**Purpose**: View models, presenters, state handlers, controllers

**Belongs here if the task involves**:
- Managing application state
- View models or presenters
- State transitions
- State management setup (Bloc, Provider, Riverpod, Redux, etc.)
- Controllers
- Reactive state handling

**Examples**:
- "Create LoginViewModel"
- "Implement ProductListBloc"
- "Add state management for cart"
- "Create AuthenticationCubit"
- "Implement Redux store for user data"

---

### Phase 7: UI
**Purpose**: Widgets, components, screens, views, user interface

**Belongs here if the task involves**:
- Screens, pages, or components
- User interface rendering
- User interaction handling
- Navigation setup
- Layouts and styling
- Visual elements

**Examples**:
- "Create login screen"
- "Build product card component"
- "Implement navigation flow"
- "Add loading spinner widget"
- "Create responsive layout for dashboard"

---

### Phase 8: Tests
**Purpose**: Unit tests, integration tests, e2e tests, test utilities, test fixtures

**Belongs here if the task involves**:
- Writing unit tests for business logic or services
- Creating integration tests across layers
- Building end-to-end test scenarios
- Setting up test utilities, mocks, or fixtures
- Configuring test infrastructure (test runners, coverage tools)
- Writing test helpers or shared test data

**Examples**:
- "Write unit tests for login use case"
- "Add integration tests for checkout flow"
- "Create e2e tests for authentication"
- "Set up mock repository for testing"
- "Add test fixtures for product data"

---

## Classification Process

To classify a task, ask these questions in order:

1. **Is it foundation/infrastructure?** → Phase 1
2. **Is it defining data structures?** → Phase 2
3. **Does it call external APIs?** → Phase 3
4. **Does it access local data/storage?** → Phase 4
5. **Is it business logic/rules?** → Phase 5
6. **Does it manage application state?** → Phase 6
7. **Is it user interface?** → Phase 7
8. **Does it write tests or test utilities?** → Phase 8

## Clean Architecture Principle

Remember: Dependencies flow inward
```
Tests → UI → State Management → Rules → Data → Services → Models → Foundational
```

- **Outer layers** depend on **inner layers**
- **Inner layers** never depend on **outer layers**
- Each phase can only depend on phases that come before it

## Quick Reference Table

| If the task creates... | Phase |
|------------------------|-------|
| Abstract base classes, utilities | 1 - Foundational |
| Data models, entities, DTOs | 2 - Models |
| API clients, external integrations | 3 - Services |
| Repositories, DAOs, local storage | 4 - Data |
| Use cases, business rules | 5 - Rules |
| ViewModels, Blocs, state handlers | 6 - State Management |
| Screens, widgets, components | 7 - UI |
| Unit tests, integration tests, e2e tests | 8 - Tests |

## Complex Task Classification

Some tasks may span multiple phases. In these cases:

1. **Break the task down** into sub-tasks for each phase
2. **Create separate tasks** for each phase
3. **Maintain phase order** - implement foundation before UI

**Example**: "Implement user authentication"
- Phase 1: Create base auth interfaces
- Phase 2: Define User and Token models
- Phase 3: Implement auth API client
- Phase 4: Create auth token repository
- Phase 5: Create login/logout use cases
- Phase 6: Build AuthenticationBloc/ViewModel
- Phase 7: Create login/signup screens
- Phase 8: Write unit and integration tests for auth flow

## Edge Cases

**Configuration files**: Phase 1 (Foundational) if infrastructure, Phase 7 (UI) if theme/styling

**Validation**: Phase 5 (Rules) if business validation, Phase 6 (State Management) if form state validation

**Error handling**: Goes with the phase where the error occurs

**Testing**: Always Phase 8 (Tests), regardless of which phase the tested code belongs to

**Documentation**: Same phase as the feature being documented

## When in Doubt

If you're unsure between two phases:
1. Consider the **primary responsibility** of the code
2. Think about **dependencies** - what does this code depend on?
3. Ask: "Where does this fit in the dependency flow?"
4. Choose the **earlier phase** when truly ambiguous (favor inner layers)

## Usage Example

**Task**: "Add user profile picture upload"

**Classification**:
- Primary responsibility: UI interaction (file picker, display)
- Depends on: API service, data storage, business rules
- This is primarily about user interface

**Result**: **Phase 7 (UI)** - but may require supporting tasks in earlier phases:
- Phase 3: API endpoint for upload
- Phase 4: Save profile picture URL locally
- Phase 5: Validate image size/format
