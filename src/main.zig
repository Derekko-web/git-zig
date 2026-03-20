const std = @import("std");

const Allocator = std.mem.Allocator;
const stdout = std.fs.File.stdout();

const ObjectType = enum {
    commit,
    tree,
    blob,
    tag,
    ofs_delta,
    ref_delta,
};

const LooseObject = struct {
    raw: []u8,
    object_type: ObjectType,
    body: []u8,

    fn deinit(self: *LooseObject, allocator: Allocator) void {
        allocator.free(self.raw);
        self.* = undefined;
    }
};

const AdvertisedRef = struct {
    name: []u8,
    object_id: [20]u8,
};

const RefDiscovery = struct {
    refs: std.ArrayList(AdvertisedRef),
    head_oid: [20]u8,
    head_ref: ?[]u8,

    fn deinit(self: *RefDiscovery, allocator: Allocator) void {
        for (self.refs.items) |ref| {
            allocator.free(ref.name);
        }
        self.refs.deinit(allocator);
        if (self.head_ref) |head_ref| allocator.free(head_ref);
        self.* = undefined;
    }
};

const TreeEntry = struct {
    name: []u8,
    kind: std.fs.Dir.Entry.Kind,
};

const ParsedTreeEntry = struct {
    mode: []const u8,
    name: []const u8,
    object_id: [20]u8,
};

const PackHeader = struct {
    object_type: ObjectType,
    size: usize,
};

const PendingDelta = struct {
    base_oid: [20]u8,
    delta_data: []u8,
};

