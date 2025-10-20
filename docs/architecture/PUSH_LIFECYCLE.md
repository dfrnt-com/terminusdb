# Push Operation Lifecycle

**Technical Deep-Dive: Data Synchronization from Local to Remote**

## Overview

The push operation in TerminusDB enables local commits to be published to a remote repository, making them available to other collaborators. This document provides a comprehensive technical analysis of the push lifecycle, including validation strategies, conflict detection, and protocol handling.

## Architecture Components

### Module Location
- **Primary Module**: `src/core/api/db_push.pl`
- **Dependencies**:
  - `db_pack.pl` - Creates layer packs for transmission
  - `db_rebase.pl` - Handles conflict resolution
  - TUS library - Resumable upload protocol
  - HTTP client - Remote communication

### Key Predicates
- `push/8` - Main push operation orchestrator
- `authorized_push/3` - HTTP transport with auth
- `local_push/5` - Direct store-to-store push

---

## Push Lifecycle: Step-by-Step

### Phase 1: Pre-Push Validation

**Location**: `db_push.pl` lines 43-72

#### 1.1 Branch Resolution
```prolog
resolve_absolute_string_descriptor(Branch, Branch_Descriptor),
(branch_descriptor{} :< Branch_Descriptor)
```

**Validation**:
- Path must resolve to valid branch descriptor
- Cannot push from commit or repository directly
- Must be a branch reference

#### 1.2 Authorization Check
```prolog
check_descriptor_auth(System_DB, Repository_Descriptor, 
    '@schema':'Action/push', Auth)
```

**Required Permission**:
- `push` action on the repository
- This is checked against local auth, not remote

#### 1.3 Remote Repository Validation
```prolog
repository_type(Database_Descriptor, Remote_Name, Type),
do_or_die(Type = remote, 
    error(push_attempted_on_non_remote(...),_))
```

**Checks**:
- Remote must be registered in database metadata
- Remote must have type `remote` (not `local`)
- Remote must have URL or path configured

---

### Phase 2: Repository Context Setup

**Location**: `db_push.pl` lines 74-85

#### 2.1 Create Local Context
```prolog
askable_context(Repository_Descriptor, System_DB, Auth, 
    Repository_Context_With_Prefixes),
context_default_prefixes(Repository_Context_With_Prefixes, 
    Repository_Context)
```

**Purpose**: Establishes transactional context for reading local repository state.

#### 2.2 Create Remote Tracking Context
```prolog
resolve_relative_descriptor(Database_Descriptor,
    [Remote_Name, "_commits"], Remote_Repository),
create_context(Remote_Repository, Remote_Repository_Context)
```

**Key Insight**: Push operates on the **local copy** of the remote repository (tracking branch), not directly on the remote server.

#### 2.3 Validate Remote Head Exists
```prolog
repository_head(Database_Transaction, Remote_Name, Last_Head_Id)
```

**Error Condition**: `push_has_no_repository_head`
- Means fetch has never been performed
- Remote tracking branch has no commits
- **Must fetch before push**

---

### Phase 3: History Analysis & Conflict Detection

**Location**: `db_push.pl` lines 86-130

This is the critical phase where push determines if it can proceed safely.

#### 3.1 Local Branch State

```prolog
branch_head_commit(Repository_Context, Branch_Name, Local_Commit_Uri)
```

Two scenarios:
1. **Local branch has commits**: Proceed to conflict check
2. **Local branch is empty** (line 123): Special handling

#### 3.2 Remote Branch State

```prolog
has_branch(Remote_Repository_Context, Remote_Branch),
branch_head_commit(Remote_Repository_Context, Remote_Branch, 
    Remote_Commit_Uri)
```

Three scenarios:
1. **Remote branch exists with commits**: Check for divergence
2. **Remote branch exists but empty**: Treat as new
3. **Remote branch doesn't exist** (line 99): Create it

#### 3.3 Common Ancestor Search

**Location**: Lines 104-107

```prolog
most_recent_common_ancestor(Repository_Context, 
    Remote_Repository_Context, 
    Local_Commit_Id, Remote_Commit_Id, 
    Common_Commit_Id, Local_Branch_Path, Remote_Branch_Path)
```

**Critical Check** (line 109):
```prolog
do_or_die(Remote_Branch_Path = [],
    error(remote_diverged(Remote_Repository, Remote_Branch_Path),_))
```

