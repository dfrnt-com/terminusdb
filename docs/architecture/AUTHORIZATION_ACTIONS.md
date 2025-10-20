# TerminusDB Authorization Actions Reference

**Comprehensive Security Documentation for Server Administrators and Security Professionals**

## Overview

TerminusDB implements fine-grained capability-based access control. Authorization is governed by **Actions** - atomic permissions controlling specific operations. Actions are grouped into **Roles**, assigned to users via **Capabilities** scoped to resources (organizations, databases, repositories, branches).

### Access Control Model

```
User → Capability (scoped to Resource) → Role → Actions
```

###Resource Hierarchy

```
System → Organization → Database → Repository → Branch
```

---

## Actions by Category

### Database Lifecycle

#### `create_database` 
**Risk Level**: 🔴 HIGH  
**Purpose**: Create new databases within organization  
**Scope**: Organization  
**Code**: `src/core/api/db_create.pl:126`

**Grants Permission To**:
- `POST /api/db/{org}/{db}` - Database creation
- Initialize database schema and structure

**Security Implications**:
- Creates new resource-consuming entities
- May impact storage quotas
- Establishes new security boundaries

**Recommended Roles**: Admin, Developer  
**Audit**: Log all creation events, monitor for rapid creation

---

#### `delete_database`
**Risk Level**: 🔴 CRITICAL  
**Purpose**: Permanently delete databases  
**Scope**: Organization  
**Code**: `src/core/api/db_delete.pl:59-60`

**Grants Permission To**:
- `DELETE /api/db/{org}/{db}` - Irreversible deletion
- Remove all data, commits, metadata

**Security Implications**:
- **IRREVERSIBLE** data destruction
- Destroys audit trails
- May violate data retention policies
- Requires BOTH `create_database` AND `delete_database` (safety mechanism)

**Recommended Roles**: Admin ONLY  
**Audit**: **MANDATORY** logging, approval workflow, alert on production deletions

**Best Practice**:
```bash
# Separate role for destruction
terminusdb role create "Database Destroyer" --action delete_database
# Grant via time-limited capability only
```

---

#### `clone`
**Risk Level**: 🟡 MEDIUM  
**Purpose**: Clone databases (copy data/schema/history)  
**Scope**: Source database (read), Target org (write)  
**Code**: `src/core/api/db_clone.pl:72`

**Grants Permission To**:
- `POST /api/clone/{org}/{db}` - Database cloning
- Copy all data and establish remote tracking

**Security Implications**:
- Duplicates potentially sensitive data
- May bypass data residency requirements
- Creates resource consumption
- Uses `create_database` + `fetch` internally

**Recommended Roles**: Developer, Operations  
**Audit**: Log source/destination, track data lineage

---

### Distributed Operations

#### `fetch`
**Risk Level**: 🟡 MEDIUM  
**Purpose**: Fetch commits/layers from remote repositories  
**Scope**: Repository  
**Code**: `src/core/api/db_fetch.pl:29,106`

**Grants Permission To**:
- `POST /api/fetch/{org}/{db}` - Retrieve from remote
- Download layer data (potentially large)
- Update remote tracking branches

**Security Implications**:
- Introduces external data (**no schema validation** - see `PULL_LIFECYCLE.md`)
- Network traffic generation
- Trust boundary crossing
- Potential network reconnaissance if misconfigured

**Recommended Roles**: Developer, Integration  
**Audit**: Log source URL, monitor for unexpected remotes, track volume

---

#### `push`
**Risk Level**: 🔴 HIGH  
**Purpose**: Push commits to remote repositories  
**Scope**: Repository  
**Code**: `src/core/api/db_push.pl:51`

**Grants Permission To**:
- `POST /api/push/{org}/{db}` - Transmit to remote
- Update remote branch heads
- Large data transfers via TUS protocol

**Security Implications**:
- **PRIMARY DATA EXFILTRATION VECTOR**
- Transmits sensitive data to external systems
- Cannot be reverted once pushed
- May violate data residency policies

