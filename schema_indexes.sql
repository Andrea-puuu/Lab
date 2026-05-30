-- =============================================================================
-- schema_indexes.sql
--
-- SQL schema and indexes derived from the BusTub C++ data structures
-- introduced in project1-submission (commit e8ef90f) and
-- project2-submission (commit efaa752).
--
-- Each table mirrors a core C++ class; indexes target columns that
-- appear in WHERE, JOIN, or ORDER BY access patterns found in the
-- implementation code.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. buffer_pool_pages
--    Source: BufferPoolManagerInstance  (project 1)
--    Models the in-memory page table that maps page ids to buffer frames.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS buffer_pool_pages (
    page_id    INT  NOT NULL,
    frame_id   INT  NOT NULL,
    pin_count  INT  NOT NULL DEFAULT 0,
    is_dirty   BOOLEAN NOT NULL DEFAULT FALSE,
    PRIMARY KEY (page_id)
);

-- FetchPgImp / UnpinPgImp / FlushPgImp / DeletePgImp all look up by page_id.
-- The PRIMARY KEY already covers this; add a secondary index on frame_id for
-- the reverse mapping used during eviction (pages_[frame_id]).
CREATE INDEX idx_bpp_frame_id   ON buffer_pool_pages (frame_id);

-- FlushAllPgsImp filters by is_dirty to decide which pages need flushing.
CREATE INDEX idx_bpp_is_dirty   ON buffer_pool_pages (is_dirty);

-- Eviction path checks pin_count = 0  (WHERE pin_count = 0).
CREATE INDEX idx_bpp_pin_count  ON buffer_pool_pages (pin_count);

-- ---------------------------------------------------------------------------
-- 2. lru_k_frames
--    Source: LRUKReplacer / FrameInfo  (project 1)
--    Tracks per-frame access history used by the LRU-K eviction policy.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lru_k_frames (
    frame_id              INT     NOT NULL,
    evictable             BOOLEAN NOT NULL DEFAULT FALSE,
    last_access_timestamp BIGINT  NOT NULL DEFAULT 0,
    access_count          INT     NOT NULL DEFAULT 0,
    PRIMARY KEY (frame_id)
);

-- RecordAccess / SetEvictable / Remove all look up by frame_id (PK covers it).

-- Evict() scans for evictable = TRUE and then orders by backward k-distance,
-- which is derived from last_access_timestamp.
-- Composite index lets the engine filter + sort in one pass.
CREATE INDEX idx_lru_evictable_ts ON lru_k_frames (evictable, last_access_timestamp);

-- ---------------------------------------------------------------------------
-- 3. lru_k_access_history
--    Source: FrameInfo::access_timestamps  (project 1)
--    Stores the per-frame access timestamp list used to compute k-distance.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lru_k_access_history (
    frame_id   INT    NOT NULL,
    seq        INT    NOT NULL,
    timestamp  BIGINT NOT NULL,
    PRIMARY KEY (frame_id, seq)
);

-- Evict() reads timestamps for a given frame and compares the k-th oldest.
-- JOIN to lru_k_frames on frame_id, ORDER BY seq / timestamp.
CREATE INDEX idx_lru_history_frame_ts ON lru_k_access_history (frame_id, timestamp);

-- ---------------------------------------------------------------------------
-- 4. hash_directory
--    Source: ExtendibleHashTable directory  (project 1)
--    The extensible-hashing directory that maps bucket indices to buckets.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS hash_directory (
    dir_index    INT NOT NULL,
    bucket_id    INT NOT NULL,
    global_depth INT NOT NULL DEFAULT 0,
    PRIMARY KEY (dir_index)
);

-- Insert() checks dir_[idx] — lookup by dir_index (PK).
-- Split path iterates directory entries that point to the same bucket.
CREATE INDEX idx_hdir_bucket_id ON hash_directory (bucket_id);

-- ---------------------------------------------------------------------------
-- 5. hash_buckets
--    Source: ExtendibleHashTable::Bucket  (project 1)
--    Key-value pairs stored inside each hash bucket.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS hash_buckets (
    bucket_id   INT NOT NULL,
    key_value   INT NOT NULL,
    stored_val  INT NOT NULL,
    local_depth INT NOT NULL DEFAULT 0,
    PRIMARY KEY (bucket_id, key_value)
);

