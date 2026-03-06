# Tracker Agent: Usage Examples

This document shows real-world examples of how the Tracker Agent helps manage projects and tasks.

## Example 1: Starting a New Web Application Project

### Conversation

```
You: I'm starting a new web application project and need help organizing my work

Agent: I'll help you set up comprehensive tracking for your web application.
       Let me ask a few questions to structure this properly:

       1. What type of web application is this?
          (e.g., SaaS, e-commerce, internal tool, portfolio site)

       2. What are the main feature areas you'll be building?
          (e.g., authentication, user profiles, dashboard, API, etc.)

       3. What development methodology do you follow?
          (e.g., Agile sprints, Kanban, Waterfall phases)

You: It's a SaaS product with authentication, user dashboard, data analytics,
     and team collaboration features. We're using 2-week Agile sprints.

Agent: Perfect! For a SaaS product with Agile methodology, I recommend:

       **Phases** (Sprint stages):
       1. Foundation - Core infrastructure and setup
       2. Feature Development - Build main features
       3. Integration & Polish - Connect everything together
       4. Testing & QA - Quality assurance
       5. Launch Preparation - Deployment and final checks

       **Tracks** (Feature areas):
       - authentication (login, signup, password reset)
       - user-dashboard (UI, data display, settings)
       - analytics (data collection, processing, visualization)
       - collaboration (teams, sharing, permissions)
       - infrastructure (database, API, deployment)

       Should I create this tracker structure for you?

You: Yes, that looks good

Agent: [Creates tracker using create-tracker skill]

       Tracker created successfully!

       **Name**: saas-product
       **Location**: .trackers/saas-product/
       **Structure**: 5 phases, 5 tracks

       **Next Steps**:
       Now let's add some initial tasks. Since you're in sprint planning,
       I recommend starting with Foundation phase tasks.

       What tasks need to happen in the Foundation phase?
       I can help you break these down and add them.

You: We need to set up the database, create the authentication framework,
     and set up the deployment pipeline

Agent: Great! I'll create these as separate tasks with proper tracking.
       Let me add them now...

       [Uses add-task skill multiple times]

       Added 3 tasks to Phase 1 (Foundation):

       **Task 01**: Setup database schema and migrations
       - Track: infrastructure
       - Priority: High (critical foundation work)
       - Complexity: Medium
       - Status: Pending

       **Task 02**: Create authentication framework
       - Track: authentication
       - Priority: High (required for all features)
       - Complexity: High (security critical)
       - Status: Pending

       **Task 03**: Setup deployment pipeline (CI/CD)
       - Track: infrastructure
       - Priority: High (needed for testing)
       - Complexity: Medium
       - Status: Pending

       All tasks are ready to start with no blockers!

       Your tracker is now set up. View it at:
       .trackers/saas-product/TRACKER.md

       Would you like to:
       1. Add more tasks?
       2. Review the current tracker status?
       3. Start working on a task?
```

---

## Example 2: Daily Standup Planning

### Conversation

