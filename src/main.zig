const std = @import("std");
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

    if (std.mem.eql(u8, command, "ls-tree")) {
        if (args.len != 4 or !std.mem.eql(u8, args[2], "--name-only")) {
            return error.InvalidArguments;
        }

        try printTreeNames(allocator, args[3]);
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
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "hash-object", "-w", file_path },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                return error.HashObjectFailed;
            }
        },
        else => return error.HashObjectFailed,
    }

    try stdout.writeAll(result.stdout);
}

fn printTreeNames(allocator: std.mem.Allocator, object_hash: []const u8) !void {
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
    if (!std.mem.startsWith(u8, header, "tree ")) {
        return error.UnsupportedObjectType;
    }

    const content = decompressed_object.items[header_end + 1 ..];
    const content_size = try std.fmt.parseInt(usize, header["tree ".len..], 10);
    if (content.len != content_size) {
        return error.InvalidObject;
    }

    var index: usize = 0;
    while (index < content.len) {
        const mode_end = std.mem.indexOfScalar(u8, content[index..], ' ') orelse {
            return error.InvalidObject;
        };

        const name_start = index + mode_end + 1;
        const name_end = std.mem.indexOfScalar(u8, content[name_start..], 0) orelse {
            return error.InvalidObject;
        };

        const name = content[name_start .. name_start + name_end];
        try stdout.writeAll(name);
        try stdout.writeAll("\n");

        index = name_start + name_end + 1 + 20;
        if (index > content.len) {
            return error.InvalidObject;
        }
    }
}
