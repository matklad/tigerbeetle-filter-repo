//! Verify deterministic storage.
//!
//! At each replica compact and checkpoint, check that storage is byte-for-byte identical across
//! replicas.
//!
//! Areas verified at compaction (half-measure):
//! - Acquired Grid blocks (ignores skipped recovery compactions)
//!  TODO Because ManifestLog acquires blocks potentially several beats prior to actually writing
//!  the block, this check will need to be removed or use a different strategy.
//!
//! Areas verified at checkpoint:
//! - SuperBlock trailers (Manifest, FreeSet, ClientSessions)
//! - ClientReplies (when repair finishes)
//! - Acquired Grid blocks (when syncing finishes)
//!
//! Areas not verified:
//! - SuperBlock headers, which hold replica-specific state.
//! - WAL headers, which may differ because the WAL writes deliberately corrupt redundant headers
//!   to faulty slots to ensure recovery is consistent.
//! - WAL prepares — a replica can commit + checkpoint an op before it is persisted to the WAL.
//!   (The primary can commit from the pipeline-queue, backups can commit from the pipeline-cache.)
//! - Non-allocated Grid blocks, which may differ due to state sync.
const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.storage_checker);

const constants = @import("../../constants.zig");
const stdx = @import("../../stdx.zig");
const vsr = @import("../../vsr.zig");
const schema = @import("../../lsm/schema.zig");
const Storage = @import("../storage.zig").Storage;

/// After each compaction half measure, save the cumulative hash of all acquired grid blocks.
///
/// (Track half-measures instead of beats because the on-disk state mid-compaction is
/// nondeterministic; it depends on IO progress.)
const Compactions = std.ArrayList(u128);

/// Maps from op_checkpoint to cumulative storage checksum.
///
/// Not every checkpoint is necessarily recorded — a replica calls on_checkpoint *at most* once.
/// For example, a replica will not call on_checkpoint if it crashes (during a checkpoint) after
/// writing 2 superblock copies. (This could be repeated by other replicas, causing a checkpoint
/// op to be skipped in Checkpoints).
const Checkpoints = std.AutoHashMap(u64, Checkpoint);

const CheckpointArea = enum {
    superblock_manifest,
    superblock_free_set,
    superblock_client_sessions,
    client_replies,
    grid,
};

const Checkpoint = std.enums.EnumArray(CheckpointArea, u128);