const Repository = struct {
    allocator: Allocator,
    root_dir: std.fs.Dir,
    git_dir: std.fs.Dir,

    fn openCurrent(allocator: Allocator) !Repository {
        var root_dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
        errdefer root_dir.close();

        var git_dir = try root_dir.openDir(".git", .{});
        errdefer git_dir.close();

        return .{
            .allocator = allocator,
            .root_dir = root_dir,
            .git_dir = git_dir,
        };
    }

    fn createCloneTarget(allocator: Allocator, directory_name: []const u8) !Repository {
        try std.fs.cwd().makeDir(directory_name);
        errdefer std.fs.cwd().deleteTree(directory_name) catch {};

        var root_dir = try std.fs.cwd().openDir(directory_name, .{ .iterate = true });
        errdefer root_dir.close();

        try initializeRepositoryLayout(root_dir, null);

        var git_dir = try root_dir.openDir(".git", .{});
        errdefer git_dir.close();

        return .{
            .allocator = allocator,
            .root_dir = root_dir,
            .git_dir = git_dir,
        };
    }

    fn deinit(self: *Repository) void {
        self.git_dir.close();
        self.root_dir.close();
        self.* = undefined;
    }

    fn writeObject(self: *Repository, object_type: ObjectType, body: []const u8) ![20]u8 {
        if (object_type == .ofs_delta or object_type == .ref_delta) {
            return error.InvalidLooseObjectType;
        }

        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(self.allocator);

        try raw.writer(self.allocator).print("{s} {d}", .{ objectTypeName(object_type), body.len });
        try raw.append(self.allocator, 0);
        try raw.appendSlice(self.allocator, body);

        var object_id: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(raw.items, &object_id, .{});

        const compressed = try zlibCompressStore(self.allocator, raw.items);
        defer self.allocator.free(compressed);

        const object_hex = std.fmt.bytesToHex(object_id, .lower);

        var object_dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const object_dir_path = try std.fmt.bufPrint(&object_dir_path_buf, "objects/{s}", .{object_hex[0..2]});
        try self.git_dir.makePath(object_dir_path);

        var object_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const object_path = try std.fmt.bufPrint(&object_path_buf, "objects/{s}/{s}", .{ object_hex[0..2], object_hex[2..] });

        const object_file = self.git_dir.createFile(object_path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => return object_id,
            else => return err,
        };
        defer object_file.close();

        try object_file.writeAll(compressed);
        return object_id;
    }

    fn readObjectHex(self: *Repository, object_hash: []const u8) !LooseObject {
        if (object_hash.len != 40) return error.InvalidObjectHash;

        var object_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const object_path = try std.fmt.bufPrint(
            &object_path_buffer,
            "objects/{s}/{s}",
            .{ object_hash[0..2], object_hash[2..] },
        );

        const object_file = try self.git_dir.openFile(object_path, .{});
        defer object_file.close();

        const compressed_object = try object_file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
        defer self.allocator.free(compressed_object);

        const raw = try decompressZlib(self.allocator, compressed_object);
        errdefer self.allocator.free(raw);

        const header_end = std.mem.indexOfScalar(u8, raw, 0) orelse return error.InvalidObject;
        const header = raw[0..header_end];
        const space_index = std.mem.indexOfScalar(u8, header, ' ') orelse return error.InvalidObject;

        const object_type = try parseObjectTypeName(header[0..space_index]);
        const body = raw[header_end + 1 ..];
        const expected_len = try std.fmt.parseInt(usize, header[space_index + 1 ..], 10);
        if (body.len != expected_len) return error.InvalidObject;

        return .{
            .raw = raw,
            .object_type = object_type,
            .body = body,
        };
    }

    fn readObject(self: *Repository, object_id: [20]u8) !LooseObject {
        const object_hex = std.fmt.bytesToHex(object_id, .lower);
        return self.readObjectHex(object_hex[0..]);
    }

    fn setHead(self: *Repository, head_oid: [20]u8, head_ref: ?[]const u8) !void {
        const object_hex = std.fmt.bytesToHex(head_oid, .lower);

        if (head_ref) |ref_name| {
            try ensureParentPath(self.git_dir, ref_name);

            const ref_file = try self.git_dir.createFile(ref_name, .{ .truncate = true });
            defer ref_file.close();
            try ref_file.writeAll(object_hex[0..]);
            try ref_file.writeAll("\n");

            const head_file = try self.git_dir.createFile("HEAD", .{ .truncate = true });
            defer head_file.close();

            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const contents = try std.fmt.bufPrint(&buffer, "ref: {s}\n", .{ref_name});
            try head_file.writeAll(contents);
            return;
        }

        const head_file = try self.git_dir.createFile("HEAD", .{ .truncate = true });
        defer head_file.close();
        try head_file.writeAll(object_hex[0..]);
        try head_file.writeAll("\n");
    }

    fn writeBlobObject(self: *Repository, file_path: []const u8) !void {
        const file = try self.root_dir.openFile(file_path, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
        defer self.allocator.free(contents);

        const object_id = try self.writeObject(.blob, contents);
        try writeObjectIdLine(object_id);
    }

    fn printBlob(self: *Repository, object_hash: []const u8) !void {
        var object = try self.readObjectHex(object_hash);
        defer object.deinit(self.allocator);

        if (object.object_type != .blob) return error.UnsupportedObjectType;
        try stdout.writeAll(object.body);
    }

    fn printTreeNames(self: *Repository, object_hash: []const u8) !void {
        var object = try self.readObjectHex(object_hash);
        defer object.deinit(self.allocator);

        if (object.object_type != .tree) return error.UnsupportedObjectType;

        var index: usize = 0;
        while (try nextTreeEntry(object.body, &index)) |entry| {
            _ = entry.mode;
            try stdout.writeAll(entry.name);
            try stdout.writeAll("\n");
        }
    }

    fn writeTreeObject(self: *Repository) !void {
        const object_id = try self.writeTreeRecursive(self.root_dir);
        try writeObjectIdLine(object_id);
    }

    fn writeTreeRecursive(self: *Repository, dir: std.fs.Dir) ![20]u8 {
        var iterator = dir.iterate();
        var entries: std.ArrayList(TreeEntry) = .empty;
        defer {
            for (entries.items) |entry| self.allocator.free(entry.name);
            entries.deinit(self.allocator);
        }

        while (try iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.name, ".git")) continue;
            try entries.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, entry.name),
                .kind = entry.kind,
            });
        }

        std.sort.insertion(TreeEntry, entries.items, {}, treeEntryLessThan);

        var tree_contents: std.ArrayList(u8) = .empty;
        defer tree_contents.deinit(self.allocator);

        for (entries.items) |entry| {
            switch (entry.kind) {
                .directory => {
                    var child_dir = try dir.openDir(entry.name, .{ .iterate = true });
                    defer child_dir.close();

                    const child_oid = try self.writeTreeRecursive(child_dir);
                    try treeContentsAppendEntry(&tree_contents, self.allocator, "40000", entry.name, child_oid);
                },
                .file => {
                    const file = try dir.openFile(entry.name, .{});
                    defer file.close();

                    const contents = try file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
                    defer self.allocator.free(contents);

                    const stat = try file.stat();
                    const mode = if ((stat.mode & 0o111) != 0) "100755" else "100644";
                    const blob_oid = try self.writeObject(.blob, contents);
                    try treeContentsAppendEntry(&tree_contents, self.allocator, mode, entry.name, blob_oid);
                },
                .sym_link => {
                    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
                    const target = try dir.readLink(entry.name, &link_buffer);
                    const blob_oid = try self.writeObject(.blob, target);
                    try treeContentsAppendEntry(&tree_contents, self.allocator, "120000", entry.name, blob_oid);
                },
                else => return error.UnsupportedFileType,
            }
        }

        return self.writeObject(.tree, tree_contents.items);
    }

    fn writeCommitObject(self: *Repository, tree_sha: []const u8, parent_sha: []const u8, message: []const u8) !void {
        _ = try parseObjectIdHex(tree_sha);
        _ = try parseObjectIdHex(parent_sha);

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);

        try body.writer(self.allocator).print("tree {s}\n", .{tree_sha});
        try body.writer(self.allocator).print("parent {s}\n", .{parent_sha});
        try body.appendSlice(self.allocator, "author John Doe <john@example.com> 1234567890 +0000\n");
        try body.appendSlice(self.allocator, "committer John Doe <john@example.com> 1234567890 +0000\n\n");
        try body.appendSlice(self.allocator, message);
        if (message.len == 0 or message[message.len - 1] != '\n') {
            try body.append(self.allocator, '\n');
        }

        const object_id = try self.writeObject(.commit, body.items);
        try writeObjectIdLine(object_id);
    }

    fn unpackPack(self: *Repository, pack_bytes: []const u8) !void {
        if (pack_bytes.len < 32) return error.InvalidPackFile;
        if (!std.mem.eql(u8, pack_bytes[0..4], "PACK")) return error.InvalidPackFile;

        const version = std.mem.readInt(u32, pack_bytes[4..8], .big);
        if (version != 2 and version != 3) return error.UnsupportedPackVersion;

        const object_count = std.mem.readInt(u32, pack_bytes[8..12], .big);

        var expected_pack_hash: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(pack_bytes[0 .. pack_bytes.len - 20], &expected_pack_hash, .{});
        if (!std.mem.eql(u8, expected_pack_hash[0..], pack_bytes[pack_bytes.len - 20 ..])) {
            return error.InvalidPackChecksum;
        }

        var offset: usize = 12;
        var pending_deltas: std.ArrayList(PendingDelta) = .empty;
        defer {
            for (pending_deltas.items) |pending| self.allocator.free(pending.delta_data);
            pending_deltas.deinit(self.allocator);
        }

        var object_index: u32 = 0;
        while (object_index < object_count) : (object_index += 1) {
            const pack_header = try readPackHeader(pack_bytes, &offset);
            switch (pack_header.object_type) {
                .commit, .tree, .blob, .tag => {
                    const inflated = try decompressPackObject(self.allocator, pack_bytes[offset..]);
                    defer self.allocator.free(inflated.data);

                    if (inflated.data.len != pack_header.size) return error.InvalidPackObject;
                    offset += inflated.consumed;

                    _ = try self.writeObject(pack_header.object_type, inflated.data);
                },
                .ref_delta => {
                    if (offset + 20 > pack_bytes.len) return error.InvalidPackObject;

                    var base_oid: [20]u8 = undefined;
                    @memcpy(base_oid[0..], pack_bytes[offset .. offset + 20]);
                    offset += 20;

                    const inflated = try decompressPackObject(self.allocator, pack_bytes[offset..]);
                    offset += inflated.consumed;

                    if (inflated.data.len != pack_header.size) {
                        self.allocator.free(inflated.data);
                        return error.InvalidPackObject;
                    }

                    try pending_deltas.append(self.allocator, .{
                        .base_oid = base_oid,
                        .delta_data = inflated.data,
                    });
                },
                .ofs_delta => return error.UnsupportedPackObjectType,
            }
        }

        if (offset + 20 != pack_bytes.len) return error.InvalidPackFile;

        while (pending_deltas.items.len > 0) {
            var resolved_any = false;
            var index: usize = 0;

            while (index < pending_deltas.items.len) {
                var base_object = self.readObject(pending_deltas.items[index].base_oid) catch |err| switch (err) {
                    error.FileNotFound => {
                        index += 1;
                        continue;
                    },
                    else => return err,
                };
                defer base_object.deinit(self.allocator);

                const resolved_body = try applyDelta(self.allocator, base_object.body, pending_deltas.items[index].delta_data);
                defer self.allocator.free(resolved_body);

                _ = try self.writeObject(base_object.object_type, resolved_body);

                self.allocator.free(pending_deltas.items[index].delta_data);
                _ = pending_deltas.swapRemove(index);
                resolved_any = true;
            }

            if (!resolved_any) return error.UnresolvedDeltaBase;
        }
    }

    fn checkoutCommit(self: *Repository, commit_oid: [20]u8) !void {
        var commit_object = try self.readObject(commit_oid);
        defer commit_object.deinit(self.allocator);

        if (commit_object.object_type != .commit) return error.UnsupportedObjectType;
        const tree_oid = try parseCommitTree(commit_object.body);

        try self.checkoutTree(self.root_dir, tree_oid);
    }

    fn checkoutTree(self: *Repository, dir: std.fs.Dir, tree_oid: [20]u8) !void {
        var tree_object = try self.readObject(tree_oid);
        defer tree_object.deinit(self.allocator);

        if (tree_object.object_type != .tree) return error.UnsupportedObjectType;

        var index: usize = 0;
        while (try nextTreeEntry(tree_object.body, &index)) |entry| {
            if (std.mem.eql(u8, entry.mode, "40000")) {
                dir.makeDir(entry.name) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };

                var child_dir = try dir.openDir(entry.name, .{ .iterate = true });
                defer child_dir.close();
                try self.checkoutTree(child_dir, entry.object_id);
                continue;
            }

            var child_object = try self.readObject(entry.object_id);
            defer child_object.deinit(self.allocator);

            switch (child_object.object_type) {
                .blob => {},
                else => return error.UnsupportedObjectType,
            }

            if (std.mem.eql(u8, entry.mode, "120000")) {
                try dir.symLink(child_object.body, entry.name, .{ .is_directory = false });
                continue;
            }

            const file = try dir.createFile(entry.name, .{ .truncate = true });
            defer file.close();
            try file.writeAll(child_object.body);

            if (std.mem.eql(u8, entry.mode, "100755")) {
                try file.chmod(0o755);
            } else if (std.mem.eql(u8, entry.mode, "100644")) {
                try file.chmod(0o644);
            } else {
                return error.UnsupportedTreeEntryMode;
            }
        }
    }
};

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

    const command = args[1];

    if (std.mem.eql(u8, command, "init")) {
        var root_dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
        defer root_dir.close();

        try initializeRepositoryLayout(root_dir, "refs/heads/main");
        try stdout.writeAll("Initialized git directory\n");
        return;
    }

    if (std.mem.eql(u8, command, "cat-file")) {
        if (args.len != 4 or !std.mem.eql(u8, args[2], "-p")) return error.InvalidArguments;

        var repo = try Repository.openCurrent(allocator);
        defer repo.deinit();
        try repo.printBlob(args[3]);
        return;
    }

    if (std.mem.eql(u8, command, "hash-object")) {
        if (args.len != 4 or !std.mem.eql(u8, args[2], "-w")) return error.InvalidArguments;

        var repo = try Repository.openCurrent(allocator);
        defer repo.deinit();
        try repo.writeBlobObject(args[3]);
        return;
    }

    if (std.mem.eql(u8, command, "ls-tree")) {
        if (args.len != 4 or !std.mem.eql(u8, args[2], "--name-only")) return error.InvalidArguments;

        var repo = try Repository.openCurrent(allocator);
        defer repo.deinit();
        try repo.printTreeNames(args[3]);
        return;
    }

    if (std.mem.eql(u8, command, "write-tree")) {
        if (args.len != 2) return error.InvalidArguments;

        var repo = try Repository.openCurrent(allocator);
        defer repo.deinit();
        try repo.writeTreeObject();
        return;
    }

    if (std.mem.eql(u8, command, "commit-tree")) {
        if (args.len != 7 or
            !std.mem.eql(u8, args[3], "-p") or
            !std.mem.eql(u8, args[5], "-m"))
        {
            return error.InvalidArguments;
        }

        var repo = try Repository.openCurrent(allocator);
        defer repo.deinit();
        try repo.writeCommitObject(args[2], args[4], args[6]);
        return;
    }

    if (std.mem.eql(u8, command, "clone")) {
        if (args.len != 4) return error.InvalidArguments;
        try cloneRepository(allocator, args[2], args[3]);
        return;
    }

    return error.UnknownCommand;
}

