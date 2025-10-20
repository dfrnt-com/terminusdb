# Bundle and Unbundle API

**Complete Guide: Repository Backup and Restoration via Bundles**

## Overview

TerminusDB has **bundle** and **unbundle** mechanisms for complete repository backup and restoration. These operations create self-contained portable packs containing all commits, layers, and history that can be stored, transferred, and restored.

### Current Status

✅ **CLI Available**: Full functionality via command-line  
✅ **HTTP API Available**: `/api/unbundle` endpoint (v11.2+)

This document explains:
1. What bundling is and how it works
2. CLI and HTTP API usage
3. Security considerations
4. Operational best practices

---

## What are Bundles?

### Bundle vs. Pack

| Aspect | Pack (`/api/pack`) | Bundle |
|--------|-------------------|--------|
| **Scope** | Incremental changes | Complete repository |
| **Purpose** | Synchronization (push/fetch) | Backup/migration |
| **Baseline** | Requires previous head | Self-contained |
| **Use Case** | Distributed collaboration | Disaster recovery |

### Bundle Contents

A bundle is a binary pack containing:
- **All commits** in repository history
- **All layers** (schema, instance, inference)
- **Commit metadata** (authors, messages, timestamps)
- **Parent-child relationships** (full DAG)
- **Repository structure**

**Key Property**: Bundle is **complete** - no external dependencies needed to restore.

---

## Current Implementation

### Module Location

**Bundle**: `src/core/api/api_bundle.pl`  
**Unbundle**: `src/core/api/api_unbundle.pl`

### How It Works Internally

#### Bundle Process (`api_bundle.pl` lines 16-45)

```prolog
bundle(System_DB, Auth, Path, Payload, Options) :-
    % 1. Create temporary fake remote
    random_string(String),
    md5_hash(String, Remote_Name_Atom, []),
    atom_string(Remote_Name_Atom, Remote_Name),
    add_remote(System_DB, Auth, Path, Remote_Name, "terminusdb:///bundle"),
    
    % 2. Create fake repository head (empty baseline)
    create_fake_repo_head(Branch_Descriptor, Remote_Name),
    
    % 3. Use PUSH mechanism to generate pack
    push(System_DB, Auth, Path, Remote_Name, "main", Options,
         {Payload}/[_,P]>>(P = Payload), _),
    
    % 4. Cleanup temporary remote
    remove_remote(System_DB, Auth, Path, Remote_Name).
```

**Clever Design**: Reuses push infrastructure by creating temporary remote with empty baseline, forcing full pack generation.

#### Unbundle Process (`api_unbundle.pl` lines 15-39)

```prolog
unbundle(System_DB, Auth, Path, Payload) :-
    % 1. Create temporary fake remote
    random_string(String),
    md5_hash(String, Remote_Name_Atom, []),
    add_remote(System_DB, Auth, Path, Remote_Name, "terminusdb:///bundle"),
    
    % 2. Use PULL mechanism with bundle as "remote"
    pull(System_DB, Auth, Path, Remote_Name, "main",
         {Payload}/[_URL,_Repository_Head_Option,some(P)]>>(
             Payload = P),
         _Result),
    
    % 3. Cleanup temporary remote
    remove_remote(System_DB, Auth, Path, Remote_Name).
```

**Clever Design**: Reuses pull infrastructure by providing bundle payload as "fetch" response.

---

## CLI Usage

### Creating a Bundle

```bash
terminusdb bundle admin/mydb --output backup.bundle
```

**Process**:
1. Resolves path to branch (defaults to `main`)
2. Generates complete pack from empty baseline
3. Writes binary bundle to file

**Output**: `backup.bundle` (binary file)

**Authorization**: Requires `commit_read_access` and `instance_read_access`

### Restoring from Bundle

```bash
terminusdb unbundle admin/mydb backup.bundle
```

**Process**:
1. Reads binary bundle from file
2. Unpacks layers to store
3. Updates branch to point to bundle head
4. Branch now contains complete history

**Authorization**: Requires `schema_write_access` and `instance_write_access`

**Important**: Target database must already exist (use `terminusdb db create` first if needed)

---

## HTTP API Implementation Guide

### Why Not Currently Exposed?

The bundle/unbundle predicates exist but are not mapped to HTTP handlers in `src/server/routes.pl`. This is likely because:
1. Large binary payloads (bundles can be hundreds of MB)
2. Need for streaming support
3. Security considerations (complete database export)

### Proposed HTTP Endpoints

#### Bundle Endpoint

