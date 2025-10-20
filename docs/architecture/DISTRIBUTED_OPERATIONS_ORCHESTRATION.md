# Distributed Operations Orchestration

**Technical Deep-Dive: Clone, Fetch, Push, Pull Orchestration**

## Overview

TerminusDB provides four distributed operations that compose to enable Git-like collaboration: **clone**, **fetch**, **push**, and **pull**. This document explains how these operations orchestrate together.

## Operation Composition

```
clone = create_db + fetch + fast_forward
pull  = fetch + fast_forward
fetch = pack_request + unpack + update_remote_head
push  = copy_commits + pack + transmit + update_remote_head
```

## Visual Orchestration

```
                    CLONE
    ┌─────────────────────────────────────────┐
    │ create_db → fetch → fast_forward        │
    └─────────────────────────────────────────┘

                    PULL
    ┌─────────────────────────────────────────┐
    │ fetch → fast_forward                    │
    └─────────────────────────────────────────┘

                    FETCH
    ┌─────────────────────────────────────────┐
    │ pack_request → unpack → update_head     │
    └─────────────────────────────────────────┘

                    PUSH
    ┌─────────────────────────────────────────┐
    │ copy_commits → pack → transmit → update │
    └─────────────────────────────────────────┘
```

---

## Clone Operation

**File**: `src/core/api/db_clone.pl`

### Orchestration Steps

#### 1. Create Database (Line 72)
```prolog
create_db_unfinalized(System_DB, Auth, Account, DB, Label, Comment, ...)
```
- Creates empty database structure
- **State**: Unfinalized (can rollback)
- **Auth**: Requires `create_database`

#### 2. Register Remote (Lines 38-49)
```prolog
insert_remote_repository(Database_Context, Remote, Remote_Path, ...)
```
- Records remote URL/path
- Creates remote tracking branch structure

#### 3. Fetch from Remote (Lines 54-58)
```prolog
(   Remote_Path = db(_, _)
->  local_fetch(...)    % Local store
;   remote_fetch(...)   % HTTP
)
```
- **Local fetch**: Direct layer copy (same instance)
- **Remote fetch**: HTTP pack download
- **Auth**: Requires `fetch`
- **No validation**: Layers copied as-is

#### 4. Fast-Forward (Lines 60-64)
```prolog
fast_forward_branch(To_Branch_Descriptor, From_Branch_Descriptor, ...)
```
- Copies commits from remote tracking → local branch
- **No validation**: Assumes remote commits valid

#### 5. Finalize or Cleanup (Lines 78-81)
```prolog
(   var(Error) ->  finalize_db(Db_Uri)
;   force_delete_db(Account, DB), throw(Error) )
```
- **Success**: Database active
- **Failure**: Complete cleanup (atomic)

### Cleanup Triggers
- `remote_pack_failed`
- `http_open_error`
- `remote_connection_failure`

---

## Fetch Operation

**File**: `src/core/api/db_fetch.pl`

### Remote Fetch Flow

#### 1. Get Current Head (Lines 44-48)
```prolog
repository_head(Database_Context, Repository_Name, Repository_Head_Layer_Id)
```
- Returns `some(Layer_Id)` or `none`
- Determines baseline for pack

#### 2. Request Pack (Lines 72-95)
```http
POST /api/pack/{org}/{db}
Authorization: Bearer {token}
Content-Type: application/json

{ "repository_head": "{layer_id}" }
```
**Responses**:
- 200: Pack with new layers
- 204: Up to date
- 401/404: Auth or not found

#### 3. Unpack Layers (Line 54)
```prolog
unpack(Pack)
```
- Extract layers to store
- Write commit objects
- **NO VALIDATION**

#### 4. Update Remote Head (Lines 56-58)
```prolog
update_repository_head(Database_Context, Repository_Name, Head)
```
- Records new remote state
- Commits metadata transaction

### Local Fetch
- Direct layer copy (no network)
- Same metadata updates
- Faster for same-instance operations

---

## Push Operation

**File**: `src/core/api/db_push.pl`

### Orchestration Steps

#### 1. Pre-Push Validation (Lines 43-85)
**Checks**:
- Branch exists
- Remote is configured and type `remote`
- `push` authorization
- Remote head exists (fetched before)