**What This Means**:
- `Remote_Branch_Path = []`: Remote has no commits we don't know about → **SAFE TO PUSH**
- `Remote_Branch_Path ≠ []`: Remote has diverged → **PUSH REJECTED**

#### 3.4 No Common History Scenario

**Location**: Lines 115-116

```prolog
throw(error(no_common_history(Remote_Repository),_))
```

Occurs when:
- Both branches have commits
- No shared ancestor exists
- Indicates completely independent development

---

### Phase 4: Commit Transfer

**Location**: `db_push.pl` lines 118-122

#### 4.1 Check If Transfer Needed

```prolog
(   Remote_Commit_Uri_Option = none
;   Remote_Commit_Id \= Local_Commit_Id)
```

**Two conditions to skip transfer**:
1. Remote head equals local head (already pushed)
2. Remote is empty and local is empty

#### 4.2 Copy Commits

```prolog
copy_commits(Repository_Context, Remote_Repository_Context, 
    Local_Commit_Id)
```

**Process**:
1. Traverses commit history from `Local_Commit_Id` back to remote head
2. Copies each commit object to remote tracking branch
3. Includes metadata: author, message, timestamp, parent links
4. Does **not** validate schema during copy

#### 4.3 Reset Remote Branch Head

```prolog
reset_branch_head(Remote_Repository_Context_With_Prefixes, 
    Remote_Branch_Uri, Local_Commit_Uri)
```

**Action**: Updates remote tracking branch to point to local head commit.

---

### Phase 5: Pack Creation & Transmission

**Location**: `db_push.pl` lines 132-163

#### 5.1 Transaction Finalization

```prolog
cycle_context(Remote_Repository_Context, Final_Context, 
    Remote_Transaction_Object, _)
```

**Purpose**: Commits changes to remote tracking branch and prepares layer data.

#### 5.2 Pack Generation

```prolog
pack_from_context(Final_Context, some(Last_Head_Id), Payload_Option)
```

**Inputs**:
- `Final_Context`: Contains new commits and layers
- `Last_Head_Id`: Previous remote head (for diff calculation)

**Output**:
- `Payload_Option = none`: No changes (local head equals `Last_Head_Id`)
- `Payload_Option = some(Payload)`: Binary pack containing new layers

#### 5.3 Remote vs. Local Push

**Remote Push** (lines 134-149): Uses HTTP/TUS
**Local Push** (lines 151-162): Direct store-to-store copy

---

### Phase 6: Remote HTTP Push

**Location**: `db_push.pl` lines 180-235

#### 6.1 TUS Protocol Attempt

**What is TUS?** Resumable upload protocol for large files.

```prolog
tus_options(TUS_URL, _TUS_Options, [
    request_header('Authorization'=Authorization),
    request_header('TerminusDB-Version'=Version)
])
```

**Flow**:
1. Check if remote supports TUS (via OPTIONS request)
2. Create temporary file with random extension
3. Write payload to file
4. Upload via TUS protocol to `/api/files`
5. Get resource URL back

**Fallback** (lines 205-210):
If TUS fails (URL not found or file exists error), fall back to traditional POST.

#### 6.2 Unpack Request

```prolog
http_post(Unpack_URL, Data, Result, [
    request_header('Authorization'=Authorization),
    request_header('TerminusDB-Version'=Version),
    json_object(dict),
    timeout(infinite),
    status_code(Status_Code)
])
```

**Endpoint**: `/api/unpack/{org}/{db}`

**Data Formats**:
- **TUS mode**: `json(_{resource_uri : Resource_URL})`
- **Direct mode**: `bytes('application/octets', Payload)`

**Response Codes**:
- `200`: Success, layers unpacked on remote
- Other: Error, operation failed

#### 6.3 TUS Cleanup

```prolog
tus_delete(Resource_URL, [tus_extension([termination])], [...])
```

After successful unpack, delete the uploaded file from TUS server.

---

### Phase 7: Repository Head Update

**Location**: `db_push.pl` lines 142-148, 156-162

#### 7.1 Extract New Layer ID

```prolog
[Read_Obj] = (Remote_Transaction_Object.instance_objects),
Layer = (Read_Obj.read),
layer_to_id(Layer, Current_Head_Id)
```

**Purpose**: Get the layer ID representing the new remote head state.

#### 7.2 Update Local Tracking

