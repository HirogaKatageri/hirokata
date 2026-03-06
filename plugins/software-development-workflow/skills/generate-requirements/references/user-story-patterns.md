# User Story Patterns and Best Practices

This reference provides detailed patterns for writing effective user stories with comprehensive acceptance criteria.

## User Story Format

### Standard Template

```
As a [specific user role]
I want to [specific action or capability]
So that [specific business value or outcome]
```

### Components Explained

**User Role:**
- Be specific: "authenticated user", "admin", "free-tier customer"
- Not generic: "user", "person", "someone"
- Consider permissions and context

**Action:**
- Use active voice
- Be specific about what capability is needed
- Focus on the "what", not the "how"

**Business Value:**
- Explain why this matters
- Connect to user goals or business outcomes
- Avoid restating the action

## User Story Patterns

### Pattern 1: Feature Addition

**Template:**
```
As a [user role]
I want to [new capability]
So that [benefit I gain]
```

**Example:**
```
As a mobile app user
I want to enable biometric authentication
So that I can log in quickly without typing my password
```

### Pattern 2: Feature Enhancement

**Template:**
```
As a [user role]
I want to [improved capability] [additional detail]
So that [enhanced benefit]
```

**Example:**
```
As a content creator
I want to filter my published articles by date range and category
So that I can quickly find specific content to edit or review
```

### Pattern 3: User Experience Improvement

**Template:**
```
As a [user role]
I want [better experience] when [context]
So that [reduced friction or improved satisfaction]
```

**Example:**
```
As a first-time user
I want to see an onboarding tutorial with skip option
So that I can learn key features without feeling forced through lengthy steps
```

### Pattern 4: Administrative Function

**Template:**
```
As an [admin role]
I want to [administrative action]
So that [operational benefit or control]
```

**Example:**
```
As a system administrator
I want to view audit logs of all user authentication attempts
So that I can detect and investigate suspicious activity
```

### Pattern 5: Integration or API

**Template:**
```
As a [system or service]
I want to [capability to interact with another system]
So that [system-level benefit]
```

**Example:**
```
As the payment service
I want to receive webhook notifications from the payment gateway
So that I can update order status in real-time without polling
```

### Pattern 6: Error Handling

**Template:**
```
As a [user role]
I want to [understand or recover from error]
So that [can continue or resolve issue]
```

**Example:**
```
As a user submitting a form
I want to see specific error messages for each invalid field
So that I know exactly what to fix without guessing
```

### Pattern 7: Performance Requirement

**Template:**
```
As a [user role]
I want [action] to [performance characteristic]
So that [experience benefit]
```

**Example:**
```
As a dashboard viewer
I want the analytics page to load in under 2 seconds
So that I can quickly check metrics without waiting
```

## Acceptance Criteria Patterns

### Given-When-Then Format

**Template:**
```
Given [precondition or context]
When [action or event]
Then [expected result]
```

**Best Practices:**
- Be specific about preconditions
- Describe one action per criterion
- Define observable, testable outcomes
- Cover happy path, alternatives, and errors

### Pattern 1: Happy Path

**Focus:** Standard expected flow

**Example:**
```
Given I am logged in as an admin
When I click "Export Users" button
Then I receive a CSV file download containing all user data
```

### Pattern 2: Alternative Flow

**Focus:** Valid but non-standard paths

**Example:**
```
Given I am on the checkout page with items in cart
When I apply a valid discount code
Then the order total is reduced by the discount amount
And the discount code is shown as applied
```

### Pattern 3: Edge Case

**Focus:** Boundary conditions or unusual scenarios

**Example:**
```
Given I am uploading a file larger than 10MB
When I submit the form
Then I see an error "File size must be under 10MB"
And the form is not submitted
```

### Pattern 4: Error Condition

**Focus:** Invalid input or failure scenarios

**Example:**
```
Given I enter an invalid email format (missing @)
When I blur the email field
Then I see inline error "Please enter a valid email address"
And the submit button is disabled
```

### Pattern 5: Permission Check

**Focus:** Authorization and access control

**Example:**
```
Given I am logged in as a regular user (not admin)
When I navigate to /admin/users URL directly
Then I am redirected to the homepage
And I see a message "Access denied: Admin privileges required"
```

### Pattern 6: State Transition

**Focus:** Changes in system or data state

**Example:**
```
Given an order is in "Pending" status
When the payment is successfully processed
Then the order status changes to "Confirmed"
And the customer receives a confirmation email
And inventory is decremented for ordered items
```

### Pattern 7: Time-Based Behavior

**Focus:** Temporal conditions and expiration

**Example:**
```
Given I requested a password reset link 25 hours ago
When I click the reset link
Then I see an error "This link has expired"
And I am prompted to request a new reset link
```

## Complete User Story Examples

### Example 1: Authentication Feature