fn initializeRepositoryLayout(root_dir: std.fs.Dir, head_ref: ?[]const u8) !void {
    try root_dir.makePath(".git/objects");
    try root_dir.makePath(".git/refs/heads");

    if (head_ref) |ref_name| {
        const head_file = try root_dir.createFile(".git/HEAD", .{ .truncate = true });
        defer head_file.close();

        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const contents = try std.fmt.bufPrint(&buffer, "ref: {s}\n", .{ref_name});
        try head_file.writeAll(contents);
    }
}

fn cloneRepository(allocator: Allocator, repository_url: []const u8, directory_name: []const u8) !void {
    var repo = try Repository.createCloneTarget(allocator, directory_name);
    defer repo.deinit();

    var refs = try discoverReferences(allocator, repository_url);
    defer refs.deinit(allocator);

    const pack_bytes = try fetchPack(allocator, repository_url, refs.head_oid);
    defer allocator.free(pack_bytes);

    try repo.unpackPack(pack_bytes);

    const head_ref = refs.head_ref orelse deriveHeadRef(refs.refs.items, refs.head_oid);
    try repo.setHead(refs.head_oid, head_ref);
    try repo.checkoutCommit(refs.head_oid);
}

fn discoverReferences(allocator: Allocator, repository_url: []const u8) !RefDiscovery {
    const info_refs_url = try buildServiceUrl(allocator, repository_url, "info/refs?service=git-upload-pack");
    defer allocator.free(info_refs_url);

    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/x-git-upload-pack-advertisement" },
    };

    const body = try fetchHttpBytes(allocator, info_refs_url, null, &headers);
    defer allocator.free(body);

    var refs: std.ArrayList(AdvertisedRef) = .empty;
    errdefer {
        for (refs.items) |ref| allocator.free(ref.name);
        refs.deinit(allocator);
    }

    var offset: usize = 0;

    const service_line = (try nextPktLine(body, &offset)) orelse return error.InvalidAdvertisement;
    const trimmed_service_line = trimPacketLine(service_line);
    if (!std.mem.eql(u8, trimmed_service_line, "# service=git-upload-pack")) {
        return error.InvalidAdvertisement;
    }

    if ((try nextPktLine(body, &offset)) != null) return error.InvalidAdvertisement;

    var head_oid: ?[20]u8 = null;
    var head_ref: ?[]u8 = null;
    var is_first_ref = true;

    while (try nextPktLine(body, &offset)) |payload| {
        const line = trimPacketLine(payload);
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "ERR ")) return error.RemoteRejected;
        if (std.mem.eql(u8, line, "version 1")) continue;

        var ref_line = line;
        if (is_first_ref) {
            if (std.mem.indexOfScalar(u8, line, 0)) |nul_index| {
                ref_line = line[0..nul_index];

                var capabilities = std.mem.splitScalar(u8, line[nul_index + 1 ..], ' ');
                while (capabilities.next()) |capability| {
                    if (std.mem.startsWith(u8, capability, "symref=HEAD:")) {
                        head_ref = try allocator.dupe(u8, capability["symref=HEAD:".len..]);
                    } else if (std.mem.startsWith(u8, capability, "object-format=") and
                        !std.mem.eql(u8, capability["object-format=".len..], "sha1"))
                    {
                        return error.UnsupportedObjectFormat;
                    }
                }
            }
            is_first_ref = false;
        }

        const space_index = std.mem.indexOfScalar(u8, ref_line, ' ') orelse return error.InvalidAdvertisement;
        const oid = try parseObjectIdHex(ref_line[0..space_index]);
        const ref_name = ref_line[space_index + 1 ..];

        if (std.mem.eql(u8, ref_name, "capabilities^{}")) return error.EmptyRemoteRepository;

        try refs.append(allocator, .{
            .name = try allocator.dupe(u8, ref_name),
            .object_id = oid,
        });

        if (std.mem.eql(u8, ref_name, "HEAD")) {
            head_oid = oid;
        }
    }

    if (head_oid == null and head_ref != null) {
        for (refs.items) |ref| {
            if (std.mem.eql(u8, ref.name, head_ref.?)) {
                head_oid = ref.object_id;
                break;
            }
        }
    }

    return .{
        .refs = refs,
        .head_oid = head_oid orelse return error.MissingHeadReference,
        .head_ref = head_ref,
    };
}

