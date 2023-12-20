const std = @import("std");
const assert = std.debug.assert;

const vsr = @import("vsr");
const constants = vsr.constants;

const tb = vsr.tigerbeetle;
const Account = tb.Account;
const Transfer = tb.Transfer;

const CreateAccountsResult = tb.CreateAccountsResult;
const CreateTransfersResult = tb.CreateTransfersResult;

const stdx = vsr.stdx;
const IO = vsr.io.IO;
const Storage = vsr.storage.Storage;
const MessagePool = vsr.message_pool.MessagePool;
const MessageBus = vsr.message_bus.MessageBusClient;
const StateMachine = vsr.state_machine.StateMachineType(Storage, constants.state_machine_config);
const Header = vsr.Header;
const Client = vsr.Client(StateMachine, MessageBus);

pub const std_options = struct {
    pub const log_level: std.log.Level = .alert;
};

pub const vsr_options = .{
    .config_base = .default,
    .config_log_level = std.log.Level.info,
    .tracer_backend = .none,
    .hash_log_mode = .none,
    .config_aof_record = false,
    .config_aof_recovery = false,
};

pub fn request(
    operation: StateMachine.Operation,
    batch: anytype,
    on_reply: *const fn (
        vsr_request: *Client.Request,
        operation: StateMachine.Operation,
        results: []const u8,
    ) void,
) !void {
    const allocator = std.heap.page_allocator;
    const client_id = std.crypto.random.int(u128);
    const cluster_id: u128 = 0;
    var addresses = [_]std.net.Address{try std.net.Address.parseIp4("127.0.0.1", constants.port)};

    var io = try IO.init(32, 0);
    defer io.deinit();

    var message_pool = try MessagePool.init(allocator, .client);
    defer message_pool.deinit(allocator);

    var client = try Client.init(
        allocator,
        client_id,
        cluster_id,
        @as(u8, @intCast(addresses.len)),
        &message_pool,
        .{
            .configuration = &addresses,
            .io = &io,
        },
    );
    defer client.deinit(allocator);

    var vsr_request: Client.Request = undefined;
    client.submit(
        on_reply,
        &vsr_request,
        operation,
        std.mem.asBytes(&batch),
    );

    while (client.request_queue.count > 0) {
        client.tick();
        try io.run_for_ns(constants.tick_ms * std.time.ns_per_ms);
    }
}

pub fn on_create_accounts(
    vsr_request: *Client.Request,
    operation: StateMachine.Operation,
    results: []const u8,
) void {
    _ = vsr_request;
    _ = operation;

    print_results(CreateAccountsResult, results);
}

pub fn on_lookup_accounts(
    vsr_request: *Client.Request,
    operation: StateMachine.Operation,
    results: []const u8,
) void {
    _ = vsr_request;
    _ = operation;

    print_results(Account, results);
}

pub fn on_lookup_transfers(
    vsr_request: *Client.Request,
    operation: StateMachine.Operation,
    results: []const u8,
) void {
    _ = vsr_request;
    _ = operation;

    print_results(Transfer, results);
}

pub fn on_create_transfers(
    vsr_request: *Client.Request,
    operation: StateMachine.Operation,
    results: []const u8,
) void {
    _ = vsr_request;
    _ = operation;

    print_results(CreateTransfersResult, results);
}

fn print_results(comptime Results: type, results: []const u8) void {
    const slice = std.mem.bytesAsSlice(Results, results);
    for (slice) |result| {
        std.debug.print("{}\n", .{result});
    }
    if (slice.len == 0) std.debug.print("OK\n", .{});
}