-- Find / Remove scan bucket items WHERE key_value = ? within a bucket.
CREATE INDEX idx_hbkt_key ON hash_buckets (key_value);

-- Redistribution during split filters by local_depth.
CREATE INDEX idx_hbkt_depth ON hash_buckets (bucket_id, local_depth);

-- ---------------------------------------------------------------------------
-- 6. b_plus_tree_pages  (base header)
--    Source: BPlusTreePage  (project 2)
--    Common header shared by both internal and leaf B+ tree pages.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS b_plus_tree_pages (
    page_id        INT NOT NULL,
    page_type      INT NOT NULL DEFAULT 0,   -- 0 = INVALID, 1 = LEAF, 2 = INTERNAL
    lsn            INT NOT NULL DEFAULT 0,
    current_size   INT NOT NULL DEFAULT 0,
    max_size       INT NOT NULL DEFAULT 0,
    parent_page_id INT,
    PRIMARY KEY (page_id)
);

-- FindLeafPage traverses from root to leaf using parent/child links (JOIN).
CREATE INDEX idx_btp_parent ON b_plus_tree_pages (parent_page_id);

-- IsLeafPage() checks page_type to decide traversal direction (WHERE).
CREATE INDEX idx_btp_type   ON b_plus_tree_pages (page_type);

-- CoalesceOrRedistribute checks current_size < min_size (WHERE).
CREATE INDEX idx_btp_size   ON b_plus_tree_pages (current_size);

-- ---------------------------------------------------------------------------
-- 7. b_plus_tree_internal_entries
--    Source: BPlusTreeInternalPage  (project 2)
--    Routing entries inside internal (non-leaf) B+ tree nodes.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS b_plus_tree_internal_entries (
    page_id        INT NOT NULL,
    entry_index    INT NOT NULL,
    key_value      INT NOT NULL,
    child_page_id  INT NOT NULL,
    PRIMARY KEY (page_id, entry_index)
);

-- FindLeafPage does binary search on key_value within a page (WHERE + ORDER BY).
CREATE INDEX idx_btie_page_key ON b_plus_tree_internal_entries (page_id, key_value);

-- InsertIntoParent / CoalesceOrRedistribute follow child_page_id links (JOIN).
CREATE INDEX idx_btie_child    ON b_plus_tree_internal_entries (child_page_id);

-- ---------------------------------------------------------------------------
-- 8. b_plus_tree_leaf_entries
--    Source: BPlusTreeLeafPage  (project 2)
--    Data entries stored in B+ tree leaf nodes.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS b_plus_tree_leaf_entries (
    page_id       INT NOT NULL,
    entry_index   INT NOT NULL,
    key_value     INT NOT NULL,
    rid           BIGINT NOT NULL,  -- record id (page_id + slot_id)
    next_page_id  INT,              -- sibling pointer for range scans
    PRIMARY KEY (page_id, entry_index)
);

-- GetValue() performs binary search on key_value within a leaf (WHERE + ORDER BY).
CREATE INDEX idx_btle_page_key  ON b_plus_tree_leaf_entries (page_id, key_value);

-- Begin() / index iterator traverse leaves via next_page_id (JOIN / ORDER BY).
CREATE INDEX idx_btle_next_page ON b_plus_tree_leaf_entries (next_page_id);

-- Range scan across all leaves ordered by key_value.
CREATE INDEX idx_btle_key_global ON b_plus_tree_leaf_entries (key_value);

-- ---------------------------------------------------------------------------
-- 9. b_plus_tree_meta
--    Source: BPlusTree header / root tracking  (project 2)
--    Tracks root page id and tree metadata (UpdateRootPageId).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS b_plus_tree_meta (
    index_name     VARCHAR(256) NOT NULL,
    root_page_id   INT NOT NULL,
    PRIMARY KEY (index_name)
);

-- GetRootPageId / UpdateRootPageId look up by index_name (PK).
-- Join to b_plus_tree_pages on root_page_id.
CREATE INDEX idx_btm_root ON b_plus_tree_meta (root_page_id);
