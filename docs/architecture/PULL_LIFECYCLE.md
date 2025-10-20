# Pull Operation Lifecycle

**Technical Deep-Dive: Data Synchronization from Remote to Local**

## Overview

The pull operation in TerminusDB enables distributed data synchronization by fetching commits from a remote repository and integrating them into a local branch. This document provides a comprehensive technical analysis of the pull lifecycle, including critical insights about schema validation and distributed write scalability.

## Architecture Components

### Module Location
- **Primary Module**: `src/core/api/db_pull.pl`
- **Dependencies**: 
  - `db_fetch.pl` - Fetches layer metadata from remote
  - `db_fast_forward.pl` - Applies commits to local branch
  - `db_pack.pl` - Handles pack/unpack of layers
  - `db_rebase.pl` - Used for divergent history resolution

### Key Predicates
- `pull/7` - Main pull operation orchestrator
- `remote_fetch/6` - Fetches layers from remote URL
- `fast_forward_branch/3` - Applies commits without conflicts

---

## Pull Lifecycle: Step-by-Step

### Phase 1: Authorization & Validation

**Location**: `db_pull.pl` lines 16-26

```prolog
check_descriptor_auth(System_DB, Our_Branch_Descriptor, 
    '@schema':'Action/schema_write_access', Local_Auth),
check_descriptor_auth(System_DB, Our_Branch_Descriptor, 
    '@schema':'Action/instance_write_access', Local_Auth),
```

**Actions**:
1. Resolve local branch path to descriptor
2. Verify user has **schema write** access
3. Verify user has **instance write** access
4. Confirm branch exists and is openable

**Why Both Permissions?**: Pull can introduce new schema elements and instance data, requiring comprehensive write access.

---

### Phase 2: Remote Repository Resolution

**Location**: `db_pull.pl` lines 28-41

**Actions**:
1. Determine remote branch name (defaults to local branch name if not specified)
2. Construct remote repository descriptor from local repository + remote name
3. Build remote branch descriptor
4. Resolve remote repository path

**Data Structure**:
```prolog
Their_Branch_Descriptor = branch_descriptor{
    branch_name : Remote_Branch_Name,
    repository_descriptor : Their_Repository_Descriptor
}
```

---

### Phase 3: Fetch Operation

**Location**: `db_pull.pl` lines 42-44, `db_fetch.pl` lines 20-63

**Critical Insight**: This is where layers are retrieved **WITHOUT schema validation**.

#### Fetch Process (`db_fetch.pl`):

1. **Get Current Local Head** (lines 44-48):
   ```prolog
   repository_head(Database_Context, Repository_Name, Repository_Head_Layer_Id)
   ```
   - Retrieves the current tip of the local remote tracking branch
   - Returns `none` if no previous fetch has occurred

2. **Call Fetch Predicate** (line 50):
   ```prolog
   call(Fetch_Predicate, URL, Repository_Head_Option, Payload_Option)
   ```
   - Invokes either `authorized_fetch` (for HTTP remotes) or local fetch
   - Sends current head to avoid re-fetching known layers

3. **HTTP Fetch Details** (`db_fetch.pl` lines 72-95):
   ```prolog
   http_post(Pack_URL, json(Document), Payload, [
       request_header('Authorization'=Authorization),
       request_header('TerminusDB-Version'=Version),
       status_code(Status)
   ])
   ```
   - POST request to `/api/pack/{org}/{db}` endpoint
   - Returns pack containing new layers + metadata
   - Status codes:
     - `200`: New layers available, payload contains pack
     - `204`: No new layers (already up to date)

4. **Unpack Layers** (line 54):
   ```prolog
   unpack(Pack)
   ```
   - Extracts layers from pack file
   - Writes layer files to store
   - **NO VALIDATION OCCURS HERE** - layers stored as-is

5. **Update Remote Head** (lines 56-58):
   ```prolog
   update_repository_head(Database_Context, Repository_Name, Head)
   ```
   - Updates local tracking of remote repository head
   - Commits metadata transaction

#### TUS Protocol Support

For large payloads, TerminusDB supports the **TUS resumable upload protocol** for efficient layer transfer.

---

### Phase 4: Fast-Forward Attempt

**Location**: `db_pull.pl` lines 54-59, `db_fast_forward.pl` lines 10-50

**Critical Insight**: Fast-forward **does NOT perform schema validation**.

#### Fast-Forward Algorithm (`db_fast_forward.pl`):