```prolog
update_repository_head(Database_Transaction_Object, 
    Remote_Name, Current_Head_Id)
```

**Critical**: This updates the **local record** of what the remote head is, ensuring future pushes have correct baseline.

#### 7.3 Commit Metadata Transaction

```prolog
run_transactions([Database_Transaction_Object], true, _)
```

**Atomicity**: All metadata updates are transactional - either fully succeed or fully rollback.

---

### Phase 8: Local Store Push

**Location**: `db_push.pl` lines 237-271

**Use Case**: Pushing to a shared filesystem store instead of remote HTTP server.

#### 8.1 Resolve Target Repository

```prolog
Repository_Path = [Organization, DB, "local", "_commits"],
resolve_absolute_descriptor(Repository_Path, Repository_Descriptor)
```

#### 8.2 Authorization Check

```prolog
check_descriptor_auth(System_DB, Repository_Descriptor,
    '@schema':'Action/commit_write_access', Auth)
```

**Different from remote push**: Requires `commit_write_access` on the **target** repository.

#### 8.3 Parent-Child Validation

**Location**: Lines 263-267

```prolog
parent_child_ids(Repository_Head_Layer_Id, New_Head_Id)
```

**Implementation** (lines 273-277):
```prolog
parent_child_ids(Parent_Id, Child_Id) :-
    triple_store(Store),
    store_id_layer(Store, Child_Id, Child_Layer),
    parent(Child_Layer, Parent_Layer),
    layer_to_id(Parent_Layer, Parent_Id).
```

**Critical Check**: Ensures `New_Head_Id` is a direct or indirect child of current head.

**Error**: `push_does_not_advance_local_remote` if validation fails.

---

## Schema Validation During Push

### ❌ NO Schema Validation on Push

**Push does not perform schema validation.** This is a critical architectural decision.

#### Assumption

Commits being pushed were **already validated** when they were created locally via:
- `insert/delete/update` operations during transaction
- Commit operation itself

#### Rationale

1. **Performance**: Re-validating on push would double validation cost
2. **Trust Model**: Local validation is authoritative
3. **Distributed Consistency**: Remote can validate during its own operations if needed

#### Security Consideration

Remote repository **could** reject invalid commits at unpack time, but standard TerminusDB doesn't enforce this. The trust model assumes:
- Authenticated users write valid commits
- Schema evolution is coordinated
- Invalid commits are bugs, not attacks

---

## Push Outcomes & Return Values

### Success Scenarios

#### 1. `new(Current_Head_Id)`
- New layers successfully pushed
- Remote head updated to `Current_Head_Id`
- Normal push completion

#### 2. `same(Last_Head_Id)`
- No new commits to push
- Local head equals remote head
- No-op, but successful

### Error Scenarios

#### 1. `remote_diverged`
```prolog
error(remote_diverged(Remote_Repository, Remote_Branch_Path),_)
```
- Remote has commits local doesn't know about
- `Remote_Branch_Path` contains list of divergent commit IDs
- **Resolution**: Fetch + rebase, then retry push

#### 2. `no_common_history`
```prolog
error(no_common_history(Remote_Repository),_)
```
- Branches are completely unrelated
- Cannot be automatically merged
- **Resolution**: Manual intervention required

#### 3. `push_has_no_repository_head`
```prolog
error(push_has_no_repository_head(Remote_Repository), _)
```
- Remote tracking branch not initialized
- **Resolution**: Fetch first to establish baseline

#### 4. `remote_not_empty_on_local_empty`
```prolog
error(remote_not_empty_on_local_empty(Remote_Repository),_)
```
- Local branch is empty
- Remote branch has commits
- **Resolution**: Don't push from empty branch, fetch instead

#### 5. `push_attempted_on_non_remote`
```prolog
error(push_attempted_on_non_remote(Database_Descriptor, Remote_Name),_)
```
- Attempted to push to a `local` repository type
- **Resolution**: Only push to remotes

---

## Race Conditions & Conflict Resolution

### The Race Window

**Scenario**:
1. Local performs fetch at T0, sees remote head = H1
2. Remote receives push from another user at T1, head becomes H2
3. Local performs push at T2, based on H1

**Detection**:
- Remote will reject push if it has advanced beyond H1
- Detection happens during `most_recent_common_ancestor` check
- `Remote_Branch_Path ≠ []` indicates remote has diverged

### Resolution Strategy