```markdown
### Story: Two-Factor Authentication Setup

**Story:**
As a security-conscious user
I want to enable two-factor authentication on my account
So that my account is protected even if my password is compromised

**Acceptance Criteria:**

1. Given I am logged in and on the security settings page
   When I click "Enable Two-Factor Authentication"
   Then I am shown a QR code and a manual entry code
   And I see instructions to scan with an authenticator app

2. Given I have scanned the QR code in my authenticator app
   When I enter the 6-digit code from the app
   Then my 2FA is enabled
   And I am shown a list of backup codes to save

3. Given 2FA is enabled on my account
   When I log in with correct username and password
   Then I am prompted to enter a 2FA code
   And I cannot access my account without the valid code

4. Given I enter an incorrect 2FA code
   When I submit the code
   Then I see an error "Invalid code. Please try again."
   And I remain on the 2FA verification page

5. Given I have lost access to my authenticator app
   When I use one of my backup codes to log in
   Then I gain access to my account
   And that specific backup code is marked as used and cannot be reused

**Edge Cases:**
- **QR code not working**: Provide manual entry code as fallback
- **Time synchronization issues**: Accept codes from previous/next 30-second window
- **Multiple failed attempts**: Implement rate limiting after 5 failed attempts
- **Lost backup codes**: Require email verification to disable 2FA and reset
- **Already enabled**: Redirect to 2FA management page instead of setup

**Technical Considerations:**
- Use TOTP (Time-based One-Time Password) standard (RFC 6238)
- Generate cryptographically secure random secret for each user
- Store secret encrypted in database
- Backup codes: 10 single-use codes, 8 characters each
- Rate limiting: Max 5 attempts per 15 minutes
- Audit logging for all 2FA events

**Definition of Done:**
- [ ] User can enable 2FA via QR code or manual entry
- [ ] 2FA is required on subsequent logins
- [ ] Backup codes are generated and downloadable
- [ ] Used backup codes are invalidated
- [ ] Rate limiting prevents brute force attacks
- [ ] Compatible with Google Authenticator and Authy
- [ ] Security audit logging implemented
- [ ] Unit tests cover all acceptance criteria
- [ ] Integration tests verify complete flow
- [ ] Documentation includes user guide
```

### Example 2: Data Export Feature

```markdown
### Story: Export Customer Data

**Story:**
As a marketing manager
I want to export customer contact information with filters
So that I can create targeted email campaigns

**Acceptance Criteria:**

1. Given I am on the customers page as an authorized user
   When I click "Export Customers"
   Then I see a modal with export options

2. Given the export modal is open
   When I select filters (date range, status, location)
   And I click "Export"
   Then the export starts processing

3. Given the export is processing fewer than 1,000 records
   When the export completes
   Then I receive a CSV file download immediately

4. Given the export is processing more than 1,000 records
   When the export is initiated
   Then I see a message "Export in progress. You'll receive an email when ready."
   And I receive an email with download link when complete

5. Given I am not authorized to export customer data
   When I access the export function
   Then I see an error "Insufficient permissions"
   And the export does not proceed

**Edge Cases:**
- **No customers match filters**: Show message "No customers match your criteria" instead of empty CSV
- **Export already in progress**: Prevent duplicate exports, show status of current export
- **Very large exports (>100K records)**: Split into multiple CSV files
- **Special characters in data**: Properly escape CSV fields (quotes, commas, newlines)
- **Email delivery fails**: Store export file for 7 days, accessible from "Export History" page

**Technical Considerations:**
- Generate CSV using streaming to avoid memory issues
- Include headers: Name, Email, Phone, Location, Status, Created Date
- Async job queue (Sidekiq/Bull) for exports >1K records
- Store temporary export files in S3 with 7-day expiration
- Rate limit: Max 5 exports per user per hour
- Audit log all export activities with timestamp and user ID
- GDPR compliance: Log data exports for compliance

**Definition of Done:**
- [ ] Small exports (<1K) download immediately
- [ ] Large exports (>1K) process asynchronously with email notification
- [ ] All selected filters are applied correctly
- [ ] CSV format is valid and parseable
- [ ] Special characters are properly escaped
- [ ] Permission checks prevent unauthorized access
- [ ] Rate limiting prevents abuse
- [ ] Export history is accessible for 7 days
- [ ] Audit logging captures all exports
- [ ] Unit tests cover filtering logic
- [ ] Integration tests verify full export flow
- [ ] Load tests confirm performance with 100K records
```

### Example 3: Error Recovery

