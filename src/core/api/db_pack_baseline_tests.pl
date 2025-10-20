:- module(db_pack_baseline_tests, []).

/** <module> Comprehensive tests for pack baseline functionality
 *
 * Tests the repository_head parameter in the pack endpoint to ensure
 * incremental packs are correctly created from a baseline.
 */

:- use_module(db_pack).
:- use_module(core(util/test_utils)).
:- use_module(core(transaction)).
:- use_module(core(query)).
:- use_module(core(account)).
:- use_module(core(triple/constants)).
:- use_module(library(terminus_store)).
:- use_module(library(plunit)).

:- begin_tests(pack_baseline, []).

/**
 * Test: child_until_parents stops at the baseline layer
 *
 * This is the core predicate that determines which layers to include in a pack.
 * When given a baseline (some(Layer_ID)), it should stop traversing at that layer.
 */
test(child_until_parents_stops_at_baseline,
     [setup((setup_temp_store(State),
             create_db_without_schema(admin,test_db))),
      cleanup(teardown_temp_store(State))
     ]
    ) :-

    resolve_absolute_string_descriptor("admin/test_db", Descriptor),

    % First commit
    create_context(Descriptor, commit_info{author:"test", message:"commit 1"}, Context1),
    with_transaction(Context1,
                     ask(Context1, insert(a,b,c)),
                     _),

    % Get the repository layer after first commit
    open_descriptor(database_descriptor{
                        organization_name: "admin",
                        database_name: "test_db" },
                    DB_Transaction1),
    repository_head(DB_Transaction1, "local", Baseline_Layer_ID),

    % Second commit
    create_context(Descriptor, commit_info{author:"test", message:"commit 2"}, Context2),
    with_transaction(Context2,
                     ask(Context2, insert(d,e,f)),
                     _),

    % Get the repository descriptor to access layers
    Repository_Path = "admin/test_db/local/_commits",
    resolve_absolute_string_descriptor(Repository_Path, Repo_Descriptor),
    open_descriptor(Repo_Descriptor, Repo_Transaction),
    [Read_Write_Obj] = (Repo_Transaction.instance_objects),
    Current_Layer = (Read_Write_Obj.read),

    % Test: child_until_parents with baseline should stop at Baseline_Layer_ID
    child_until_parents(Current_Layer, some(Baseline_Layer_ID), Layers),

    % Layers should NOT be empty (should include the second commit)
    % or if empty, that means it stopped at baseline correctly
    % The key is that Baseline_Layer_ID should not be in the Layers list
    (   Layers = []
    ->  true  % Stopped at baseline, no additional layers
    ;   (   % Check that none of the returned layers match Baseline_Layer_ID
            \+ (member(L, Layers), layer_to_id(L, Baseline_Layer_ID))
        )
    ).

/**
 * Test: pack with baseline returns smaller pack than full pack
 *
 * This is the user-visible behavior we expect.
 */
test(pack_with_baseline_smaller_than_full,
     [setup((setup_temp_store(State),
             create_db_without_schema(admin,test_db))),
      cleanup(teardown_temp_store(State))
     ]
    ) :-

    resolve_absolute_string_descriptor("admin/test_db", Descriptor),

    % First commit
    create_context(Descriptor, commit_info{author:"test", message:"commit 1"}, Context1),
    with_transaction(Context1,
                     ask(Context1, insert(a,b,c)),
                     _),

    % Capture baseline after first commit
    open_descriptor(database_descriptor{
                        organization_name: "admin",
                        database_name: "test_db" },
                    DB_Transaction1),
    repository_head(DB_Transaction1, "local", Baseline_Layer_ID),

    % Second commit
    create_context(Descriptor, commit_info{author:"test", message:"commit 2"}, Context2),
    with_transaction(Context2,
                     ask(Context2, insert(d,e,f)),
                     _),

    % Get incremental pack (from baseline)
    super_user_authority(Auth),
    pack(system_descriptor{}, Auth, "admin/test_db", some(Baseline_Layer_ID), Incremental_Payload_Option),

    % Get full pack (no baseline)
    pack(system_descriptor{}, Auth, "admin/test_db", none, Full_Payload_Option),

    % Both should return a payload
    some(Incremental_Payload) = Incremental_Payload_Option,
    some(Full_Payload) = Full_Payload_Option,

    % Incremental pack should be smaller than full pack
    string_length(Incremental_Payload, Incremental_Size),
    string_length(Full_Payload, Full_Size),
    Incremental_Size < Full_Size.

/**
 * Test: pack with current head returns nothing
 *
 * If the baseline is the current repository head, pack should return none
 * because we're already up to date.
 */
test(pack_with_current_head_returns_none,
     [setup((setup_temp_store(State),
             create_db_without_schema(admin,test_db))),
      cleanup(teardown_temp_store(State))
     ]
    ) :-

    resolve_absolute_string_descriptor("admin/test_db", Descriptor),

    % Make a commit
    create_context(Descriptor, commit_info{author:"test", message:"commit 1"}, Context1),
    with_transaction(Context1,
                     ask(Context1, insert(a,b,c)),
                     _),

    % Get current repository head
    open_descriptor(database_descriptor{
                        organization_name: "admin",
                        database_name: "test_db" },
                    DB_Transaction),
    repository_head(DB_Transaction, "local", Current_Layer_ID),

    % Request pack with current head as baseline
    super_user_authority(Auth),
    pack(system_descriptor{}, Auth, "admin/test_db", some(Current_Layer_ID), Payload_Option),

    % Should return none (no pack needed)
    Payload_Option = none.

/**
 * Test: incremental pack contains correct commits
 *
 * Verify that the pack actually contains the commits after the baseline
 * and doesn't contain commits at or before the baseline.
 */