```
Local: A -- B -- C -- D
                       ↑ (attempting to push)
Remote: A -- B -- E -- F
                       ↑ (current head)
```

**Steps**:
1. Push fails with `remote_diverged` error
2. User performs `fetch` to retrieve commits E, F
3. User performs `rebase` of D onto F (with validation)
4. User retries push

**Critical**: Rebase performs schema validation, ensuring conflicts are resolved before retry.

---

## Protocol Details

### HTTP Headers

All HTTP requests include:
```prolog
request_header('Authorization'=Authorization),
request_header('TerminusDB-Version'=Version)
```

**Authorization**: Bearer token
**TerminusDB-Version**: Ensures protocol compatibility

### Endpoint URLs

#### Pack Endpoint (fetch)
```
POST /api/pack/{organization}/{database}
```

#### Unpack Endpoint (push)
```
POST /api/unpack/{organization}/{database}
```

#### TUS Upload Endpoint
```
POST /api/files
```

### Data Format

**Pack Structure**:
- Binary format containing layer data
- Includes commit metadata (author, message, timestamps)
- Parent-child relationships
- Layer IDs (content-addressed hashes)

---

## Performance Characteristics

### Time Complexity

1. **History Analysis**: O(commits since common ancestor)
2. **Commit Copy**: O(commits to push)
3. **Pack Creation**: O(layer data size)
4. **Network Transfer**: O(pack size)
5. **Metadata Update**: O(1)

### Space Complexity

- **Temporary**: Pack file size (compressed layers)
- **Permanent**: Metadata updates (KB per push)

### Optimization Strategies

1. **Pack Compression**: Reduces network transfer time
2. **TUS Protocol**: Enables resumable uploads for reliability
3. **Incremental Packing**: Only new layers since `Last_Head_Id`
4. **Lazy Layer Loading**: Layers not loaded until needed

---

## Error Handling & Edge Cases

### 1. Network Failures

**During TUS Upload**:
- TUS protocol supports resumption
- Client can retry from last uploaded chunk

**During HTTP POST**:
- Connection timeout: Infinite timeout allowed
- Network error: Propagated as `http_open_error`

### 2. Authorization Failures

**Local Auth**: Checked before any operations
**Remote Auth**: May fail at remote server
- Returns HTTP 401/403
- Wrapped as `remote_connection_failure`

### 3. Empty Branch Pushes

**Scenario**: Push empty local branch to empty remote
- Branch object created on remote
- No commits transferred
- Succeeds (lines 123-129)

**Scenario**: Push empty local branch to non-empty remote
- Error: `remote_not_empty_on_local_empty`
- Cannot push empty state over existing data

### 4. Concurrent Pushes

**Two users push simultaneously**:
- Both perform divergence check
- First push succeeds
- Second push detects divergence during `copy_commits`
- Second push fails with `remote_diverged`

---

## Security Considerations

### Authentication
- Required for all remote operations
- Bearer token in Authorization header
- Token validated at remote server

### Authorization Granularity

**Push Operation**:
- `push` action on source repository

**Local Push**:
- `commit_write_access` on destination repository

### Data Integrity

**Content Addressing**:
- Layer IDs are cryptographic hashes
- Tampering detected automatically

**Commit Chain**:
- Parent references prevent rewriting history
- Divergence detection ensures consistency

---

## Comparison: Push vs. Other Operations

| Aspect | Push | Pull | Fetch | Rebase |
|--------|------|------|-------|--------|
| Direction | Local → Remote | Remote → Local | Remote → Local | Local → Local |
| Schema validation | ❌ No | ❌ No | ❌ No | ✅ Yes |
| Conflict detection | ✅ Yes | ✅ Yes | ❌ No | ✅ Yes |
| History modification | ❌ No | ❌ No | ❌ No | ✅ Yes |
| Network required | ✅ Yes | ✅ Yes | ✅ Yes | ❌ No |

---

## Distributed Workflow Patterns

### Pattern 1: Linear Collaboration

```
Developer A: Write → Commit → Push
Developer B: Pull → Write → Commit → Push
Developer A: Pull → Write → Commit → Push
```

**Characteristics**:
- Simple, no conflicts
- Works if developers coordinate
- Pull always succeeds (fast-forward)

### Pattern 2: Parallel Development