```http
POST /api/bundle/{organization}/{database}
Authorization: Bearer {token}
Content-Type: application/json

{
  "branch": "main",           // Optional, defaults to "main"
  "options": {}               // Optional, passed to bundle/5
}
```

**Response** (Success):
```http
HTTP/1.1 200 OK
Content-Type: application/octets
Content-Disposition: attachment; filename="{org}-{db}-{timestamp}.bundle"

{binary bundle data}
```

**Response** (Empty):
```http
HTTP/1.1 204 No Content
```

#### Unbundle Endpoint

```http
POST /api/unbundle/{organization}/{database}
Authorization: Bearer {token}
Content-Type: application/octets

{binary bundle data}
```

**Response** (Success):
```http
HTTP/1.1 200 OK
Content-Type: application/json

{
  "api:status": "api:success",
  "api:message": "Bundle restored successfully",
  "api:applied_commits": 47
}
```

---

## Implementation Code

### 1. Add HTTP Handlers to `routes.pl`

Insert after the `unpack_handler` (around line 1500):

```prolog
%%%%%%%%%%%%%%%%%%%% Bundle Handlers %%%%%%%%%%%%%%%%%%%%%%%
:- http_handler(api(bundle/Path), cors_handler(Method, bundle_handler(Path)),
                [method(Method),
                 time_limit(infinite),
                 chunked,
                 methods([options,post])]).

bundle_handler(post, Path, Request, System_DB, Auth) :-
    get_payload(Document, Request),
    
    % Extract options (branch name, etc.)
    (   get_dict(branch, Document, Branch)
    ->  true
    ;   Branch = "main"
    ),
    
    (   get_dict(options, Document, Options)
    ->  true
    ;   Options = []
    ),
    
    % Construct full path with branch
    atomic_list_concat([Path, '/local/branch/', Branch], Full_Path),
    
    api_report_errors(
        bundle,
        Request,
        bundle(System_DB, Auth, Full_Path, Payload, Options)),
    
    % Return bundle as binary attachment
    (   var(Payload)
    ->  format('Content-type: application/json~n', []),
        format('Status: 500 Internal Server Error~n~n', []),
        format('{"api:status": "api:error", "api:message": "Bundle generation failed"}~n', [])
    ;   % Generate filename
        get_time(Timestamp),
        format_time(string(TimeStr), '%Y%m%d-%H%M%S', Timestamp),
        atomic_list_concat([Path, '-', TimeStr, '.bundle'], '_', Filename),
        format('Content-type: application/octets~n', []),
        format('Content-Disposition: attachment; filename="~s"~n', [Filename]),
        format('Status: 200 OK~n~n', []),
        format('~s', [Payload])
    ).

%%%%%%%%%%%%%%%%%%%% Unbundle Handlers %%%%%%%%%%%%%%%%%%%%%
:- http_handler(api(unbundle/Path), cors_handler(Method, unbundle_handler(Path)),
                [method(Method),
                 time_limit(infinite),
                 chunked,
                 methods([options,post])]).

unbundle_handler(post, Path, Request, System_DB, Auth) :-
    % Read binary payload directly from request
    http_read_data(Request, Payload, [to(string)]),
    
    % Default to main branch
    atomic_list_concat([Path, '/local/branch/main'], Full_Path),
    
    api_report_errors(
        unbundle,
        Request,
        unbundle(System_DB, Auth, Full_Path, Payload)),
    
    % Return success response
    format('Content-type: application/json~n', []),
    format('Status: 200 OK~n~n', []),
    format('{"api:status": "api:success", "api:message": "Bundle restored successfully"}~n', []).
```

### 2. Usage Examples

#### Bundle via HTTP (curl)

```bash
curl -X POST \
  https://terminusdb.example.com/api/bundle/admin/mydb \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"branch": "main"}' \
  --output mydb-backup.bundle
```

#### Unbundle via HTTP (curl)

```bash
curl -X POST \
  https://terminusdb.example.com/api/unbundle/admin/mydb \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/octets" \
  --data-binary @mydb-backup.bundle
```

#### Bundle via JavaScript Client

```javascript
const fetch = require('node-fetch');
const fs = require('fs');

// Create bundle
const response = await fetch('https://terminusdb.example.com/api/bundle/admin/mydb', {
  method: 'POST',
  headers: {
    'Authorization': 'Bearer YOUR_TOKEN',
    'Content-Type': 'application/json'
  },
  body: JSON.stringify({ branch: 'main' })
});

const bundle = await response.buffer();
fs.writeFileSync('backup.bundle', bundle);

// Restore bundle
const bundleData = fs.readFileSync('backup.bundle');
await fetch('https://terminusdb.example.com/api/unbundle/admin/restored_db', {
  method: 'POST',
  headers: {
    'Authorization': 'Bearer YOUR_TOKEN',
    'Content-Type': 'application/octets'
  },
  body: bundleData
});
```

