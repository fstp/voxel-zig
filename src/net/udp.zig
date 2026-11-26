const std = @import("std");

/// Minimal UDP peer for the multiplayer spike (2.4).
///
/// The model the plan asks for: client-authoritative player positions (sent
/// unreliably, 10 Hz, latest wins) and server-authoritative world edits (sent
/// with a sequence number so duplicates are dropped). No ENet, no handshake, no
/// retransmission: this is a spike to find out whether the model holds up, not a
/// protocol to ship.
pub const MAX_MESSAGE = 64;

pub const Kind = enum(u8) {
    position = 1,
    edit = 2,
};

pub const Message = union(Kind) {
    /// Player position and yaw, sent every POSITION_INTERVAL.
    position: struct { ids: u8, x: f32, y: f32, z: f32, yaw: f32 },
    /// One block edit with a monotonic sequence number.
    edit: struct { seq: u32, x: i32, y: i32, z: i32, block: u8 },
};

pub const POSITION_INTERVAL: f32 = 0.1;

pub const Peer = struct {
    socket: std.Io.net.Socket,
    port: u16,
    /// Learned from the first packet received, so only one side needs to be told
    /// where the other lives.
    remote: ?std.Io.net.IpAddress = null,

    pub fn init(io: std.Io, port: u16) !Peer {
        var address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = port } };
        const socket = try std.Io.net.IpAddress.bind(&address, io, .{ .mode = .dgram });
        return .{ .socket = socket, .port = port };
    }

    pub fn deinit(self: *Peer, io: std.Io) void {
        self.socket.close(io);
    }

    pub fn setRemote(self: *Peer, address: std.Io.net.IpAddress) void {
        self.remote = address;
    }

    pub fn send(self: *Peer, io: std.Io, message: Message) void {
        const address = self.remote orelse return;
        var buffer: [MAX_MESSAGE]u8 = undefined;
        const length = encode(message, &buffer) orelse return;
        self.socket.send(io, &address, buffer[0..length]) catch {};
    }

    /// Poll, not a blocking wait: the render loop calls this every frame, so a
    /// short timeout is the cheapest way to find out that nothing arrived.
    pub fn receive(self: *Peer, io: std.Io, out: *Message) bool {
        var buffer: [MAX_MESSAGE]u8 = undefined;
        const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .{ .nanoseconds = 200_000 }, .clock = .awake } };
        const incoming = self.socket.receiveTimeout(io, &buffer, timeout) catch return false;
        self.remote = incoming.from;
        return decode(incoming.data, out);
    }
};

pub fn encode(message: Message, out: *[MAX_MESSAGE]u8) ?usize {
    switch (message) {
        .position => |p| {
            out[0] = @intFromEnum(Kind.position);
            out[1] = p.ids;
            putF32(out, 2, p.x);
            putF32(out, 6, p.y);
            putF32(out, 10, p.z);
            putF32(out, 14, p.yaw);
            return 18;
        },
        .edit => |e| {
            out[0] = @intFromEnum(Kind.edit);
            putU32(out, 1, e.seq);
            putI32(out, 5, e.x);
            putI32(out, 9, e.y);
            putI32(out, 13, e.z);
            out[17] = e.block;
            return 18;
        },
    }
}

pub fn decode(bytes: []const u8, out: *Message) bool {
    if (bytes.len < 2) return false;
    const kind: Kind = switch (bytes[0]) {
        @intFromEnum(Kind.position) => .position,
        @intFromEnum(Kind.edit) => .edit,
        else => return false,
    };
    if (bytes.len < 18) return false;
    switch (kind) {
        .position => {
            out.* = .{ .position = .{
                .ids = bytes[1],
                .x = getF32(bytes, 2),
                .y = getF32(bytes, 6),
                .z = getF32(bytes, 10),
                .yaw = getF32(bytes, 14),
            } };
        },
        .edit => {
            out.* = .{ .edit = .{
                .seq = getU32(bytes, 1),
                .x = getI32(bytes, 5),
                .y = getI32(bytes, 9),
                .z = getI32(bytes, 13),
                .block = bytes[17],
            } };
        },
    }
    return true;
}

fn putU32(out: *[MAX_MESSAGE]u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, out[at..][0..4], value, .little);
}
fn putI32(out: *[MAX_MESSAGE]u8, at: usize, value: i32) void {
    putU32(out, at, @bitCast(value));
}
fn putF32(out: *[MAX_MESSAGE]u8, at: usize, value: f32) void {
    putU32(out, at, @bitCast(value));
}
fn getU32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn getI32(bytes: []const u8, at: usize) i32 {
    return @bitCast(getU32(bytes, at));
}
fn getF32(bytes: []const u8, at: usize) f32 {
    return @bitCast(getU32(bytes, at));
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "position messages round-trip" {
    var buffer: [MAX_MESSAGE]u8 = undefined;
    const message = Message{ .position = .{ .ids = 7, .x = 12.5, .y = -3.25, .z = 900.125, .yaw = 1.5 } };
    const length = encode(message, &buffer) orelse return error.EncodeFailed;
    try testing.expectEqual(@as(usize, 18), length);

    var decoded: Message = undefined;
    try testing.expect(decode(buffer[0..length], &decoded));
    try testing.expectEqual(@as(u8, 7), decoded.position.ids);
    try testing.expectEqual(@as(f32, 12.5), decoded.position.x);
    try testing.expectEqual(@as(f32, -3.25), decoded.position.y);
    try testing.expectEqual(@as(f32, 900.125), decoded.position.z);
    try testing.expectEqual(@as(f32, 1.5), decoded.position.yaw);
}

test "edit messages round-trip including negative coordinates" {
    var buffer: [MAX_MESSAGE]u8 = undefined;
    const message = Message{ .edit = .{ .seq = 42, .x = -1024, .y = 63, .z = 77, .block = 3 } };
    const length = encode(message, &buffer) orelse return error.EncodeFailed;
    var decoded: Message = undefined;
    try testing.expect(decode(buffer[0..length], &decoded));
    try testing.expectEqual(@as(u32, 42), decoded.edit.seq);
    try testing.expectEqual(@as(i32, -1024), decoded.edit.x);
    try testing.expectEqual(@as(i32, 63), decoded.edit.y);
    try testing.expectEqual(@as(i32, 77), decoded.edit.z);
    try testing.expectEqual(@as(u8, 3), decoded.edit.block);
}

test "garbage and truncation are rejected rather than misread" {
    var decoded: Message = undefined;
    try testing.expect(!decode(&[_]u8{}, &decoded));
    try testing.expect(!decode(&[_]u8{99}, &decoded));
    try testing.expect(!decode(&[_]u8{ 1, 2, 3 }, &decoded)); // position cut short
    try testing.expect(!decode(&[_]u8{ 2, 0, 0 }, &decoded)); // edit cut short
}