fn fetchPack(allocator: Allocator, repository_url: []const u8, head_oid: [20]u8) ![]u8 {
    const upload_pack_url = try buildServiceUrl(allocator, repository_url, "git-upload-pack");
    defer allocator.free(upload_pack_url);

    const want_hex = std.fmt.bytesToHex(head_oid, .lower);

    var request_body: std.ArrayList(u8) = .empty;
    defer request_body.deinit(allocator);

    var want_line_buffer: [80]u8 = undefined;
    const want_line = try std.fmt.bufPrint(&want_line_buffer, "want {s} no-progress\n", .{want_hex[0..]});
    try appendPktLine(&request_body, allocator, want_line);
    try request_body.appendSlice(allocator, "0000");
    try appendPktLine(&request_body, allocator, "done\n");

    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/x-git-upload-pack-result" },
        .{ .name = "Content-Type", .value = "application/x-git-upload-pack-request" },
    };

    const response = try fetchHttpBytes(allocator, upload_pack_url, request_body.items, &headers);
    defer allocator.free(response);

    var offset: usize = 0;
    const status_line = (try nextPktLine(response, &offset)) orelse return error.InvalidUploadPackResponse;
    const trimmed_status_line = trimPacketLine(status_line);
    if (std.mem.startsWith(u8, trimmed_status_line, "ERR ")) return error.RemoteRejected;
    if (!std.mem.eql(u8, trimmed_status_line, "NAK") and !std.mem.startsWith(u8, trimmed_status_line, "ACK ")) {
        return error.InvalidUploadPackResponse;
    }

    return try allocator.dupe(u8, response[offset..]);
}

