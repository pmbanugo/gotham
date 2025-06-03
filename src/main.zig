//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
const lib = @import("gotham_lib");
const usockets = @cImport({
    @cInclude("libusockets.h");
});

// We're not using SSL for this example
const SSL = 1;

// HTTP socket extension data
const HttpSocket = struct {
    offset: i32 = 0,
};

// HTTP context extension data
const HttpContext = struct {
    response: []u8,
    length: i32,
};

// Event loop callbacks (empty implementations)
fn onWakeup(loop: ?*usockets.us_loop_t) callconv(.C) void {
    _ = loop;
}

fn onPre(loop: ?*usockets.us_loop_t) callconv(.C) void {
    _ = loop;
}

fn onPost(loop: ?*usockets.us_loop_t) callconv(.C) void {
    _ = loop;
}

// Socket event handlers
fn onHttpSocketWritable(socket: ?*usockets.us_socket_t) callconv(.C) ?*usockets.us_socket_t {
    const http_socket: *HttpSocket = @ptrCast(@alignCast(usockets.us_socket_ext(SSL, socket)));
    const socket_context = usockets.us_socket_context(SSL, socket);
    const http_context: *HttpContext = @ptrCast(@alignCast(usockets.us_socket_context_ext(SSL, socket_context)));

    // Stream whatever is remaining of the response
    const bytes_written = usockets.us_socket_write(SSL, socket, http_context.response.ptr + @as(usize, @intCast(http_socket.offset)), http_context.length - http_socket.offset, 0);
    // http_socket.offset += @intCast(bytes_written);
    http_socket.offset += bytes_written;

    return socket;
}

fn onHttpSocketClose(socket: ?*usockets.us_socket_t, code: i32, reason: ?*anyopaque) callconv(.C) ?*usockets.us_socket_t {
    _ = code;
    _ = reason;
    std.log.info("Client disconnected", .{});
    return socket;
}

fn onHttpSocketEnd(socket: ?*usockets.us_socket_t) callconv(.C) ?*usockets.us_socket_t {
    // HTTP does not support half-closed sockets
    _ = usockets.us_socket_shutdown(SSL, socket);
    return usockets.us_socket_close(SSL, socket, 0, null);
}

fn onHttpSocketData(socket: ?*usockets.us_socket_t, data: [*c]u8, length: i32) callconv(.C) ?*usockets.us_socket_t {
    _ = data;
    _ = length;

    const http_socket: *HttpSocket = @ptrCast(@alignCast(usockets.us_socket_ext(SSL, socket)));
    const socket_context = usockets.us_socket_context(SSL, socket);
    const http_context: *HttpContext = @ptrCast(@alignCast(usockets.us_socket_context_ext(SSL, socket_context)));

    // We treat all data events as a request
    const bytes_written = usockets.us_socket_write(SSL, socket, http_context.response.ptr, http_context.length, 0);
    // http_socket.offset = @intCast(bytes_written);
    http_socket.offset = bytes_written;

    // Reset idle timer (30 seconds)
    usockets.us_socket_timeout(SSL, socket, 30);

    return socket;
}

fn onHttpSocketOpen(socket: ?*usockets.us_socket_t, is_client: i32, ip: [*c]u8, ip_length: i32) callconv(.C) ?*usockets.us_socket_t {
    _ = is_client;
    _ = ip;
    _ = ip_length;

    const http_socket: *HttpSocket = @ptrCast(@alignCast(usockets.us_socket_ext(SSL, socket)));

    // Reset offset
    http_socket.offset = 0;

    // Timeout idle HTTP connections
    usockets.us_socket_timeout(SSL, socket, 30);

    std.log.info("Client connected", .{});

    return socket;
}

fn onHttpSocketTimeout(socket: ?*usockets.us_socket_t) callconv(.C) ?*usockets.us_socket_t {
    // Close idle HTTP sockets
    return usockets.us_socket_close(SSL, socket, 0, null);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create the event loop
    const loop = usockets.us_create_loop(null, onWakeup, onPre, onPost, 0);
    defer usockets.us_loop_free(loop);

    // Create a socket context for HTTP (no SSL)
    const options = usockets.us_socket_context_options_t{
        .key_file_name = null,
        .cert_file_name = null,
        .passphrase = null,
        .dh_params_file_name = null,
        .ca_file_name = null,
        .ssl_ciphers = null,
        .ssl_prefer_low_memory_usage = 0,
    };

    const http_context = usockets.us_create_socket_context(SSL, loop, @sizeOf(HttpContext), options);
    if (http_context == null) {
        std.log.err("Could not create socket context", .{});
        return;
    }

    // Generate the shared response
    const body = "Hello from Zig HTTP Server";
    const response_template = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\n\r\n{s}";

    const response_str = try std.fmt.allocPrint(allocator, response_template, .{ body.len, body });
    defer allocator.free(response_str);

    const http_context_ext: *HttpContext = @ptrCast(@alignCast(usockets.us_socket_context_ext(SSL, http_context)));
    http_context_ext.response = try allocator.dupe(u8, response_str);
    http_context_ext.length = @intCast(response_str.len);

    // Set up event handlers
    usockets.us_socket_context_on_open(SSL, http_context, onHttpSocketOpen);
    usockets.us_socket_context_on_data(SSL, http_context, onHttpSocketData);
    usockets.us_socket_context_on_writable(SSL, http_context, onHttpSocketWritable);
    usockets.us_socket_context_on_close(SSL, http_context, onHttpSocketClose);
    usockets.us_socket_context_on_timeout(SSL, http_context, onHttpSocketTimeout);
    usockets.us_socket_context_on_end(SSL, http_context, onHttpSocketEnd);

    // Start serving HTTP connections on localhost:3000
    const listen_socket = usockets.us_socket_context_listen(SSL, http_context, null, 3000, 0, @sizeOf(HttpSocket));

    if (listen_socket != null) {
        std.log.info("Listening on localhost:3000...", .{});
        usockets.us_loop_run(loop);
    } else {
        std.log.err("Failed to listen on port 3000!", .{});
    }

    // Cleanup
    allocator.free(http_context_ext.response);
}