1. **Find Common Ancestor** (lines 17-28):
   ```prolog
   most_recent_common_ancestor(Our_Repo_Context, Their_Repo_Context, 
       Our_Commit_Id, Their_Commit_Id, 
       Common_Commit_Id_Option, Our_Branch_Path, Their_Branch_Path)
   ```
   - Walks commit history from both branch heads
   - Identifies most recent shared commit
   - Returns divergence paths from common point

2. **Check for Divergence** (lines 26-28):
   ```prolog
   (   Our_Branch_Path = []
   ->  true
   ;   throw(error(divergent_history(...), _))
   )
   ```
   - `Our_Branch_Path = []` means we have no local-only commits → safe to fast-forward
   - Non-empty path means divergent history → requires rebase

3. **Copy Commits** (line 43):
   ```prolog
   copy_commits(Their_Repo_Context, Our_Repo_Context, Commit_Id)
   ```
   - Copies commit objects from remote tracking branch to local repository
   - Includes commit metadata (author, message, timestamp)
   - Includes all parent-child relationships

4. **Update Branch Pointer** (lines 44-48):
   ```prolog
   unlink_commit_object_from_branch(Our_Repo_Context, Our_Branch_Uri),
   link_commit_object_to_branch(Our_Repo_Context, Our_Branch_Uri, Commit_Uri)
   ```
   - Moves branch head to point at new commit
   - This is an atomic pointer update - no validation occurs

---

### Phase 5: Status Reporting

**Location**: `db_pull.pl` lines 49-71

#### Possible Outcomes:

1. **`api:pull_fast_forwarded`** (lines 56-58):
   - Fast-forward succeeded
   - `Applied_Commit_Ids` contains list of applied commits
   - Local branch now points to same commit as remote

2. **`api:pull_unchanged`** (line 57):
   - Local branch already up to date
   - `Applied_Commit_Ids = []`

3. **`api:pull_ahead`** (lines 63-64):
   - Local branch has commits remote doesn't have
   - Remote branch has no new commits
   - User should push, not pull

4. **`pull_divergent_history`** (lines 65-66):
   - Both branches have unique commits
   - Requires manual rebase operation
   - Returns common commit for reference

5. **`pull_no_common_history`** (lines 67-68):
   - Branches share no history
   - Cannot be automatically merged
   - Requires manual intervention

---

## Schema Validation: The Critical Detail

### ❌ NO Schema Validation During Pull/Fetch

**This is a deliberate design decision with major architectural implications.**

#### Where Validation DOES NOT Occur:

1. **Fetch Operation**: Layers are copied directly to store
2. **Unpack Operation**: Layer files written without inspection
3. **Fast-Forward**: Branch pointer updated without validation

#### Where Validation DOES Occur:

**Only during REBASE** (`db_rebase.pl` lines 80-95):

```prolog
validate_validation_objects([Our_Commit_Validation_Object], Witnesses)
```

When divergent history requires rebase:
1. Each commit is applied sequentially
2. After applying, schema validation runs
3. Validation failures can use strategies: `error`, `continue`, or `fixup`

---

## Distributed Write Scalability

### The Key Architectural Advantage

The lack of schema validation during pull enables **distributed write scaling without central coordination**.

#### Scaling Pattern:

```
┌──────────────┐         ┌──────────────┐
│  Writer A    │         │  Writer B    │
│  (Node 1)    │         │  (Node 2)    │
└──────┬───────┘         └──────┬───────┘
       │                        │
       │ Write commits          │ Write commits
       │ (schema checked        │ (schema checked
       │  locally)              │  locally)
       │                        │
       ├────────► Push          │
       │                        ├────────► Push
       │                        │
       ▼                        ▼
┌────────────────────────────────────────┐
│         Central Repository              │
│     (Aggregates writes, no check)       │
└────────────────┬───────────────────────┘
                 │
                 │ Pull (no schema check)
                 │
                 ▼
        ┌────────────────┐
        │  Reader Node   │
        │  (Assembled    │
        │   complete     │
        │   view)        │
        └────────────────┘
```

#### Benefits:

1. **Bottleneck Elimination**: Schema validation is the slowest operation. By validating only at write time on each node, not at pull time, the central repository isn't a constraint checker.

2. **Parallel Writes**: Multiple systems can write independently to their local repositories, each validating their own writes.

3. **Asynchronous Aggregation**: A central system can pull from multiple writers to build a complete view without blocking on validation.