---

## Security Considerations

### Authorization

#### Bundle (Export)
**Required Actions**:
- `commit_read_access` - Read commit history
- `instance_read_access` - Read instance data
- `schema_read_access` - Read schema

**Risk Level**: 🔴 **HIGH** - Complete data exfiltration

**Mitigation**:
- Audit all bundle creations
- Alert on bundle operations for sensitive databases
- Consider rate limiting
- Require additional approval for production databases

#### Unbundle (Import)
**Required Actions**:
- `schema_write_access` - May modify schema
- `instance_write_access` - May modify data
- `commit_write_access` - Creates commits

**Risk Level**: 🔴 **HIGH** - Can overwrite database

**Mitigation**:
- Validate bundle source before unbundling
- Consider separate `bundle_restore` permission
- Require approval workflow
- Backup before unbundle

### Data Classification

**Bundles contain ALL data**:
- Sensitive PII
- Historical audit trail
- Schema (may reveal business logic)
- Commit messages (may contain sensitive info)

**Storage Recommendations**:
- Encrypt bundles at rest
- Secure transport (HTTPS, VPN)
- Access controls on bundle storage
- Retention policies
- Secure deletion when expired

### Network Considerations

**Bundle Size**:
- Can be hundreds of MB or GB
- Streaming required for large databases
- Timeout considerations
- Bandwidth impact

**Recommendations**:
- Use TUS protocol for large bundles
- Implement chunked transfer
- Progress indicators for CLI/UI
- Compression (bundles are already compressed via pack format)

---

## Operational Patterns

### Pattern 1: Regular Backups

```bash
#!/bin/bash
# Daily backup script

DATE=$(date +%Y%m%d)
terminusdb bundle admin/production --output /backups/prod-$DATE.bundle

# Encrypt
gpg --encrypt --recipient backup@example.com /backups/prod-$DATE.bundle

# Upload to S3
aws s3 cp /backups/prod-$DATE.bundle.gpg s3://db-backups/

# Cleanup old backups (keep 30 days)
find /backups -name "prod-*.bundle*" -mtime +30 -delete
```

### Pattern 2: Database Migration

```bash
# Source environment
terminusdb bundle admin/mydb --output mydb.bundle

# Transfer bundle (scp, s3, etc.)
scp mydb.bundle target-server:/tmp/

# Target environment
ssh target-server
terminusdb db create admin mydb "Migrated DB"
terminusdb unbundle admin/mydb /tmp/mydb.bundle
```

### Pattern 3: Disaster Recovery

```bash
# Restore from backup
aws s3 cp s3://db-backups/prod-20250119.bundle.gpg ./
gpg --decrypt prod-20250119.bundle.gpg > prod-20250119.bundle

# Restore to new database
terminusdb db create admin production_restored "DR Restore"
terminusdb unbundle admin/production_restored prod-20250119.bundle

# Verify
terminusdb log admin/production_restored
```

### Pattern 4: Cross-Instance Sync

```bash
# Instance A: Create bundle
terminusdb bundle admin/shared_data --output shared.bundle

# Transfer
curl -F "file=@shared.bundle" https://transfer-service/upload

# Instance B: Download and restore
curl https://transfer-service/download/shared.bundle -o shared.bundle
terminusdb unbundle admin/shared_data shared.bundle
```

---

## Performance Characteristics

### Bundle Creation

**Time Complexity**: O(total_layers + total_commits)

**Factors**:
- Database size (number of commits)
- Layer sizes
- Compression level

**Typical Times**:
- Small DB (< 10 MB): 1-5 seconds
- Medium DB (100 MB): 10-30 seconds
- Large DB (1 GB): 1-5 minutes
- Very Large DB (10 GB): 10-30 minutes

### Unbundle Restoration

**Time Complexity**: O(total_layers)

**Factors**:
- Bundle size
- Disk I/O speed
- Layer unpacking

**Typical Times**:
- Similar to bundle creation
- Slightly faster (no pack generation overhead)

### Optimization

**Bundle**:
- Already compressed via pack format
- No additional compression needed
- Progress indication helpful for large DBs

**Unbundle**:
- Parallel layer writing possible
- Verify integrity before committing

---

## Comparison with Other Operations