**Recommended Roles**: Developer, CI/CD (with caution)  
**Audit**: **MANDATORY** logging, alert on unexpected destinations, monitor volume

**DLP Pattern**:
```bash
# Alert on unauthorized push
terminusdb log --action push --filter 'url not in approved' --alert security
```

---

#### `rebase`
**Risk Level**: 🟡 MEDIUM  
**Purpose**: Rebase branches with schema validation  
**Scope**: Branch (source and target)  
**Code**: `src/core/api/db_rebase.pl:144-146,162`

**Grants Permission To**:
- `POST /api/rebase/{org}/{db}/{repo}/branch/{branch}`
- Replay commits with validation
- Execute fixup WOQL queries

**Security Implications**:
- Can alter commit history
- Fixup allows arbitrary WOQL execution
- Requires: `commit_read_access`, `schema_write_access`, `instance_write_access`
- **ONLY operation that validates fetched commits**

**Recommended Roles**: Developer, Integration  
**Audit**: Log strategy used, track fixup queries

---

### Data Access

#### `instance_read_access`
**Risk Level**: 🟡 MEDIUM  
**Purpose**: Read instance data (documents/facts)  
**Scope**: Database/Branch  
**Code**: `account/capabilities.pl:611`

**Grants Permission To**:
- `GET /api/document/{org}/{db}` - Read documents
- `POST /api/woql/{org}/{db}` - Query instance graph
- GraphQL queries on instance data

**Security Implications**:
- Grants read access to ALL instance data in scope
- No document-level restrictions
- May expose sensitive personal data

**Recommended Roles**: Read-Only, Developer, Analyst  
**Audit**: Monitor bulk access, track sensitive database queries

---

#### `instance_write_access`
**Risk Level**: 🔴 HIGH  
**Purpose**: Write/modify instance data  
**Scope**: Database/Branch  
**Code**: `account/capabilities.pl:611`

**Grants Permission To**:
- `POST /api/document/{org}/{db}` - Insert/update/delete documents
- `POST /api/woql/{org}/{db}` - Insert/delete triples
- GraphQL mutations

**Security Implications**:
- **Full write access** to all instance data
- Can modify or delete any documents
- Schema validation enforced on commit

**Recommended Roles**: Developer, Application Service  
**Audit**: **MANDATORY** logging, track commit authors, monitor bulk modifications

---

#### `schema_read_access`
**Risk Level**: 🟢 LOW  
**Purpose**: Read schema definitions  
**Scope**: Database/Branch  
**Code**: `account/capabilities.pl:612`

**Grants Permission To**:
- `GET /api/schema/{org}/{db}` - Retrieve schema
- Query schema graph
- Class frame generation

**Security Implications**:
- Discloses database structure
- Reveals class/property names
- Generally safe

**Recommended Roles**: Almost all roles

---

#### `schema_write_access`
**Risk Level**: 🔴 HIGH  
**Purpose**: Modify schema definitions  
**Scope**: Database/Branch  
**Code**: `account/capabilities.pl:612`

**Grants Permission To**:
- `POST /api/schema/{org}/{db}` - Modify schema
- Create/delete classes and properties
- Schema migrations

**Security Implications**:
- **CAN CAUSE DATA LOSS**
- Deleting classes deletes all instances
- Breaking changes disrupt applications

**Recommended Roles**: Developer, Data Architect  
**Audit**: **MANDATORY** logging, alert on production changes, require peer review

**Protection**:
```bash
# Separate dev/prod
terminusdb capability grant --user dev --role "Schema Developer" --scope "Database/dev"
# Prod requires approval
terminusdb capability grant --user dev --role "Schema Developer" --scope "Database/prod" --requires-approval
```

---

### Metadata

#### `meta_read_access`
**Risk Level**: 🟢 LOW  
**Purpose**: Read metadata (commit history, logs)  
**Scope**: Database/Repository  
**Code**: `api/api_log.pl:40`, `account/capabilities.pl:610`