4. **Eventual Consistency**: If schema violations occur, they're detected during rebase, allowing for fixup strategies.

---

## Multi-Remote Branching Strategy

### Question: Should Each Remote Have Its Own Local Branch?

**Answer**: Yes, this is the recommended pattern for managing multiple remotes.

#### Recommended Structure:

```
admin/mydb/
├── local/
│   └── branch/
│       └── main              # Local development
├── origin/
│   └── branch/
│       └── main              # Tracking branch for origin remote
└── upstream/
    └── branch/
        └── main              # Tracking branch for upstream remote
```

#### Workflow:

1. **Fetch from origin**: Updates `admin/mydb/origin/branch/main`
2. **Fetch from upstream**: Updates `admin/mydb/upstream/branch/main`
3. **Rebase local on origin**: Integrates origin changes with validation
4. **Rebase local on upstream**: Integrates upstream changes with validation

This mirrors Git's remote tracking branch model and provides clear separation of concerns.

---

## Edge Cases & Error Handling

### 1. Empty Branch Pull
- Pulling from empty remote to empty local: No-op, succeeds
- Pulling from non-empty to empty: Fast-forward succeeds

### 2. Network Failures
- Fetch can fail mid-transfer
- TUS protocol supports resumable uploads for reliability
- Partial fetches are discarded (atomic operation)

### 3. Authorization Failures
- Checked before any network operations
- Remote may also reject unauthorized fetch requests

### 4. Invalid Remote References
```prolog
error(not_a_valid_remote_branch(Their_Branch_Descriptor),_)
```
Thrown if remote branch doesn't exist after fetch completes.

---

## Performance Characteristics

### Time Complexity

1. **Fetch**: O(new_layers) - proportional to number of new commits
2. **Fast-Forward**:
   - Ancestor finding: O(log n) average, O(n) worst case
   - Commit copying: O(commits_to_copy)
   - Pointer update: O(1)

### Space Complexity

- Layer storage: Permanent storage cost
- Pack transmission: Temporary (unpacked and discarded)
- Commit metadata: Small (KB per commit)

### Network Considerations

- Single HTTP POST for fetch
- Pack compression reduces bandwidth
- TUS chunking for large transfers

---

## Security Considerations

### Authentication
- Bearer token in `Authorization` header
- Required for both fetch and pull operations

### Authorization
- `fetch` action permission on remote repository
- `schema_write_access` on local branch
- `instance_write_access` on local branch

### Data Integrity
- Layers identified by content hash (Layer ID)
- Commit IDs are cryptographically secure
- Parent-child relationships enforced

---

## Code References

| Operation | File | Lines | Key Function |
|-----------|------|-------|--------------|
| Main pull | `db_pull.pl` | 13-71 | `pull/7` |
| Remote fetch | `db_fetch.pl` | 20-63 | `remote_fetch/6` |
| Local fetch | `db_fetch.pl` | 97-155 | `local_fetch/5` |
| Fast-forward | `db_fast_forward.pl` | 10-50 | `fast_forward_branch/3` |
| Pack handling | `db_pack.pl` | - | `unpack/1`, `pack_from_context/3` |
| Schema validation | `db_rebase.pl` | 80-95 | `validate_validation_objects/2` |

---

## Comparison: Pull vs. Rebase

| Aspect | Pull | Rebase |
|--------|------|--------|
| Schema validation | ❌ No | ✅ Yes |
| Divergent history | ❌ Fails | ✅ Handles |
| Speed | Fast | Slower |
| Safety | Requires valid commits | Validates each commit |
| Use case | Linear history | Conflicting changes |

---

## Related Operations

- **Push**: See `PUSH_LIFECYCLE.md`
- **Fetch**: Standalone operation to update remote tracking
- **Rebase**: Manual conflict resolution with validation
- **Clone**: Initial repository setup with fetch

---

## Conclusion

The pull operation in TerminusDB is designed for **speed and scalability** in distributed environments. By deferring schema validation to rebase operations, it enables:

1. Multiple writers to work independently
2. Central aggregation without validation bottleneck
3. Efficient network transfer via packing
4. Clear separation between data transfer and validation

This architecture is essential for TerminusDB's goal of providing a distributed, constraint-checked database system that can scale horizontally.

---

**Document Version**: 1.0  
**Last Updated**: 2025-01-19  
**Author**: TerminusDB Architecture Documentation