```
You: What should I work on today?

Agent: Let me check your tracker status...

       [Reads .trackers/saas-product/TRACKER.md]

       **Current Status**: 8/15 tasks (53% complete)

       **In Progress** (finish these first):
       - Task 07: User dashboard layout (80% done per notes)
         Started 2 days ago, High priority

       **Ready to Start** (no blockers):
       - Task 09: Analytics data API (High priority, critical path)
       - Task 11: Team creation UI (Medium priority)
       - Task 14: Password reset flow (Medium priority)

       **Blocked**:
       - Task 12: Dashboard data integration (blocked by Task 09)

       **My Recommendation for Today**:

       1. **FINISH Task 07** (User dashboard layout)
          - You're close to completion
          - High priority
          - Other tasks may depend on this

       2. **START Task 09** (Analytics data API)
          - High priority
          - Blocking Task 12
          - Critical path item

       3. **If time permits**: Task 11 (Team creation UI)
          - No dependencies
          - Good parallel work

       This approach:
       - Completes your in-progress work
       - Unblocks Task 12
       - Maximizes progress on critical path

       Sound good? Want me to mark Task 07 as your current focus?

You: Yes, let me finish Task 07 first

Agent: Perfect! I'll keep Task 07 as in-progress.
       Let me know when you complete it and I'll help you
       transition to Task 09.

       Good luck! 🚀

[Later that day...]

You: Task 07 is done

Agent: Excellent work! Let me update the tracker...

       [Uses mark-status skill]

       Task 07 marked as Complete! ✓

       **Updated Status**: 9/15 tasks (60% complete)

       **Next Up**: Task 09 (Analytics data API)

       This is a high-priority, high-complexity task.
       Would you like me to:
       1. Show you the detailed plan for Task 09?
       2. Start tracking it as in-progress?
       3. Add any notes or sub-tasks to it?

You: Mark it in progress and show the plan

Agent: [Updates status and reads plan file]

       Task 09 is now In Progress ⏳

       **Plan: Analytics Data API**

       **Requirements**:
       - Create REST API endpoints for analytics data
       - Implement data aggregation queries
       - Add caching layer for performance
       - Write API documentation

       **Acceptance Criteria**:
       - [ ] GET /api/analytics/overview endpoint
       - [ ] GET /api/analytics/detailed endpoint
       - [ ] Response time < 500ms with caching
       - [ ] Complete OpenAPI documentation

       **Dependencies**: None (ready to implement)

       **Estimated Complexity**: High
       - Database query optimization needed
       - Caching strategy required
       - Multiple endpoints to implement

       The plan file is at:
       .trackers/saas-product/plans/09-analytics-data-api.md

       You can add notes there as you work. Good luck! 🎯
```

---

## Example 3: Sprint Review & Planning

### Conversation

```
You: Our 2-week sprint is ending tomorrow. Can you help me review what we've
     accomplished and plan the next sprint?

Agent: I'll do a comprehensive sprint review and help you plan the next one.

       [Uses review-tracker skill with detailed analysis]

       **Sprint 1 Review** (Jan 13 - Jan 27, 2026)

       ═══════════════════════════════════════════════════════════

       **Overall Progress**:
       - **Planned**: 12 tasks
       - **Completed**: 10 tasks (83%) ✓
       - **In Progress**: 1 task
       - **Blocked**: 1 task

       **Completion by Track**:
       - ✓ infrastructure: 3/3 (100%)
       - ✓ authentication: 2/2 (100%)
       - ⏳ user-dashboard: 3/4 (75%)
       - ⏳ analytics: 2/3 (67%)
       - ⏸ collaboration: 0/0 (not started)

       **Completion by Phase**:
       - ✓ Phase 1 (Foundation): 5/5 (100%) - COMPLETE
       - ⏳ Phase 2 (Feature Development): 5/7 (71%)

       ═══════════════════════════════════════════════════════════

       **Completed This Sprint** ✓:
       - All foundation/infrastructure work
       - Core authentication framework
       - Basic dashboard UI
       - Analytics data collection

       **Carryover to Next Sprint**:
       - Task 08: Dashboard data integration (In Progress, 60% done)
         Recommendation: Should complete in 1-2 days

       - Task 12: Analytics visualization widgets (Blocked by Task 08)
         Recommendation: Will unblock when Task 08 completes

       **Analysis**:
       - 🎉 Excellent velocity: 10 tasks in 2 weeks
       - ✓ Foundation phase complete - ready to focus on features
       - ⚠️ Analytics track needs attention (blocking visualization work)
       - 💡 Collaboration track not started (good opportunity for next sprint)

       ═══════════════════════════════════════════════════════════

       **Recommendations for Next Sprint**:

       1. **Finish carryovers** (2 tasks, ~2-3 days)
          - Complete Task 08
          - Unblock and finish Task 12

       2. **Start collaboration track** (3-4 tasks)
          - Team creation and management
          - Sharing and permissions
          - Collaboration UI

       3. **Continue analytics** (2 tasks)
          - Advanced analytics features
          - Export and reporting

       **Suggested Sprint 2 Plan** (12-14 tasks):
       - 2 carryover tasks
       - 4 collaboration tasks (new track)
       - 3 analytics tasks (finish track)
       - 3 dashboard polish tasks
       - 1-2 integration tasks

       ═══════════════════════════════════════════════════════════

       Would you like me to:
       1. Export this review as a report for your team?
       2. Create tasks for the next sprint based on these recommendations?
       3. Mark Phase 1 as complete?
       4. All of the above?

You: Do all of the above

Agent: Perfect! I'll handle all of that now...

       [Exports review, creates tasks, updates phase status]

       **Actions Completed**:

       ✓ Sprint review exported to:
         .trackers/saas-product/reviews/saas-product-review-2026-01-27.md

       ✓ Phase 1 (Foundation) marked as COMPLETE

       ✓ Created 10 new tasks for Sprint 2:

       **Collaboration Track** (Phase 2):
       - Task 15: Create team management UI (High priority)
       - Task 16: Implement team permissions (High priority)
       - Task 17: Add user invitation system (Medium priority)
       - Task 18: Team settings and configuration (Medium priority)

       **Analytics Track** (Phase 2):
       - Task 19: Advanced filtering and queries (Medium priority)
       - Task 20: Data export functionality (Low priority)
       - Task 21: Custom report builder (Medium priority)

       **Dashboard Track** (Phase 2):
       - Task 22: Dashboard customization (Low priority)
       - Task 23: User preferences (Medium priority)

       **Integration** (Phase 3):
       - Task 24: End-to-end feature testing (High priority)

       **Dependencies Set**:
       - Task 12 blocked by Task 08 ✓
       - Task 24 blocked by Tasks 15, 19, 23

       ═══════════════════════════════════════════════════════════

       **Sprint 2 Summary**:
       - Total tasks: 14 (2 carryover + 10 new + 2 existing)
       - High priority: 4 tasks
       - Medium priority: 7 tasks
       - Low priority: 2 tasks

       **Next Steps**:
       1. Share the exported review with your team
       2. Start Sprint 2 with Task 08 (finish carryover)
       3. Move to collaboration track tasks
       4. Review progress mid-sprint

       Your tracker is updated and ready for Sprint 2! 🚀

       Want to see the detailed tracker or have questions about any tasks?
```

