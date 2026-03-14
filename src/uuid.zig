const std = @import("std");

/// A UUID v4 stored as a 36-byte string (8-4-4-4-12 hex format).
pub const Uuid = [36]u8;

/// Generate a random UUID v4 by reading from /dev/urandom.
pub fn generate() Uuid {
    var bytes: [16]u8 = undefined;

    // Read 16 random bytes
    var urandom = std.fs.openFileAbsolute("/dev/urandom", .{}) catch {
        // Fallback: use Zig's CSPRNG
        std.crypto.random.bytes(&bytes);
        return formatUuid(bytes);
    };
    defer urandom.close();
    _ = urandom.read(&bytes) catch {
        std.crypto.random.bytes(&bytes);
        return formatUuid(bytes);
    };

    return formatUuid(bytes);
}

fn formatUuid(bytes: [16]u8) Uuid {
    var b = bytes;

    // Set version (4) and variant (RFC 4122)
    b[6] = (b[6] & 0x0F) | 0x40; // version 4
    b[8] = (b[8] & 0x3F) | 0x80; // variant 1

    const hex = "0123456789abcdef";
    var result: Uuid = undefined;
    var pos: usize = 0;

    for (0..16) |i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            result[pos] = '-';
            pos += 1;
        }
        result[pos] = hex[b[i] >> 4];
        result[pos + 1] = hex[b[i] & 0x0F];
        pos += 2;
    }

    return result;
}

/// Compare two UUIDs for equality.
pub fn eql(a: *const Uuid, b: *const Uuid) bool {
    return std.mem.eql(u8, a, b);
}

/// Format a UUID as a slice for printing / socket responses.
pub fn asSlice(id: *const Uuid) []const u8 {
    return id[0..36];
}

test "uuid format" {
    const id = generate();
    // Check format: 8-4-4-4-12
    try std.testing.expect(id[8] == '-');
    try std.testing.expect(id[13] == '-');
    try std.testing.expect(id[18] == '-');
    try std.testing.expect(id[23] == '-');
    try std.testing.expectEqual(@as(usize, 36), id.len);

    // Check version nibble
    try std.testing.expect(id[14] == '4');

    // Check variant nibble (must be 8, 9, a, or b)
    const variant = id[19];
    try std.testing.expect(variant == '8' or variant == '9' or variant == 'a' or variant == 'b');
}

test "uuid uniqueness" {
    const a = generate();
    const b = generate();
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}
