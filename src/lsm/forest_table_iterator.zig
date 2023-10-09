//! Iterate over every TableInfo in the forest.
//!
//! The underlying level iterator is stable across ManifestLevel mutation and
//! Forest.reset()/Forest.open(). (This is necessary for the scrubber, which is long-running).
//!
//! Stability invariants:
//! - Tables inserted after the iterator starts *may* be iterated.
//! - Tables inserted before the iterator starts *will* be iterated (unless they are removed).
//!
//! This iterator is conceptually simple, but it is a complex implementation due to the
//! metaprogramming necessary to generalize over the different concrete Tree types, and the
//! stability requirements.
//!
//! Pseudocode for this iterator:
//!
//!   for level in 0→lsm_levels:
//!     for tree in forest.trees:
//!       for table in tree.manifest.levels[level]:
//!         yield table
//!
//! The iterator must traverse from the top (level 0) to the bottom of each tree to avoid skipping
//! tables that are compacted with move-table.
const std = @import("std");
const assert = std.debug.assert;

const stdx = @import("../stdx.zig");
const constants = @import("../constants.zig");
const TableInfo = @import("./schema.zig").Manifest.TableInfo;

pub fn ForestTableIteratorType(comptime Forest: type) type {
    // struct { (Tree.name) → TreeTableIteratorType(Tree) }
    const TreeTableIterators = iterator: {
        const StructField = std.builtin.Type.StructField;

        var fields: []const StructField = &[_]StructField{};
        for (Forest.tree_infos) |tree_info| {
            fields = fields ++ &[_]StructField{.{
                .name = tree_info.tree_name,
                .type = TreeTableIteratorType(tree_info.Tree),
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(TreeTableIteratorType(tree_info.Tree)),
            }};
        }

        break :iterator @Type(.{ .Struct = .{
            .layout = .Auto,
            .fields = fields,
            .decls = &.{},
            .is_tuple = false,
        } });
    };
    assert(std.meta.fields(TreeTableIterators).len > 0);

    return struct {
        const ForestTableIterator = @This();

        /// The level we are currently pulling tables from.
        level: u8 = 0,
        /// The tree we are currently pulling tables from.
        tree_id: u16 = Forest.tree_id_range.min,

        trees: TreeTableIterators = default: {
            var iterators: TreeTableIterators = undefined;
            for (std.meta.fields(TreeTableIterators)) |field| @field(iterators, field.name) = .{};
            break :default iterators;
        },

        pub fn next(iterator: *ForestTableIterator, forest: *Forest) ?TableInfo {
            while (iterator.level < constants.lsm_levels) : (iterator.level += 1) {
                for (iterator.tree_id..Forest.tree_id_range.max + 1) |tree_id_runtime| {
                    iterator.tree_id = @intCast(tree_id_runtime);

                    switch (tree_id_runtime) {
                        inline Forest.tree_id_range.min...Forest.tree_id_range.max => |tree_id| {
                            const tree_info = Forest.tree_infos[tree_id - Forest.tree_id_range.min];
                            assert(tree_info.tree_id == tree_id);

                            if (iterator.next_from_tree(
                                tree_info.tree_name,
                                tree_info.Tree,
                                forest.tree_for_id(tree_id),
                            )) |block| {
                                return block;
                            }
                        },
                        else => unreachable,
                    }
                }
                assert(iterator.tree_id == Forest.tree_id_range.max);

                iterator.tree_id = Forest.tree_id_range.min;
            }
            assert(iterator.tree_id == Forest.tree_id_range.min);

            return null;
        }

        fn next_from_tree(
            iterator: *ForestTableIterator,
            comptime iterator_field: []const u8,
            comptime Tree: type,
            tree: *const Tree,
        ) ?TableInfo {
            const tree_iterator = &@field(iterator.trees, iterator_field);
            if (tree_iterator.next(tree, iterator.level)) |table| {
                return table.encode(tree.config.id);
            } else {
                return null;
            }
        }
    };
}

/// Iterate over every table in a tree (i.e. every table in every ManifestLevel).
/// The iterator is stable across ManifestLevel mutation and Manifest.reset()/Manifest.open().
fn TreeTableIteratorType(comptime Tree: type) type {
    return struct {
        const TreeTableIterator = @This();

        position: ?struct {
            level: u8,
            /// Corresponds to `ManifestLevel.generation`.
            /// Used to detect when a ManifestLevel is mutated.
            generation: u32,
            /// Used to recover the position in the manifest level after ManifestLevel mutations.
            previous: Tree.Manifest.TreeTableInfo,
            /// Only valid for the same level+generation that created it.
            iterator: Tree.Manifest.Level.Tables.Iterator,
        } = null,

        fn next(
            iterator: *TreeTableIterator,
            tree: *const Tree,
            level: u8,
        ) ?*const Tree.Manifest.TreeTableInfo {
            assert(tree.manifest.manifest_log.?.opened);
            assert(level < constants.lsm_levels);

            if (iterator.position) |position| {
                assert(position.level < constants.lsm_levels);

                if (position.level != level) {
                    assert(position.level + 1 == level);

                    iterator.position = null;
                }
            }

            const manifest_level: *const Tree.Manifest.Level = &tree.manifest.levels[level];

            var table_iterator = tables: {
                if (iterator.position) |position| {
                    if (position.generation == manifest_level.generation) {
                        break :tables position.iterator;
                    } else {
                        // The ManifestLevel was mutated since the last iteration, so our
                        // position's cursor/ManifestLevel.Iterator is invalid.
                        break :tables manifest_level.tables.iterator_from_cursor(
                            manifest_level.tables.search(.{
                                .key_max = position.previous.key_max,
                                // +1 to skip past the previous table.
                                // (The tables are ordered by (key_max,snapshot_min).)
                                .snapshot_min = position.previous.snapshot_min + 1,
                            }),
                            .ascending,
                        );
                    }
                } else {
                    break :tables manifest_level.tables.iterator_from_cursor(
                        manifest_level.tables.first(),
                        .ascending,
                    );
                }
            };

            const table = table_iterator.next() orelse return null;

            if (iterator.position) |position| {
                const table_order =
                    Tree.Table.compare_keys(position.previous.key_max, table.key_max);
                assert(table_order.compare(.lte));

                if (table_order == .eq) {
                    assert(position.previous.snapshot_min < table.snapshot_min);
                }
            }

            iterator.position = .{
                .level = level,
                .generation = manifest_level.generation,
                .previous = table.*,
                .iterator = table_iterator,
            };

            return table;
        }
    };
}

test "ForestTableIterator: refAllDecls" {
    const Storage = @import("../testing/storage.zig").Storage;
    const StateMachineType = @import("../testing/state_machine.zig").StateMachineType;
    const StateMachine = StateMachineType(Storage, constants.state_machine_config);

    std.testing.refAllDecls(ForestTableIteratorType(StateMachine.Forest));
}