fn fetchHttpBytes(
    allocator: Allocator,
    url: []const u8,
    payload: ?[]const u8,
    headers: []const std.http.Header,
) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(allocator);
    errdefer body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .payload = payload,
        .extra_headers = headers,
        .response_writer = &body.writer,
    });

    if (result.status != .ok) return error.HttpRequestFailed;
    return try body.toOwnedSlice();
}

fn buildServiceUrl(allocator: Allocator, repository_url: []const u8, suffix: []const u8) ![]u8 {
    const trimmed_url = std.mem.trimRight(u8, repository_url, "/");
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimmed_url, suffix });
}

fn nextPktLine(data: []const u8, offset: *usize) !?[]const u8 {
    if (offset.* + 4 > data.len) return error.InvalidPktLine;

    const packet_len = try std.fmt.parseInt(u16, data[offset.* .. offset.* + 4], 16);
    offset.* += 4;

    if (packet_len == 0) return null;
    if (packet_len < 4) return error.InvalidPktLine;

    const payload_len = packet_len - 4;
    if (offset.* + payload_len > data.len) return error.InvalidPktLine;

    const payload = data[offset.* .. offset.* + payload_len];
    offset.* += payload_len;
    return payload;
}

fn appendPktLine(buffer: *std.ArrayList(u8), allocator: Allocator, payload: []const u8) !void {
    var header: [4]u8 = undefined;
    _ = try std.fmt.bufPrint(&header, "{x:0>4}", .{@as(u16, @intCast(payload.len + 4))});
    try buffer.appendSlice(allocator, &header);
    try buffer.appendSlice(allocator, payload);
}