---

## Example 4: Handling Blockers

### Conversation

```
You: I'm stuck. Several tasks seem blocked and I don't know what to work on

Agent: Let me analyze your tracker for blockers and dependencies...

       [Reads tracker and analyzes task relationships]

       **Blocker Analysis**:

       You have **5 blocked tasks**. Here's what's blocking them:

       ═══════════════════════════════════════════════════════════

       **Primary Blocker**: Task 09 (Analytics data API)
       - Status: In Progress (60% complete)
       - **BLOCKING**: 3 other tasks
         * Task 12: Analytics visualization
         * Task 17: Dashboard data integration
         * Task 21: Export functionality

       **Impact**: Completing Task 09 will unblock 3 tasks

       ═══════════════════════════════════════════════════════════

       **Secondary Blocker**: Task 15 (Team permissions system)
       - Status: Pending (not started)
       - **BLOCKING**: 2 other tasks
         * Task 18: Sharing features
         * Task 20: Team settings

       **Impact**: Starting Task 15 will eventually unblock 2 tasks

       ═══════════════════════════════════════════════════════════

       **Root Cause**:
       You're 60% done with Task 09, which is the critical blocker.
       The other blocker (Task 15) hasn't been started yet.

       **Recommendation**:

       **Option 1: Finish the blocker** (Recommended)
       - Complete Task 09 (40% remaining work)
       - This immediately unblocks 3 tasks
       - Provides most value

       **Option 2: Work around it**
       - Start Task 15 (new track)
       - Parallel progress while Task 09 completes
       - Requires context switching

       **Option 3: Focus elsewhere**
       - Work on non-blocked tasks:
         * Task 22: Dashboard customization (no dependencies)
         * Task 23: User preferences (no dependencies)

       ═══════════════════════════════════════════════════════════

       **My Strong Recommendation**:
       Finish Task 09 first. You're 60% done, and completing it will:
       - Unblock 3 high-value tasks
       - Clear your critical path
       - Give you more options for what's next

       After that, you'll have 3 newly unblocked tasks + the 2 non-blocked
       tasks = 5 options to choose from.

       Want me to:
       1. Help you plan how to finish Task 09?
       2. Show you the detailed plan for Task 09?
       3. Suggest a different approach?

You: Help me finish Task 09

Agent: Great choice! Let me pull up your progress on Task 09...

       [Reads plan file and notes]

       **Task 09: Analytics Data API** (60% complete)

       **What's Done** ✓:
       - Database queries implemented
       - Basic API endpoints created
       - Initial testing complete

       **What's Remaining** (40%):
       - [ ] Add caching layer (Redis integration)
       - [ ] Optimize slow queries
       - [ ] Write API documentation
       - [ ] Final integration testing

       **To Complete This Task**:

       1. **Add caching** (~2 hours)
          - Install Redis client
          - Add cache middleware
          - Cache common queries

       2. **Optimize queries** (~1-2 hours)
          - Add database indexes
          - Review query plans
          - Test performance

       3. **Documentation** (~1 hour)
          - Write OpenAPI specs
          - Add usage examples
          - Document edge cases

       **Estimated Time to Complete**: 4-5 hours

       **Acceptance Criteria Remaining**:
       - [ ] Response time < 500ms with caching
       - [ ] Complete OpenAPI documentation

       ═══════════════════════════════════════════════════════════

       **My Suggestion**:
       Tackle this in order: caching → optimization → docs

       Once you finish, you'll unblock:
       - Task 12 (analytics visualization) - High priority
       - Task 17 (dashboard integration) - High priority
       - Task 21 (export functionality) - Medium priority

       You'll have 3 high-value tasks ready to start! 🎯

       Want me to track your progress as you work through these steps?

You: Yes, let me start with the caching

Agent: Perfect! I'll note that in your task plan.

       Working on: Task 09 - Adding caching layer

       Let me know when each step is done and I'll help you track progress.
       You've got this! 💪
```