**Grants Permission To**:
- `GET /api/log/{org}/{db}` - Commit log
- `GET /api/history/{org}/{db}` - Document history
- Repository metadata inspection

**Security Implications**:
- Reveals commit authors and messages
- Shows timing of changes
- Generally safe for transparency

**Recommended Roles**: Most roles

---

#### `meta_write_access`
**Risk Level**: 🔴 HIGH  
**Purpose**: Metadata operations (optimize, squash)  
**Scope**: Database/Repository  
**Code**: `api/api_optimize.pl:24-31`, `account/capabilities.pl:611`

**Grants Permission To**:
- `POST /api/optimize/{org}/{db}` - Optimize storage
- `POST /api/squash/{org}/{db}` - Squash commit history
- Layer compaction

**Security Implications**:
- **CAN DESTROY COMMIT HISTORY** (squash)
- May violate audit requirements
- Affects system performance

**Recommended Roles**: DBA, Operations ONLY  
**Audit**: **MANDATORY** logging, alert on production squash

**Warning**:
```bash
# Never squash audited databases without backup
terminusdb capability grant --user dba --role "DBA" --requires-approval
```

---

### Commit Operations

#### `commit_read_access`
**Risk Level**: 🟢 LOW  
**Purpose**: Read commit information  
**Scope**: Repository  
**Code**: `api/api_history.pl:21`, `account/capabilities.pl:612`

**Grants Permission To**:
- Read commit objects
- Traverse commit history
- Access commit metadata

**Security Implications**:
- Reveals change history
- Generally safe

**Recommended Roles**: Most roles

---

#### `commit_write_access`
**Risk Level**: 🔴 HIGH  
**Purpose**: Create new commits  
**Scope**: Repository  
**Code**: `api/api_squash.pl:26`, `account/capabilities.pl:612`

**Grants Permission To**:
- Create new commits
- Squash commits
- Migration commits

**Security Implications**:
- Creates permanent records
- Consumes storage

**Recommended Roles**: Developer, Application

---

### Branch Management

#### `branch`
**Risk Level**: 🟡 MEDIUM  
**Purpose**: Create/delete branches  
**Scope**: Repository  
**Code**: `api/db_branch.pl:230,277`

**Grants Permission To**:
- `POST /api/branch/{org}/{db}/{repo}/branch/{branch}` - Create
- `DELETE /api/branch/{org}/{db}/{repo}/branch/{branch}` - Delete

**Security Implications**:
- Branch deletion can cause data access loss
- May disrupt collaborative workflows

**Recommended Roles**: Developer

---

### Introspection

#### `class_frame`
**Risk Level**: 🟢 LOW  
**Purpose**: Retrieve class frame information  
**Scope**: Database/Branch  
**Code**: `api/api_frame.pl:8-24`

**Grants Permission To**:
- `GET /api/frame/{org}/{db}` - Get class frames
- Schema introspection

**Security Implications**:
- Discloses class structure
- Generally safe

**Recommended Roles**: Most roles

---

### Administration

#### `manage_capabilities`
**Risk Level**: 🔴 CRITICAL  
**Purpose**: Manage users, roles, organizations, capabilities  
**Scope**: System or Organization  
**Code**: `api/api_access_control.pl` (multiple lines)

**Grants Permission To**:
- **User Management**: Create/delete/update users, passwords
- **Role Management**: Create/delete/modify roles and actions
- **Organization Management**: Create/delete organizations
- **Capability Management**: Grant/revoke capabilities

**Security Implications**:
- **HIGHEST PRIVILEGE LEVEL**
- Can grant themselves any permission
- Can lock out other administrators
- Equivalent to root/admin access

**Recommended Roles**: System Admin ONLY  
**Audit**: **MANDATORY** logging of ALL operations, alert on grants/revokes, require MFA