fn trimPacketLine(line: []const u8) []const u8 {
    return std.mem.trimRight(u8, line, "\n");
}

fn objectTypeName(object_type: ObjectType) []const u8 {
    return switch (object_type) {
        .commit => "commit",
        .tree => "tree",
        .blob => "blob",
        .tag => "tag",
        .ofs_delta, .ref_delta => unreachable,
    };
}

fn parseObjectTypeName(name: []const u8) !ObjectType {
    if (std.mem.eql(u8, name, "commit")) return .commit;
    if (std.mem.eql(u8, name, "tree")) return .tree;
    if (std.mem.eql(u8, name, "blob")) return .blob;
    if (std.mem.eql(u8, name, "tag")) return .tag;
    return error.UnsupportedObjectType;
}

fn parseObjectIdHex(object_hash: []const u8) ![20]u8 {
    if (object_hash.len != 40) return error.InvalidObjectHash;
    var object_id: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(object_id[0..], object_hash);
    return object_id;
}

fn writeObjectIdLine(object_id: [20]u8) !void {
    const object_hex = std.fmt.bytesToHex(object_id, .lower);
    try stdout.writeAll(object_hex[0..]);
    try stdout.writeAll("\n");
}

fn zlibCompressStore(allocator: Allocator, input: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    try output.appendSlice(allocator, &.{ 0x78, 0x01 });

    var adler = std.hash.Adler32{};
    adler.update(input);

    var offset: usize = 0;
    while (true) {
        const remaining = input.len - offset;
        const chunk_len = @min(remaining, 0xffff);
        const is_last = offset + chunk_len == input.len;

        try output.append(allocator, if (is_last) 0x01 else 0x00);

        var chunk_header: [4]u8 = undefined;
        const len_u16: u16 = @intCast(chunk_len);
        std.mem.writeInt(u16, chunk_header[0..2], len_u16, .little);
        std.mem.writeInt(u16, chunk_header[2..4], ~len_u16, .little);
        try output.appendSlice(allocator, &chunk_header);

        if (chunk_len > 0) {
            try output.appendSlice(allocator, input[offset .. offset + chunk_len]);
        }

        if (is_last) break;
        offset += chunk_len;
    }

    var checksum: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum, adler.adler, .big);
    try output.appendSlice(allocator, &checksum);

    return try output.toOwnedSlice(allocator);
}

