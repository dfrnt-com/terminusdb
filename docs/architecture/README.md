# TerminusDB Architecture Documentation

**Technical Deep-Dive Documentation for System Internals**

## Overview

This directory contains comprehensive technical documentation covering TerminusDB's internal architecture, distributed operations, and security model. These documents are intended for:

- System administrators
- Security professionals  
- Core contributors
- Advanced users requiring deep system understanding

---

## Documents

### 1. [PULL_LIFECYCLE.md](./PULL_LIFECYCLE.md)
**Pull Operation Lifecycle - Data Synchronization from Remote to Local**

Comprehensive technical analysis of the pull operation, including:
- Fetch operation details (NO schema validation)
- Fast-forward algorithm
- History analysis and conflict detection
- Distributed write scalability patterns
- Multi-remote branching strategies

**Key Insight**: Pull operations do NOT perform schema validation, enabling distributed write scaling without central bottleneck.

**Audience**: Developers, architects designing distributed systems

---

### 2. [PUSH_LIFECYCLE.md](./PUSH_LIFECYCLE.md)
**Push Operation Lifecycle - Data Synchronization from Local to Remote**

Complete technical documentation of push operations:
- Pre-push validation and history analysis
- Commit transfer and pack creation
- TUS protocol for large transfers
- Race condition handling
- Local vs. remote push differences

**Key Insight**: Push operations assume local validation is authoritative, making push a potential data exfiltration vector that requires monitoring.

**Audience**: Security professionals, DevOps engineers

---

### 3. [AUTHORIZATION_ACTIONS.md](./AUTHORIZATION_ACTIONS.md)
**Authorization Actions Reference - Comprehensive Security Documentation**

Authoritative security documentation for all 17 authorization actions:
- Detailed action descriptions with risk levels
- Security implications and attack scenarios
- Role recommendations and best practices
- Audit requirements
- Compliance considerations (GDPR, SOX, HIPAA)
- Code references for each action

**Key Insight**: `manage_capabilities` is the highest privilege (equivalent to root), while `push` is the primary data exfiltration vector.

**Audience**: Security professionals, system administrators, compliance officers

---

### 4. [DISTRIBUTED_OPERATIONS_ORCHESTRATION.md](./DISTRIBUTED_OPERATIONS_ORCHESTRATION.md)
**Distributed Operations Orchestration - Clone, Fetch, Push, Pull**

Complete technical analysis of how distributed operations compose and orchestrate:
- Operation composition hierarchy (clone = create + fetch + fast-forward)
- Detailed orchestration steps for each operation
- State transitions and remote tracking
- Collaboration patterns (linear, parallel, hub-and-spoke)
- Error recovery strategies
- Performance characteristics

**Key Insight**: Operations compose cleanly with no validation on transfer, enabling distributed write scaling. Only rebase validates.

**Audience**: Developers, architects, DevOps engineers

---

### 5. [BUNDLE_UNBUNDLE_API.md](./BUNDLE_UNBUNDLE_API.md)
**Bundle and Unbundle API - Repository Backup and Restoration**

Complete guide to bundling mechanisms for database backup and migration:
- What bundles are and how they differ from packs
- CLI and HTTP API usage (both fully functional)
- `/api/unbundle` endpoint implementation with comprehensive security
- Complete working examples for direct upload and TUS
- Security hardening (path validation, authorization, rate limiting)
- Attack vectors and mitigations
- Compliance considerations (GDPR, SOX, HIPAA)
- Operational patterns (backups, DR, migration)
- Production deployment checklist

**Key Insight**: Complete bundle/unbundle functionality via CLI and HTTP API. Secure implementation with multi-layer protection against common attacks.

**Audience**: DevOps engineers, system administrators, security professionals, developers

---

## Architecture Principles

### 1. Distributed-First Design
TerminusDB is architected for distributed collaboration with eventual consistency. Operations like `pull` and `push` do not validate schema, allowing:
- Horizontal write scaling
- Independent writer validation
- Central aggregation without bottleneck

### 2. Capability-Based Security
Fine-grained access control through composable actions, roles, and capabilities:
- Principle of least privilege
- Resource-scoped permissions
- Immutable audit trail

### 3. Content-Addressed Storage
Commits and layers are content-addressed, providing:
- Tamper-evident history
- Efficient deduplication
- Cryptographic integrity

---

## Planned Documentation

Future architecture documents to be added:

- **REBASE_LIFECYCLE.md** - Conflict resolution with schema validation
- **COMMIT_LIFECYCLE.md** - Transaction processing and validation
- **LAYER_STORAGE.md** - Storage engine internals
- **SCHEMA_VALIDATION.md** - Constraint checking engine
- **GRAPHQL_ENGINE.md** - GraphQL to WOQL translation
- **TRANSACTION_MODEL.md** - ACID properties and isolation levels

---

## Contributing

When adding architecture documentation:

1. **Target Audience**: Clearly state intended readers
2. **Code References**: Link to specific files and line numbers
3. **Security Focus**: Highlight security implications
4. **Practical Examples**: Include real-world usage patterns
5. **Diagrams**: Use ASCII art or reference external diagrams
6. **Key Insights**: Call out critical architectural decisions

### Document Template Structure

```markdown
# [Feature] Lifecycle/Architecture

**Technical Deep-Dive: [Summary]**

## Overview
[High-level description]

## Architecture Components
[Modules, files, key predicates]

## [Feature] Lifecycle: Step-by-Step
[Detailed walkthrough with code references]

## Security Considerations
[Threats, mitigations, best practices]

## Performance Characteristics
[Time/space complexity, optimization strategies]

## Code References
[Table of files/functions]

## Conclusion
[Summary of key insights]
```

---

## Related Documentation

- **User Documentation**: `/docs/` (user-facing guides)
- **API Documentation**: Generated from code comments
- **Schema Documentation**: `src/terminus-schema/system_schema.json`
- **Contributing Guide**: `/CONTRIBUTING.md`

---

## Document Maintenance

- **Review Cycle**: Quarterly or after major architectural changes
- **Accuracy**: Must reflect actual code behavior
- **Updates**: Update line numbers and code references when refactoring
- **Versioning**: Include document version and last updated date

---

**For Questions**: Open an issue with label `documentation` or `architecture`
