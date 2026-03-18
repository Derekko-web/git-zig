const std = @import("std");
const c = @cImport({
    @cInclude("zlib.h");
});
const stdout = std.fs.File.stdout();

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <command>\n", .{args[0]});
        return;
    }

    const command: []const u8 = args[1];

    if (std.mem.eql(u8, command, "init")) {
        const cwd = std.fs.cwd();
        _ = try cwd.makeDir("./.git");
        _ = try cwd.makeDir("./.git/objects");
        _ = try cwd.makeDir("./.git/refs");
        {
            const head = try cwd.createFile("./.git/HEAD", .{});
            defer head.close();
            _ = try head.write("ref: refs/heads/main\n");
        }
        try stdout.writeAll("Initialized git directory\n");
        return;
    }

    if (std.mem.eql(u8, command, "cat-file")) {
        if (args.len != 4 or !std.mem.eql(u8, args[2], "-p")) {
            return error.InvalidArguments;
        }

        try printBlob(allocator, args[3]);
        return;
    }

    if (std.mem.eql(u8, command, "hash-object")) {
        if (args.len != 4 or !std.mem.eql(u8, args[2], "-w")) {
            return error.InvalidArguments;
        }

        try writeBlobObject(allocator, args[3]);
        return;
    }
}

fn printBlob(allocator: std.mem.Allocator, object_hash: []const u8) !void {
    if (object_hash.len != 40) {
        return error.InvalidObjectHash;
    }

    var object_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const object_path = try std.fmt.bufPrint(
        &object_path_buffer,
        ".git/objects/{s}/{s}",
        .{ object_hash[0..2], object_hash[2..] },
    );

    const cwd = std.fs.cwd();
    const object_file = try cwd.openFile(object_path, .{});
    defer object_file.close();

    const compressed_object = try object_file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(compressed_object);

    var object_reader: std.Io.Reader = .fixed(compressed_object);
    var decompressor: std.compress.flate.Decompress = .init(&object_reader, .zlib, &.{});
    var decompressed_object: std.ArrayList(u8) = .empty;
    defer decompressed_object.deinit(allocator);
    try decompressor.reader.appendRemainingUnlimited(allocator, &decompressed_object);

    const header_end = std.mem.indexOfScalar(u8, decompressed_object.items, 0) orelse {
        return error.InvalidObject;
    };

    const header = decompressed_object.items[0..header_end];
    if (!std.mem.startsWith(u8, header, "blob ")) {
        return error.UnsupportedObjectType;
    }

    const content = decompressed_object.items[header_end + 1 ..];
    const content_size = try std.fmt.parseInt(usize, header["blob ".len..], 10);
    if (content.len != content_size) {
        return error.InvalidObject;
    }

    try stdout.writeAll(content);
}

fn writeBlobObject(allocator: std.mem.Allocator, file_path: []const u8) !void {
    const cwd = std.fs.cwd();
    const input_file = try cwd.openFile(file_path, .{});
    defer input_file.close();

    const file_contents = try input_file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(file_contents);

    const header = try std.fmt.allocPrint(allocator, "blob {d}\x00", .{file_contents.len});
    defer allocator.free(header);

    const blob = try allocator.alloc(u8, header.len + file_contents.len);
    defer allocator.free(blob);
    @memcpy(blob[0..header.len], header);
    @memcpy(blob[header.len..], file_contents);

    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(blob, &digest, .{});
    const object_hash = std.fmt.bytesToHex(digest, .lower);

    const compressed_blob = try compressBlob(allocator, blob);
    defer allocator.free(compressed_blob);

    var object_dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const object_dir_path = try std.fmt.bufPrint(
        &object_dir_buffer,
        ".git/objects/{s}",
        .{object_hash[0..2]},
    );

    cwd.makeDir(object_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var object_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const object_path = try std.fmt.bufPrint(
        &object_path_buffer,
        ".git/objects/{s}/{s}",
        .{ object_hash[0..2], object_hash[2..] },
    );

    const object_file = try cwd.createFile(object_path, .{});
    defer object_file.close();
    try object_file.writeAll(compressed_blob);

    try stdout.writeAll(&object_hash);
    try stdout.writeAll("\n");
}

fn compressBlob(allocator: std.mem.Allocator, blob: []const u8) ![]u8 {
    const max_size: usize = @intCast(c.compressBound(@intCast(blob.len)));
    const compressed = try allocator.alloc(u8, max_size);
    errdefer allocator.free(compressed);

    var compressed_len: c_ulong = @intCast(compressed.len);
    const result = c.compress2(
        compressed.ptr,
        &compressed_len,
        blob.ptr,
        @intCast(blob.len),
        c.Z_BEST_SPEED,
    );

    if (result != c.Z_OK) {
        return error.ZlibCompressFailed;
    }

    return allocator.realloc(compressed, @intCast(compressed_len));
}