fn decompressZlib(allocator: Allocator, compressed: []const u8) ![]u8 {
    var reader: std.Io.Reader = .fixed(compressed);
    var decompressor: std.compress.flate.Decompress = .init(&reader, .zlib, &.{});
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    _ = try decompressor.reader.streamRemaining(&output.writer);
    return try output.toOwnedSlice();
}

fn decompressPackObject(allocator: Allocator, compressed_tail: []const u8) !struct { data: []u8, consumed: usize } {
    var reader: std.Io.Reader = .fixed(compressed_tail);
    var decompressor: std.compress.flate.Decompress = .init(&reader, .zlib, &.{});
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    _ = try decompressor.reader.streamRemaining(&output.writer);
    return .{
        .data = try output.toOwnedSlice(),
        .consumed = reader.seek,
    };
}

fn treeContentsAppendEntry(
    buffer: *std.ArrayList(u8),
    allocator: Allocator,
    mode: []const u8,
    name: []const u8,
    object_id: [20]u8,
) !void {
    try buffer.writer(allocator).print("{s} {s}", .{ mode, name });
    try buffer.append(allocator, 0);
    try buffer.appendSlice(allocator, object_id[0..]);
}

fn treeEntryLessThan(_: void, lhs: TreeEntry, rhs: TreeEntry) bool {
    return normalizedTreeNameLessThan(lhs.name, lhs.kind == .directory, rhs.name, rhs.kind == .directory);
}

fn normalizedTreeNameLessThan(lhs: []const u8, lhs_is_dir: bool, rhs: []const u8, rhs_is_dir: bool) bool {
    var index: usize = 0;
    while (true) : (index += 1) {
        const lhs_byte = normalizedTreeNameByte(lhs, lhs_is_dir, index);
        const rhs_byte = normalizedTreeNameByte(rhs, rhs_is_dir, index);

        if (lhs_byte == null and rhs_byte == null) return false;
        if (lhs_byte == null) return true;
        if (rhs_byte == null) return false;
        if (lhs_byte.? != rhs_byte.?) return lhs_byte.? < rhs_byte.?;
    }
}

fn normalizedTreeNameByte(name: []const u8, is_dir: bool, index: usize) ?u8 {
    if (index < name.len) return name[index];
    if (index == name.len and is_dir) return '/';
    return null;
}

fn nextTreeEntry(data: []const u8, index: *usize) !?ParsedTreeEntry {
    if (index.* == data.len) return null;
    if (index.* > data.len) return error.InvalidObject;

    const mode_end = std.mem.indexOfScalar(u8, data[index.*..], ' ') orelse return error.InvalidObject;
    const mode = data[index.* .. index.* + mode_end];

    const name_start = index.* + mode_end + 1;
    const name_end_rel = std.mem.indexOfScalar(u8, data[name_start..], 0) orelse return error.InvalidObject;
    const name_end = name_start + name_end_rel;
    const object_id_start = name_end + 1;
    if (object_id_start + 20 > data.len) return error.InvalidObject;

    var object_id: [20]u8 = undefined;
    @memcpy(object_id[0..], data[object_id_start .. object_id_start + 20]);

    index.* = object_id_start + 20;
    return .{
        .mode = mode,
        .name = data[name_start..name_end],
        .object_id = object_id,
    };
}

fn readPackHeader(pack_bytes: []const u8, offset: *usize) !PackHeader {
    if (offset.* >= pack_bytes.len) return error.InvalidPackObject;

    var byte = pack_bytes[offset.*];
    offset.* += 1;

    const object_type = switch ((byte >> 4) & 0x07) {
        1 => ObjectType.commit,
        2 => ObjectType.tree,
        3 => ObjectType.blob,
        4 => ObjectType.tag,
        6 => ObjectType.ofs_delta,
        7 => ObjectType.ref_delta,
        else => return error.UnsupportedPackObjectType,
    };

    var size: usize = byte & 0x0f;
    var shift: u6 = 4;

    while ((byte & 0x80) != 0) {
        if (offset.* >= pack_bytes.len) return error.InvalidPackObject;
        byte = pack_bytes[offset.*];
        offset.* += 1;

        size |= @as(usize, byte & 0x7f) << shift;
        shift += 7;
    }

    return .{
        .object_type = object_type,
        .size = size,
    };
}