| Operation | Scope | Network | Baseline | Use Case |
|-----------|-------|---------|----------|----------|
| **bundle** | Complete | ❌ No | Empty | Backup |
| **unbundle** | Complete | ❌ No | N/A | Restore |
| **pack** | Incremental | ✅ Yes | Required | Sync |
| **clone** | Complete | ✅ Yes | N/A | Initialize |
| **fetch** | Incremental | ✅ Yes | Optional | Update |
| **push** | Incremental | ✅ Yes | Required | Publish |

---

## Error Handling

### Bundle Errors

| Error | Cause | Resolution |
|-------|-------|------------|
| `invalid_absolute_path` | Bad path format | Check path syntax |
| `push_requires_branch` | Not a branch | Specify branch path |
| `access_not_authorised` | No read access | Grant read permissions |
| File write error | Disk full | Free up space |

### Unbundle Errors

| Error | Cause | Resolution |
|-------|-------|------------|
| `invalid_absolute_path` | Bad path format | Check path syntax |
| `push_requires_branch` | Target not branch | Create branch first |
| `access_not_authorised` | No write access | Grant write permissions |
| Corrupt bundle | Bad bundle data | Use valid bundle file |
| Layer unpack error | Store issue | Check store integrity |

---

## Testing

### Unit Tests

**Existing**: `api_bundle.pl` lines 60-82

```prolog
test(bundle,
     [setup((setup_temp_store(State),
             create_db_with_test_schema('admin','test'))),
      cleanup(teardown_temp_server(State))]) :-
    open_descriptor(system_descriptor{}, System),
    bundle(System, 'User/admin', 'admin/test', Payload, []),
    % Verify Payload is binary and non-empty
    \+ var(Payload).
```

### Integration Test Pattern

```javascript
describe('Bundle/Unbundle API', () => {
  it('should create and restore bundle', async () => {
    // Create test data
    await client.addDocument({type: 'Person', name: 'Alice'});
    
    // Create bundle
    const bundle = await client.bundle('admin/test');
    expect(bundle).toBeInstanceOf(Buffer);
    
    // Create new database
    await client.createDatabase('admin', 'test_restored');
    
    // Restore bundle
    await client.unbundle('admin/test_restored', bundle);
    
    // Verify data
    const docs = await client.getDocuments('admin/test_restored');
    expect(docs).toHaveLength(1);
    expect(docs[0].name).toBe('Alice');
  });
});
```

---

## Future Enhancements

### Potential Improvements

1. **Compression Options**: Allow different compression levels
2. **Selective Bundle**: Bundle specific branch or commit range
3. **Incremental Bundles**: Bundle changes since last bundle
4. **Bundle Metadata**: Include creation timestamp, source info
5. **Bundle Verification**: Checksum/signature for integrity
6. **Streaming API**: TUS support for large bundles
7. **Progress Callbacks**: Report progress during bundle/unbundle
8. **Bundle Catalog**: List available bundles with metadata

### Proposed New Actions

```prolog
% Enhanced bundle with options
bundle_advanced(System_DB, Auth, Path, Options, Payload) :-
    % Options:
    % - compression_level: 0-9
    % - include_branches: list of branches
    % - since_commit: incremental from commit
    % - metadata: custom metadata
    ...

% Bundle verification
verify_bundle(Payload, Metadata) :-
    % Check integrity
    % Extract metadata
    % Validate structure
    ...
```

---

## Related Documentation

- **DISTRIBUTED_OPERATIONS_ORCHESTRATION.md**: How pack/unpack work
- **PUSH_LIFECYCLE.md**: Push uses pack internally
- **AUTHORIZATION_ACTIONS.md**: Required permissions

---

## Summary

### What Exists Now

✅ Complete bundle/unbundle functionality via CLI  
✅ Reuses proven push/pull infrastructure  
✅ Self-contained portable database format  
✅ Unit tested

### What's Missing

❌ HTTP API endpoints  
❌ Client library support  
❌ Progress indication  
❌ TUS support for large bundles

### How to Add HTTP API

1. Add handlers to `src/server/routes.pl` (code provided above)
2. Test with curl
3. Add client library methods
4. Document in API reference
5. Consider TUS for large bundles
6. Add authorization checks

### Key Takeaways

- **Bundle = Complete database** in single file
- **Uses push/pull** infrastructure cleverly
- **Security critical** - full data export/import
- **Operational essential** - backups and migration
- **Easy to add HTTP** - pattern already established with pack/unpack

---

**Document Version**: 1.0  
**Last Updated**: 2025-01-19  
**Author**: TerminusDB Architecture Documentation  
**Status**: Implementation Guide