**Errors**:
- `push_requires_branch`
- `unknown_remote_repository`
- `push_has_no_repository_head`

#### 2. History Analysis (Lines 86-116)
```prolog
most_recent_common_ancestor(Repo_Context, Remote_Context, 
    Local_Commit_Id, Remote_Commit_Id,
    Common_Commit_Id, Local_Path, Remote_Path)

do_or_die(Remote_Path = [], error(remote_diverged(...),_))
```

**Divergence Detection**:
```
Linear:    Local: A-B-C-D, Remote: A-B-C
           Remote_Path = [] ✅ Safe

Diverged:  Local: A-B-C-E, Remote: A-B-C-D
           Remote_Path = [D] ❌ Error
```

#### 3. Copy Commits (Lines 118-121)
```prolog
copy_commits(Repository_Context, Remote_Repository_Context, Local_Commit_Id)
reset_branch_head(Remote_Repository_Context, Remote_Branch_Uri, Local_Commit_Uri)
```
- Copies new commits to remote tracking
- Updates branch pointer

#### 4. Create Pack (Line 137)
```prolog
pack_from_context(Final_Context, some(Last_Head_Id), Payload_Option)
```
**Output**:
- `none`: No changes (optimization)
- `some(Payload)`: Binary pack

#### 5. Transmit (Lines 180-235)

**TUS Protocol** (preferred):
```prolog
tus_upload(Tmp_File, TUS_URL, Resource_URL, [...])
```
- Resumable uploads
- Large pack support

**Direct POST** (fallback):
```http
POST /api/unpack/{org}/{db}
Content-Type: application/octets

{binary pack}
```

#### 6. Update Local Tracking (Lines 142-148)
```prolog
update_repository_head(Database_Transaction_Object, Remote_Name, Current_Head_Id)
```
- Records what was pushed

---

## Pull Operation

**File**: `src/core/api/db_pull.pl`

### Orchestration Steps

#### 1. Authorization (Lines 20-21)
**Requires**:
- `schema_write_access`
- `instance_write_access`
- `fetch` (implicit)

**Why write for pull?** Pull modifies local branch.

#### 2. Fetch (Lines 42-44)
```prolog
remote_fetch(System_DB, Local_Auth, Their_Repository_Path, 
    Fetch_Predicate, _New_Head_Layer_Id, Head_Has_Updated)
```
- Delegates to `db_fetch.pl`
- Updates remote tracking

#### 3. Fast-Forward (Lines 54-60)
```prolog
fast_forward_branch(Our_Branch_Descriptor, Their_Branch_Descriptor, 
    Applied_Commit_Ids)
```
- Attempts to advance local branch
- **No validation**

#### 4. Status Determination (Lines 56-70)

**Success**:
- `api:pull_fast_forwarded`: `Applied_Commit_Ids ≠ []`
- `api:pull_unchanged`: `Applied_Commit_Ids = []`
- `api:pull_ahead`: Local ahead, remote unchanged

**Failure**:
- `pull_divergent_history`: Both have unique commits
- `pull_no_common_history`: Branches unrelated

---

## Collaboration Patterns

### 1. Linear Workflow
```
Dev A: clone → commit → push
Dev B: pull → commit → push
Dev A: pull → commit → push
```
**Characteristics**: No conflicts, all fast-forward

### 2. Parallel with Rebase
```
Dev A: clone → commit
Dev B: clone → commit
Dev A: push ✅
Dev B: push ❌ remote_diverged
       fetch → rebase → push ✅
```
**Characteristics**: Last to push must rebase

### 3. Hub-and-Spoke (Data Aggregation)
```
Writer 1: clone("hub") → commit → push
Writer 2: clone("hub") → commit → push
Writer 3: clone("hub") → commit → push
Aggregator: clone("hub") → pull (gets all)
```
**Characteristics**: No validation on push/pull, distributed scaling

---

## State Transitions

### Remote Tracking States