```markdown
### Story: Form Auto-Save and Recovery

**Story:**
As a user filling out a long application form
I want my progress to be automatically saved
So that I don't lose my work if my browser closes unexpectedly

**Acceptance Criteria:**

1. Given I am filling out the application form
   When I complete any field and move to the next field
   Then my data is automatically saved to browser local storage
   And I see a subtle "Saved" indicator

2. Given I have partially filled the form and close my browser
   When I return to the form page
   Then I see a banner "We found unsaved progress. Would you like to restore it?"
   And I can choose "Restore" or "Start Fresh"

3. Given I click "Restore" on the recovery banner
   When the form loads
   Then all my previously entered data is populated
   And I can continue from where I left off

4. Given I click "Start Fresh" on the recovery banner
   When the form loads
   Then the form is blank
   And the saved data is cleared from local storage

5. Given I successfully submit the form
   When the submission is confirmed
   Then the auto-saved data is cleared from local storage
   And no recovery banner appears on next visit

**Edge Cases:**
- **Local storage unavailable**: Gracefully degrade, show one-time warning
- **Data corruption in storage**: Clear corrupted data, show "Start Fresh" only
- **Multiple tabs open**: Last-write-wins, sync across tabs using storage events
- **Expired session**: Restore form data but require re-authentication before submit
- **Form version mismatch**: If form structure changed, discard old saved data

**Technical Considerations:**
- Debounce auto-save to 500ms after last input change
- Store data as JSON in localStorage with timestamp and form version
- Max storage size: 5MB (typical localStorage limit)
- Include form version in saved data for compatibility checks
- Use storage event API to sync across browser tabs
- Clear local storage on successful form submission
- Encrypt sensitive fields in local storage (optional, based on data sensitivity)

**Definition of Done:**
- [ ] Form data auto-saves on field blur
- [ ] Recovery banner appears on return with unsaved data
- [ ] Restore functionality populates all saved fields
- [ ] Start Fresh clears saved data
- [ ] Successful submission clears local storage
- [ ] Graceful degradation when localStorage unavailable
- [ ] Cross-tab synchronization works correctly
- [ ] No PII stored unencrypted in localStorage
- [ ] User sees clear "Saved" feedback
- [ ] Unit tests cover save/restore logic
- [ ] Integration tests verify recovery flow
```

## Common Mistakes to Avoid

### Mistake 1: Vague User Role

❌ **Bad:**
```
As a user
I want to search for products
```

✅ **Good:**
```
As a guest visitor browsing the online store
I want to search for products by name or category
So that I can quickly find items I'm interested in purchasing
```

### Mistake 2: Implementation-Focused

❌ **Bad:**
```
As a developer
I want to implement OAuth2 with JWT tokens
So that users can authenticate
```

✅ **Good:**
```
As a registered user
I want to log in using my Google account
So that I don't need to create and remember another password
```

### Mistake 3: Missing Business Value

❌ **Bad:**
```
As a user
I want to export data to CSV
```

✅ **Good:**
```
As a data analyst
I want to export filtered report data to CSV
So that I can perform advanced analysis in Excel
```

### Mistake 4: Untestable Acceptance Criteria

❌ **Bad:**
```
Then the system works correctly
Then the user is happy
Then performance is good
```

✅ **Good:**
```
Then the API responds in less than 200ms
Then the user sees a success message "Profile updated"
Then the dashboard loads all widgets within 2 seconds
```

### Mistake 5: Combining Multiple Stories

❌ **Bad:**
```
As a user
I want to log in, view my dashboard, and update my profile
So that I can manage my account
```

✅ **Good:**
Split into three separate stories:
- Login story
- Dashboard story
- Profile update story

## Acceptance Criteria Checklist

When writing acceptance criteria, ensure:

**Completeness:**
- [ ] Happy path covered
- [ ] Alternative paths covered
- [ ] Error conditions covered
- [ ] Edge cases covered
- [ ] Permission checks covered

**Clarity:**
- [ ] Preconditions are specific
- [ ] Actions are unambiguous
- [ ] Expected results are observable
- [ ] Technical jargon is minimized

**Testability:**
- [ ] Each criterion is independently testable
- [ ] Success/failure is clearly defined
- [ ] No subjective terms ("fast", "easy", "intuitive")
- [ ] Measurable metrics where relevant

**Consistency:**
- [ ] Same terminology used throughout
- [ ] Format is consistent (Given-When-Then)
- [ ] Level of detail is appropriate
- [ ] Aligns with user story intent

## Tips for Writing Great User Stories

1. **Focus on user goals, not solutions**: Describe what users need, not how to build it
2. **Keep stories small**: If a story takes more than 1 sprint, split it
3. **Make them independent**: Stories should be completable in any order
4. **Collaborate**: Involve developers, designers, and stakeholders
5. **Add examples**: Real-world scenarios clarify intent
6. **Think edge cases**: What could go wrong? What are the limits?
7. **Define "done"**: Include testing, documentation, deployment criteria
8. **Review regularly**: Update stories based on feedback and learning

## Conclusion

Effective user stories and acceptance criteria:
- Clearly communicate user needs and business value
- Provide testable, unambiguous requirements
- Cover happy paths, alternatives, and errors
- Enable developers to build the right thing
- Help QA verify correctness
- Document expected behavior for future reference

Use these patterns as starting points, then adapt them to your specific domain and team practices.