**Separation of Duties**:
```bash
# Limit to 2-3 named individuals
terminusdb role create "System Administrator" --action manage_capabilities
terminusdb capability grant --user admin1 --role "System Administrator" --scope system --requires-mfa
```

---

## Role Templates

### Read-Only User
```bash
terminusdb role create "Read Only" \
  --action instance_read_access \
  --action schema_read_access \
  --action meta_read_access \
  --action commit_read_access
```

### Developer
```bash
terminusdb role create "Developer" \
  --action instance_read_access \
  --action instance_write_access \
  --action schema_read_access \
  --action schema_write_access \
  --action commit_read_access \
  --action commit_write_access \
  --action branch \
  --action rebase \
  --action fetch
```

### Admin (Pre-configured)
```bash
# Includes all 17 actions - use with extreme caution
terminusdb role get "Admin Role"
```

---

## Security Best Practices

### 1. Principle of Least Privilege
Grant only minimum necessary actions. Start restrictive, expand as needed.

### 2. Scope Narrowly
Prefer database/branch-level scopes over organization-level.

### 3. Audit Everything
Mandatory logging for: `delete_database`, `push`, `meta_write_access`, `manage_capabilities`

### 4. Separate Environments
Different roles for dev/staging/production.

### 5. Time-Limited Capabilities
Use expiring capabilities for elevated privileges:
```bash
terminusdb capability grant --expires "2025-01-20T00:00:00Z"
```

### 6. Monitor Anomalies
- Bulk data access
- Off-hours operations
- Push to unexpected remotes
- Production schema changes

### 7. Approval Workflows
Require approval for: production changes, deletions, capability grants

---

## Compliance Considerations

### GDPR/Data Protection
- **Personal Data Access**: Audit `instance_read_access` on user databases
- **Right to Erasure**: Control `instance_write_access` and `delete_database`
- **Data Portability**: Monitor `push` for exports

### SOX/Financial Audit
- **Never use** `meta_write_access` (squash) on financial databases
- Maintain immutable audit trail
- Separate duties for data entry vs. approval

### HIPAA/Healthcare
- Encrypt at rest and in transit
- Audit all `instance_read_access` on PHI databases
- Restrict `push` to prevent PHI exfiltration

---

## Quick Reference

| Action | Risk | Read | Write | Network | Admin |
|--------|------|------|-------|---------|-------|
| `create_database` | 🔴 | ❌ | ✅ | ❌ | ❌ |
| `delete_database` | 🔴 | ❌ | ✅ | ❌ | ❌ |
| `clone` | 🟡 | ✅ | ✅ | ⚠️ | ❌ |
| `fetch` | 🟡 | ✅ | ❌ | ✅ | ❌ |
| `push` | 🔴 | ❌ | ✅ | ✅ | ❌ |
| `rebase` | 🟡 | ✅ | ✅ | ❌ | ❌ |
| `instance_read_access` | 🟡 | ✅ | ❌ | ❌ | ❌ |
| `instance_write_access` | 🔴 | ❌ | ✅ | ❌ | ❌ |
| `schema_read_access` | 🟢 | ✅ | ❌ | ❌ | ❌ |
| `schema_write_access` | 🔴 | ❌ | ✅ | ❌ | ❌ |
| `meta_read_access` | 🟢 | ✅ | ❌ | ❌ | ❌ |
| `meta_write_access` | 🔴 | ❌ | ✅ | ❌ | ⚠️ |
| `commit_read_access` | 🟢 | ✅ | ❌ | ❌ | ❌ |
| `commit_write_access` | 🔴 | ❌ | ✅ | ❌ | ❌ |
| `branch` | 🟡 | ❌ | ✅ | ❌ | ❌ |
| `class_frame` | 🟢 | ✅ | ❌ | ❌ | ❌ |
| `manage_capabilities` | 🔴 | ✅ | ✅ | ❌ | ✅ |

---

**Document Version**: 1.0  
**Last Updated**: 2025-01-19  
**Classification**: Internal Security Documentation  
**Author**: TerminusDB Security Team