```
Initial (clone):
  local:  [A]──[B]──[C]●
  remote: [A]──[B]──[C]●

After local commit:
  local:  [A]──[B]──[C]──[D]●
  remote: [A]──[B]──[C]●

After push:
  local:  [A]──[B]──[C]──[D]●
  remote: [A]──[B]──[C]──[D]●

Remote advances (other user):
  local:  [A]──[B]──[C]──[D]●
  remote: [A]──[B]──[C]──[D]──[E]●

After fetch (not pull):
  local:  [A]──[B]──[C]──[D]●
  remote: [A]──[B]──[C]──[D]──[E]●

After pull (fast-forward):
  local:  [A]──[B]──[C]──[D]──[E]●
  remote: [A]──[B]──[C]──[D]──[E]●
```

---

## Error Recovery

### Clone Failures
| Error | Cause | Recovery |
|-------|-------|----------|
| `http_open_error` | Network failure | Database deleted, retry |
| `access_not_authorised` | No permission | No DB created, request access |
| `remote_pack_failed` | Remote error | Database deleted, check remote |

### Fetch Failures
| Error | Cause | Recovery |
|-------|-------|----------|
| `http_open_error(timeout)` | Network | Local unchanged, retry |
| `http_status(404)` | Remote deleted | Update remote URL |

### Push Failures
| Error | Cause | Recovery |
|-------|-------|----------|
| `remote_diverged` | Remote advanced | `fetch → rebase → push` |
| `http_open_error` | Network | Local updated, retry push |

**TUS Benefit**: Resumable if network fails mid-transfer

### Pull Failures
| Error | Cause | Recovery |
|-------|-------|----------|
| `pull_divergent_history` | Both advanced | Manual `rebase` |
| `pull_no_common_history` | Unrelated branches | Manual intervention |

---

## Key Architectural Insights

### 1. No Validation on Transfer
**Operations WITHOUT validation**:
- `fetch`: Layers copied as-is
- `push`: Assumes local validation authoritative
- `pull`: Fast-forward without checking
- `clone`: Trusts remote

**ONLY validation**: `rebase` (see `db_rebase.pl`)

**Why?** Enables distributed write scaling - validation bottleneck removed.

### 2. Atomic Operations
- `clone`: All-or-nothing (cleanup on failure)
- `push`: Pack creation atomic
- `fetch`: Metadata update transactional
- `pull`: Fast-forward atomic

### 3. Content Addressing
- Layers identified by hash (immutable)
- Duplicate detection automatic
- Tamper-evident

### 4. Remote Tracking
- Local copy of remote state
- Enables offline diff
- Fast divergence detection

---

## Performance Characteristics

| Operation | Network | Disk I/O | Validation | Typical Time |
|-----------|---------|----------|------------|--------------|
| Clone | ✅ Yes | High | ❌ No | 1s - 5min |
| Fetch | ✅ Yes | Medium | ❌ No | < 1s - 1min |
| Push | ✅ Yes | Low | ❌ No | < 1s - 1min |
| Pull | ✅ Yes | Medium | ❌ No | < 1s - 1min |
| Rebase | ❌ No | Medium | ✅ **YES** | 1s - 10min |

**Factors**:
- Database size (commits, layers)
- Network bandwidth
- Remote server load
- TUS vs direct POST

---

## Security Implications

### Data Flow
```
Remote (untrusted) 
    ↓ fetch/clone (NO VALIDATION)
Remote Tracking Branch
    ↓ pull/fast-forward (NO VALIDATION)
Local Branch
    ↓ commit (VALIDATED)
Local Branch
    ↓ push (NO VALIDATION)
Remote (untrusted)
```

### Critical Points
1. **Fetch**: External data enters without validation
2. **Push**: Primary data exfiltration vector
3. **Rebase**: ONLY operation with validation

### Mitigation
- Monitor fetch sources (alert on unexpected remotes)
- Audit all push operations (DLP)
- Require rebase for critical data
- Network segmentation

---

## Related Documentation

- **PULL_LIFECYCLE.md**: Detailed pull mechanics
- **PUSH_LIFECYCLE.md**: Detailed push mechanics
- **AUTHORIZATION_ACTIONS.md**: Security model
- **Code**: `src/core/api/db_*.pl` modules

---

**Document Version**: 1.0  
**Last Updated**: 2025-01-19  
**Author**: TerminusDB Architecture Documentation