---

## Example 5: Feature Planning

### Conversation

```
You: I need to add a new feature: real-time notifications for team activities

Agent: Great! Let me help you plan this feature addition.

       First, let me understand the scope:

       1. What kind of notifications? (e.g., new messages, updates, mentions)
       2. How should they be delivered? (in-app, email, push notifications)
       3. Does this depend on any existing features?
       4. What's the priority for this feature?

You: In-app notifications for team activities like new messages, @mentions,
     and task updates. It depends on the team collaboration features.
     High priority since teams are complaining they miss updates.

Agent: Thanks! This is a significant feature that will span multiple phases.
       Let me analyze your tracker structure...

       [Reads tracker to understand current state]

       **Feature Analysis**:

       This notification feature needs:
       - Backend: Notification system, real-time delivery
       - Frontend: Notification UI, real-time updates
       - Integration: Connect with team, messaging, tasks

       **Recommendation**: Create a new track called "notifications"

       **Suggested Task Breakdown**:

       **Phase 2 (Feature Development)**:
       1. Design notification data model (Foundation)
       2. Create notification API endpoints (Backend)
       3. Implement notification UI component (Frontend)

       **Phase 3 (Integration)**:
       4. Integrate with team activities (Integration)
       5. Add real-time delivery (WebSocket/SSE)
       6. Implement notification preferences

       **Phase 4 (Testing)**:
       7. Test notification scenarios
       8. Performance testing

       **Dependencies**:
       - Requires: Task 15 (Team permissions) to be complete
       - Blocks: None initially

       Should I:
       1. Create the "notifications" track?
       2. Add these 8 tasks to your tracker?
       3. Set up the dependencies?

You: Yes, do all of that

Agent: Perfect! Creating notification feature tasks...

       [Uses add-track and add-task skills]

       **Created**:

       ✓ New track: "notifications"

       ✓ Added 8 tasks:

       **Phase 2: Feature Development**
       - Task 25: Design notification data model
         Priority: High, Complexity: Medium
         Status: Pending

       - Task 26: Create notification API endpoints
         Priority: High, Complexity: High
         Blocked by: Task 25
         Status: Pending

       - Task 27: Implement notification UI component
         Priority: High, Complexity: Medium
         Blocked by: Task 26
         Status: Pending

       **Phase 3: Integration**
       - Task 28: Integrate with team activities
         Priority: High, Complexity: High
         Blocked by: Task 15, Task 27
         Status: Pending

       - Task 29: Add real-time delivery (WebSocket)
         Priority: High, Complexity: High
         Blocked by: Task 26
         Status: Pending

       - Task 30: Implement notification preferences
         Priority: Medium, Complexity: Low
         Blocked by: Task 27
         Status: Pending

       **Phase 4: Testing**
       - Task 31: Test notification scenarios
         Priority: High, Complexity: Medium
         Blocked by: Task 28, Task 29
         Status: Pending

       - Task 32: Notification performance testing
         Priority: Medium, Complexity: Medium
         Blocked by: Task 31
         Status: Pending

       ═══════════════════════════════════════════════════════════

       **Summary**:
       - 8 tasks added to notifications track
       - Spans 3 phases (Feature Dev, Integration, Testing)
       - Dependencies set up properly
       - First task (25) is ready to start once you're ready

       **Critical Path**:
       Task 25 → Task 26 → Task 27 → Task 28 → Task 31 → Task 32

       **Next Steps**:
       1. Complete Task 15 (Team permissions) - currently blocking Task 28
       2. Start Task 25 (Notification data model) when ready
       3. Follow the dependency chain

       **Estimated Timeline**:
       - If you complete 1 task per day: ~8 days
       - With Task 15 dependency: add 2-3 days
       - Total: ~10-11 days for full feature

       Your tracker now has 32 tasks total across 6 tracks! 📊

       Want to see how this affects your overall progress?

You: Yes, show me the updated status

Agent: [Uses review-tracker skill]

       **Updated Tracker Status**:

       **Overall**:
       - Total tasks: 32 (was 24)
       - Completed: 10 (31%)
       - In Progress: 2 (6%)
       - Pending: 19 (59%)
       - Blocked: 1 (3%)

       **Progress by Track**:
       - infrastructure: 3/3 (100%) ✓
       - authentication: 2/2 (100%) ✓
       - user-dashboard: 3/5 (60%)
       - analytics: 3/5 (60%)
       - collaboration: 2/6 (33%)
       - notifications: 0/8 (0%) ← NEW

       **Progress by Phase**:
       - Phase 1 (Foundation): 5/5 (100%) ✓
       - Phase 2 (Feature Dev): 5/18 (28%)
       - Phase 3 (Integration): 0/6 (0%)
       - Phase 4 (Testing): 0/3 (0%)

       **Impact of New Feature**:
       - Added 8 tasks (33% increase)
       - Completion dropped from 42% to 31% (expected)
       - Phase 2 now has 18 tasks (was 10)

       **Good News**:
       - Task 25 is ready to start (no blockers)
       - Dependencies are clear
       - Foundation is solid (100%)

       **Recommendation**:
       Your next sprint should focus on:
       1. Complete existing Phase 2 work
       2. Start notifications feature
       3. Move some tasks to Phase 3 when ready

       The notifications feature is well-integrated into your plan! 🎯
```

---

## Key Takeaways

### What the Agent Does Well

1. **Context Understanding**: Remembers project details and makes informed suggestions
2. **Proactive Analysis**: Identifies issues before you ask
3. **Workflow Orchestration**: Handles multi-step operations seamlessly
4. **Clear Communication**: Explains reasoning and provides actionable advice
5. **Dependency Management**: Tracks blockers and critical paths
6. **Progress Insight**: Provides meaningful metrics and recommendations

### Best Practices for Working with the Agent

1. **Provide Context**: Share details about your project and workflow
2. **Ask Open Questions**: "What should I work on?" vs "Mark task 5 complete"
3. **Trust Recommendations**: The agent analyzes more data than you might manually review
4. **Use for Planning**: Great for sprint planning, feature design, progress reviews
5. **Let It Guide You**: The agent knows the tracker structure and best practices

### When to Use Direct Skills Instead

- Quick, specific operations (you know exactly what to do)
- Scripting or automation
- Batch operations
- Learning the system (seeing direct commands)

---

**Note**: These examples show conversational flows. The agent will adapt to your specific project, team size, methodology, and preferences.