pub const StorageChecker = struct {
    const SuperBlock = vsr.SuperBlockType(Storage);

    compactions: Compactions,
    checkpoints: Checkpoints,

    free_set: SuperBlock.FreeSet,

    pub fn init(allocator: std.mem.Allocator) !StorageChecker {
        var compactions = Compactions.init(allocator);
        errdefer compactions.deinit();

        var checkpoints = Checkpoints.init(allocator);
        errdefer checkpoints.deinit();

        var free_set = try SuperBlock.FreeSet.init(allocator, vsr.superblock.grid_blocks_max);
        errdefer free_set.deinit(allocator);

        return StorageChecker{
            .compactions = compactions,
            .checkpoints = checkpoints,
            .free_set = free_set,
        };
    }

    pub fn deinit(checker: *StorageChecker, allocator: std.mem.Allocator) void {
        checker.free_set.deinit(allocator);
        checker.checkpoints.deinit();
        checker.compactions.deinit();
    }

    pub fn replica_checkpoint(checker: *StorageChecker, superblock: *const SuperBlock) !void {
        const replica_checkpoint_op = superblock.working.vsr_state.commit_min;

        var checkpoint_actual = std.enums.EnumMap(CheckpointArea, u128).init(.{
            .superblock_manifest = checksum_trailer(superblock, .manifest),
            .superblock_free_set = checksum_trailer(superblock, .free_set),
            .superblock_client_sessions = checksum_trailer(superblock, .client_sessions),
        });

        const syncing = superblock.working.vsr_state.sync_op_max > 0;
        if (!syncing) {
            checkpoint_actual.put(.client_replies, checksum_client_replies(superblock));
            checkpoint_actual.put(.grid, checker.checksum_grid(superblock));
        }

        for (std.enums.values(CheckpointArea)) |area| {
            log.debug("{}: replica_checkpoint: checkpoint={} area={s} value={?x:0>32}", .{
                superblock.replica_index.?,
                replica_checkpoint_op,
                @tagName(area),
                checkpoint_actual.get(area),
            });
        }

        const checkpoint_expect = checker.checkpoints.get(replica_checkpoint_op) orelse {
            if (!syncing) {
                // This replica is the first to reach op_checkpoint.
                // Save its state for other replicas to check themselves against.
                var checkpoint: Checkpoint = undefined;
                for (std.enums.values(CheckpointArea)) |area| {
                    checkpoint.set(area, checkpoint_actual.get(area).?);
                }
                try checker.checkpoints.putNoClobber(replica_checkpoint_op, checkpoint);
            }
            return;
        };

        var mismatch: bool = false;
        for (std.enums.values(CheckpointArea)) |area| {
            const checksum_actual = checkpoint_actual.get(area) orelse continue;
            const checksum_expect = checkpoint_expect.get(area);
            if (checksum_expect != checksum_actual) {
                log.warn("{}: replica_checkpoint: mismatch " ++
                    "area={s} expect={x:0>32} actual={x:0>32}", .{
                    superblock.replica_index.?,
                    @tagName(area),
                    checksum_expect,
                    checksum_actual,
                });

                mismatch = true;
            }
        }
        if (mismatch) return error.StorageMismatch;
    }

    fn checksum_trailer(superblock: *const SuperBlock, trailer: vsr.SuperBlockTrailer) u128 {
        const trailer_size = superblock.working.trailer_size(trailer);
        const trailer_checksum = superblock.working.trailer_checksum(trailer);

        var copy: u8 = 0;
        while (copy < constants.superblock_copies) : (copy += 1) {
            const trailer_start = trailer.zone().start_for_copy(copy);

            assert(trailer_checksum ==
                vsr.checksum(superblock.storage.memory[trailer_start..][0..trailer_size]));
        }

        return trailer_checksum;
    }

    fn checksum_client_replies(superblock: *const SuperBlock) u128 {
        assert(superblock.working.vsr_state.sync_op_max == 0);

        var checksum: u128 = 0;
        for (superblock.client_sessions.entries, 0..) |client_session, slot| {
            if (client_session.session == 0) {
                // Empty slot.
            } else {
                assert(client_session.header.command == .reply);

                if (client_session.header.size == @sizeOf(vsr.Header)) {
                    // ClientReplies won't store this entry.
                } else {
                    checksum ^= vsr.checksum(superblock.storage.area_memory(
                        .{ .client_replies = .{ .slot = slot } },
                    )[0..vsr.sector_ceil(client_session.header.size)]);
                }
            }
        }
        return checksum;
    }

    fn checksum_grid(checker: *StorageChecker, superblock: *const SuperBlock) u128 {
        assert(superblock.working.vsr_state.sync_op_max == 0);

        const free_set_zone = vsr.SuperBlockTrailer.free_set.zone();
        const free_set_offset = vsr.Zone.superblock.offset(free_set_zone.start_for_copy(0));
        const free_set_size = superblock.working.free_set_size;
        const free_set_buffer = superblock.storage.memory[free_set_offset..][0..free_set_size];
        assert(vsr.checksum(free_set_buffer) == superblock.working.free_set_checksum);

        checker.free_set.decode(@alignCast(free_set_buffer));
        defer checker.free_set.reset();

        var stream = vsr.ChecksumStream.init();
        var blocks_missing: usize = 0;
        var blocks_acquired = checker.free_set.blocks.iterator(.{});
        while (blocks_acquired.next()) |block_address_index| {
            const block_address: u64 = block_address_index + 1;
            const block = superblock.storage.grid_block(block_address) orelse {
                log.err("{}: checksum_grid: missing block_address={}", .{
                    superblock.replica_index.?,
                    block_address,
                });

                blocks_missing += 1;
                continue;
            };

            const block_header = schema.header_from_block(block);
            assert(block_header.op == block_address);

            stream.add(block[0..block_header.size]);
            // Extra guard against identical blocks:
            stream.add(std.mem.asBytes(&block_address));

            // Grid block sector padding is zeroed:
            assert(stdx.zeroed(block[block_header.size..vsr.sector_ceil(block_header.size)]));
        }
        assert(blocks_missing == 0);

        return stream.checksum();
    }
};