```
Developer A: Write → Commit (A1)
Developer B: Write → Commit (B1)
Developer A: Push (succeeds)
Developer B: Push (fails: remote_diverged)
Developer B: Fetch → Rebase (B1 on A1) → Push (succeeds)
```

**Characteristics**:
- Common in distributed teams
- Requires rebase with validation
- Schema conflicts resolved during rebase

### Pattern 3: Hub-and-Spoke (Recommended for Scaling)

```
┌─────────┐
│ Writer 1│─── Push ───┐
└─────────┘            │
┌─────────┐            ▼
│ Writer 2│─── Push ──► Central Hub
└─────────┘            │
┌─────────┐            │
│ Writer 3│─── Push ───┘
└─────────┘
     │
     │ Pull
     ▼
┌─────────────┐
│ Aggregator  │
│   (builds   │
│  complete   │
│   view)     │
└─────────────┘
```

**Characteristics**:
- Each writer validates locally
- Central hub aggregates without validation
- Aggregator pulls to build unified view
- Scales horizontally

---

## Testing Push Operations

### Unit Tests in `db_push.pl`

**Location**: Lines 279-702

#### Key Test Scenarios:

1. **`push_on_empty`** (lines 296-335):
   - Push to new remote branch
   - Verifies commit transfer and data integrity

2. **`push_twice`** (lines 338-394):
   - Push, commit more, push again
   - Verifies incremental push

3. **`push_twice_with_second_push_changing_nothing`** (lines 396-435):
   - Push, then push again without changes
   - Verifies `same(Head)` response

4. **`push_empty_branch`** (lines 437-459):
   - Push empty branch to empty remote
   - Verifies branch creation

5. **`push_without_branch`** (lines 536-559):
   - Attempt to push non-existent branch
   - Expects error

6. **`push_local`** (lines 584-627):
   - Attempt to push to local repository
   - Expects `push_attempted_on_non_remote` error

---

## Code References

| Operation | File | Lines | Key Function |
|-----------|------|-------|--------------|
| Main push | `db_push.pl` | 39-163 | `push/8` |
| HTTP push | `db_push.pl` | 180-235 | `authorized_push/3` |
| Local push | `db_push.pl` | 237-271 | `local_push/5` |
| History check | `db_push.pl` | 104-116 | `most_recent_common_ancestor` |
| Pack creation | `db_pack.pl` | - | `pack_from_context/3` |
| TUS protocol | Library: `tus` | - | `tus_upload/4`, `tus_delete/3` |

---

## Troubleshooting Guide

### Problem: Push Rejected with `remote_diverged`

**Cause**: Remote has commits you don't know about  
**Solution**:
```bash
terminusdb fetch <remote>
terminusdb rebase <local-branch> <remote-branch>
terminusdb push <remote>
```

### Problem: `push_has_no_repository_head`

**Cause**: Never fetched from remote  
**Solution**:
```bash
terminusdb fetch <remote>
terminusdb push <remote>
```

### Problem: Push Hangs or Times Out

**Cause**: Large pack transfer or network issues  
**Solution**:
- Check network connectivity
- Verify remote server is responsive
- Consider TUS support for resumable uploads

### Problem: `push_attempted_on_non_remote`

**Cause**: Trying to push to local repository  
**Solution**: Only push to remotes configured with URLs

---

## Future Enhancements

### Potential Improvements

1. **Partial Push**: Push subset of branches
2. **Signed Commits**: Cryptographic signatures for auth
3. **Push Hooks**: Server-side validation hooks
4. **Bandwidth Throttling**: Rate-limited uploads
5. **Multi-Remote Push**: Push to multiple remotes in one operation

---

## Conclusion

The push operation in TerminusDB is designed for **reliability and conflict detection** in distributed environments. Key architectural principles:

1. **Divergence Detection**: Ensures data consistency across collaborators
2. **No Schema Validation**: Trusts local validation, optimizes performance
3. **Flexible Transport**: Supports both HTTP and local store-to-store
4. **TUS Protocol**: Enables reliable large-file transfers
5. **Atomic Operations**: Metadata updates are transactional

Combined with pull's non-validating approach, push enables TerminusDB to scale writes horizontally while maintaining eventual consistency through rebase operations.

---

**Document Version**: 1.0  
**Last Updated**: 2025-01-19  
**Author**: TerminusDB Architecture Documentation  
**Related**: `PULL_LIFECYCLE.md`, `REBASE_LIFECYCLE.md` (TBD)