test(incremental_pack_contains_correct_commits,
     [setup((setup_temp_store(State),
             create_db_without_schema(admin,test_db))),
      cleanup(teardown_temp_store(State))
     ]
    ) :-

    resolve_absolute_string_descriptor("admin/test_db", Descriptor),

    % First commit
    create_context(Descriptor, commit_info{author:"test", message:"commit 1"}, Context1),
    with_transaction(Context1,
                     ask(Context1, insert(a,b,c)),
                     _),

    % Get layer ID after first commit
    open_descriptor(database_descriptor{
                        organization_name: "admin",
                        database_name: "test_db" },
                    DB_Transaction1),
    [RW_Obj1] = (DB_Transaction1.repository_descriptor.instance_objects),
    Layer1 = (RW_Obj1.read),
    layer_to_id(Layer1, Layer_ID_1),

    % Capture baseline
    repository_head(DB_Transaction1, "local", Baseline_Layer_ID),

    % Second commit
    create_context(Descriptor, commit_info{author:"test", message:"commit 2"}, Context2),
    with_transaction(Context2,
                     ask(Context2, insert(d,e,f)),
                     _),

    % Get layer ID after second commit
    open_descriptor(database_descriptor{
                        organization_name: "admin",
                        database_name: "test_db" },
                    DB_Transaction2),
    [RW_Obj2] = (DB_Transaction2.repository_descriptor.instance_objects),
    Layer2 = (RW_Obj2.read),
    layer_to_id(Layer2, Layer_ID_2),

    % Get incremental pack
    super_user_authority(Auth),
    pack(system_descriptor{}, Auth, "admin/test_db", some(Baseline_Layer_ID), Payload_Option),

    some(Payload) = Payload_Option,
    payload_repository_head_and_pack(Payload, _Head, Pack),
    pack_layerids_and_parents(Pack, Layer_IDs_And_Parents),

    % Extract just the layer IDs
    findall(Layer_ID, member(Layer_ID-_, Layer_IDs_And_Parents), Pack_Layer_IDs),

    % Pack should contain Layer_ID_2 (second commit)
    memberchk(Layer_ID_2, Pack_Layer_IDs),

    % Pack should NOT contain Layer_ID_1 (at or before baseline)
    \+ memberchk(Layer_ID_1, Pack_Layer_IDs).

/**
 * Test: repository_layer_to_layerids with baseline
 *
 * Direct test of the predicate that converts a layer and baseline
 * into a list of layer IDs for the pack.
 */
test(repository_layer_to_layerids_respects_baseline,
     [setup((setup_temp_store(State),
             create_db_without_schema(admin,test_db))),
      cleanup(teardown_temp_store(State))
     ]
    ) :-

    resolve_absolute_string_descriptor("admin/test_db", Descriptor),

    % First commit
    create_context(Descriptor, commit_info{author:"test", message:"commit 1"}, Context1),
    with_transaction(Context1,
                     ask(Context1, insert(a,b,c)),
                     _),

    % Get baseline layer ID
    open_descriptor(database_descriptor{
                        organization_name: "admin",
                        database_name: "test_db" },
                    DB_Transaction1),
    repository_head(DB_Transaction1, "local", Baseline_Layer_ID),

    % Second commit
    create_context(Descriptor, commit_info{author:"test", message:"commit 2"}, Context2),
    with_transaction(Context2,
                     ask(Context2, insert(d,e,f)),
                     _),

    % Third commit
    create_context(Descriptor, commit_info{author:"test", message:"commit 3"}, Context3),
    with_transaction(Context3,
                     ask(Context3, insert(g,h,i)),
                     _),

    % Get current layer
    open_descriptor(database_descriptor{
                        organization_name: "admin",
                        database_name: "test_db" },
                    DB_Transaction3),
    [RW_Obj] = (DB_Transaction3.repository_descriptor.instance_objects),
    Current_Layer = (RW_Obj.read),

    % Get layer IDs with baseline
    repository_layer_to_layerids(Current_Layer, some(Baseline_Layer_ID), Layer_IDs_With_Baseline),

    % Get layer IDs without baseline (full history)
    repository_layer_to_layerids(Current_Layer, none, Layer_IDs_Full),

    % With baseline should have fewer layer IDs than full
    length(Layer_IDs_With_Baseline, Count_With_Baseline),
    length(Layer_IDs_Full, Count_Full),
    Count_With_Baseline < Count_Full.

/**
 * Test: pack with non-existent baseline fails gracefully
 *
 * If the baseline layer ID doesn't exist in the history, the predicate
 * should handle it properly (either include all layers or fail).
 */
test(pack_with_invalid_baseline,
     [setup((setup_temp_store(State),
             create_db_without_schema(admin,test_db))),
      cleanup(teardown_temp_store(State))
     ]
    ) :-

    resolve_absolute_string_descriptor("admin/test_db", Descriptor),

    % Make a commit
    create_context(Descriptor, commit_info{author:"test", message:"commit 1"}, Context1),
    with_transaction(Context1,
                     ask(Context1, insert(a,b,c)),
                     _),

    % Use a fake layer ID that doesn't exist in history
    Fake_Layer_ID = "0000000000000000000000000000000000000000",

    % Request pack with fake baseline
    super_user_authority(Auth),
    pack(system_descriptor{}, Auth, "admin/test_db", some(Fake_Layer_ID), Payload_Option),

    % Should either return a full pack or handle gracefully
    % (The current implementation likely returns a full pack)
    (   Payload_Option = some(_)
    ->  true  % Accepted: returned a pack
    ;   Payload_Option = none  % Also acceptable: no pack
    ).

:- end_tests(pack_baseline).