fn applyDelta(allocator: Allocator, base: []const u8, delta: []const u8) ![]u8 {
    var index: usize = 0;

    const base_size = try readDeltaVarInt(delta, &index);
    if (base_size != base.len) return error.InvalidDeltaBase;

    const result_size = try readDeltaVarInt(delta, &index);
    var result = try allocator.alloc(u8, result_size);
    errdefer allocator.free(result);

    var out_index: usize = 0;

    while (index < delta.len) {
        const opcode = delta[index];
        index += 1;

        if ((opcode & 0x80) != 0) {
            var copy_offset: usize = 0;
            var copy_size: usize = 0;

            if ((opcode & 0x01) != 0) {
                if (index >= delta.len) return error.InvalidDeltaInstruction;
                copy_offset |= delta[index];
                index += 1;
            }
            if ((opcode & 0x02) != 0) {
                if (index >= delta.len) return error.InvalidDeltaInstruction;
                copy_offset |= @as(usize, delta[index]) << 8;
                index += 1;
            }
            if ((opcode & 0x04) != 0) {
                if (index >= delta.len) return error.InvalidDeltaInstruction;
                copy_offset |= @as(usize, delta[index]) << 16;
                index += 1;
            }
            if ((opcode & 0x08) != 0) {
                if (index >= delta.len) return error.InvalidDeltaInstruction;
                copy_offset |= @as(usize, delta[index]) << 24;
                index += 1;
            }

            if ((opcode & 0x10) != 0) {
                if (index >= delta.len) return error.InvalidDeltaInstruction;
                copy_size |= delta[index];
                index += 1;
            }
            if ((opcode & 0x20) != 0) {
                if (index >= delta.len) return error.InvalidDeltaInstruction;
                copy_size |= @as(usize, delta[index]) << 8;
                index += 1;
            }
            if ((opcode & 0x40) != 0) {
                if (index >= delta.len) return error.InvalidDeltaInstruction;
                copy_size |= @as(usize, delta[index]) << 16;
                index += 1;
            }

            if (copy_size == 0) copy_size = 0x10000;
            if (copy_offset + copy_size > base.len) return error.InvalidDeltaInstruction;
            if (out_index + copy_size > result.len) return error.InvalidDeltaInstruction;

            @memcpy(result[out_index .. out_index + copy_size], base[copy_offset .. copy_offset + copy_size]);
            out_index += copy_size;
            continue;
        }

        if (opcode == 0) return error.InvalidDeltaInstruction;

        const literal_len = @as(usize, opcode);
        if (index + literal_len > delta.len) return error.InvalidDeltaInstruction;
        if (out_index + literal_len > result.len) return error.InvalidDeltaInstruction;

        @memcpy(result[out_index .. out_index + literal_len], delta[index .. index + literal_len]);
        out_index += literal_len;
        index += literal_len;
    }

    if (out_index != result.len) return error.InvalidDeltaInstruction;
    return result;
}

fn readDeltaVarInt(data: []const u8, index: *usize) !usize {
    var value: usize = 0;
    var shift: u6 = 0;

    while (true) {
        if (index.* >= data.len) return error.InvalidDeltaInstruction;

        const byte = data[index.*];
        index.* += 1;

        value |= @as(usize, byte & 0x7f) << shift;
        if ((byte & 0x80) == 0) return value;

        shift += 7;
    }
}

fn parseCommitTree(body: []const u8) ![20]u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "tree ")) {
            return parseObjectIdHex(line["tree ".len..]);
        }
    }
    return error.InvalidCommitObject;
}

fn deriveHeadRef(refs: []const AdvertisedRef, head_oid: [20]u8) ?[]const u8 {
    for (refs) |ref| {
        if (!std.mem.startsWith(u8, ref.name, "refs/heads/")) continue;
        if (std.mem.eql(u8, ref.object_id[0..], head_oid[0..])) return ref.name;
    }
    return null;
}

fn ensureParentPath(dir: std.fs.Dir, sub_path: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, sub_path, '/')) |last_slash| {
        if (last_slash > 0) try dir.makePath(sub_path[0..last_slash]);
    }
}
