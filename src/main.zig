//! Gotham HTTP Server Example
//! This example demonstrates a simple HTTP server using the Gotham framework.

const std = @import("std");
/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
const lib = @import("gotham_lib");
const usockets = @cImport({
    @cInclude("libusockets.h");
});

const log = std.log.scoped(.gotham);

// We're not using SSL for this example
const SSL = 1;

// HttpResponse state flags
const HTTP_STATUS_WRITTEN: u8 = 1 << 0;
const HTTP_HEADERS_WRITTEN: u8 = 1 << 1;
const HTTP_BODY_STARTED: u8 = 1 << 2;
const HTTP_RESPONSE_ENDED: u8 = 1 << 3;
const HTTP_CONNECTION_CLOSE: u8 = 1 << 4;
const HTTP_CHUNKED_ENCODING: u8 = 1 << 5;

const HttpResponse = struct {
    socket: *usockets.us_socket_t,
    state: u8 = 0, // state with bit flags
    status_code: u16 = 200,
    header_buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, socket: *usockets.us_socket_t) HttpResponse {
        // Pre-allocate reasonable header buffer size to avoid reallocations
        const header_buffer = std.ArrayList(u8).initCapacity(allocator, 1024) catch
            std.ArrayList(u8).init(allocator);

        return HttpResponse{
            .socket = socket,
            .header_buffer = header_buffer,
            .allocator = allocator,
        };
    }

    pub fn writeStatus(self: *HttpResponse, code: u16) *HttpResponse {
        if ((self.state & HTTP_STATUS_WRITTEN) != 0 or (self.state & HTTP_RESPONSE_ENDED) != 0) return self;

        self.status_code = code;
        const status_text = getStatusText(code);

        self.header_buffer.writer().print("HTTP/1.1 {d} {s}\r\n", .{ code, status_text }) catch return self;
        self.state |= HTTP_STATUS_WRITTEN;

        return self;
    }

    pub fn writeHeader(self: *HttpResponse, name: []const u8, value: []const u8) *HttpResponse {
        if ((self.state & HTTP_HEADERS_WRITTEN) != 0 or (self.state & HTTP_RESPONSE_ENDED) != 0) return self;

        if ((self.state & HTTP_STATUS_WRITTEN) == 0) {
            _ = self.writeStatus(200);
        }

        self.header_buffer.writer().print("{s}: {s}\r\n", .{ name, value }) catch return self;

        return self;
    }

    fn flushHeaders(self: *HttpResponse) void {
        if ((self.state & HTTP_HEADERS_WRITTEN) == 0 and self.header_buffer.items.len > 0) {
            // Add final CRLF to end headers section
            self.header_buffer.writer().writeAll("\r\n") catch return;
            _ = usockets.us_socket_write(SSL, self.socket, self.header_buffer.items.ptr, @intCast(self.header_buffer.items.len), 0);
            self.state |= HTTP_HEADERS_WRITTEN;
        }
    } // Enter or continue chunked encoding mode. Writes part of the response.
    // End with zero length write. Returns true if no backpressure was added.
    // TODO: Add backpressure handling - should queue remainder for writable callback
    // TODO: When write() returns false, data should be queued and sent in onHttpSocketWritable
    pub fn write(self: *HttpResponse, data: []const u8) !bool {
        if ((self.state & HTTP_RESPONSE_ENDED) != 0) return false; // Response already ended

        if ((self.state & HTTP_BODY_STARTED) == 0) {
            // First write - close headers and start chunked encoding
            _ = self.writeHeader("Transfer-Encoding", "chunked");
            self.flushHeaders(); // Single syscall for all headers
            self.state |= HTTP_BODY_STARTED | HTTP_CHUNKED_ENCODING;
        }

        // Handle zero-length write (end chunked encoding)
        if (data.len == 0 and (self.state & HTTP_CHUNKED_ENCODING) != 0) {
            _ = usockets.us_socket_write(SSL, self.socket, "0\r\n\r\n", 5, 0);
            self.state |= HTTP_RESPONSE_ENDED;
            return true;
        }

        if ((self.state & HTTP_CHUNKED_ENCODING) != 0 and data.len > 0) {
            // Build chunk header
            var chunk_header: [32]u8 = undefined;
            const chunk_size_str = std.fmt.bufPrint(&chunk_header, "{X}\r\n", .{data.len}) catch return false;

            // Use stack buffer with @memcpy for optimal performance
            var data_with_trailer: []u8 = undefined;
            var stack_buffer: [4104]u8 = undefined; // Stack buffer for 4KB chunks + trailer (8-byte aligned). For future, I could consider using a larger buffer if needed (4-8KB?).

            if (data.len + 2 <= stack_buffer.len) {
                // Fast path: use stack buffer with @memcpy
                @memcpy(stack_buffer[0..data.len], data);
                @memcpy(stack_buffer[data.len .. data.len + 2], "\r\n");
                data_with_trailer = stack_buffer[0 .. data.len + 2];
            } else {
                // Fallback: heap allocation for large chunks
                var heap_buffer = self.allocator.alloc(u8, data.len + 2) catch return false;
                defer self.allocator.free(heap_buffer);
                @memcpy(heap_buffer[0..data.len], data);
                @memcpy(heap_buffer[data.len .. data.len + 2], "\r\n");
                data_with_trailer = heap_buffer;
            }

            // Single syscall: chunk header + (data + trailer)
            // TODO: When SSL support is added, use separate us_socket_write() calls since us_socket_write2() is non-SSL only
            _ = usockets.us_socket_write2(SSL, self.socket, chunk_size_str.ptr, @intCast(chunk_size_str.len), data_with_trailer.ptr, @intCast(data_with_trailer.len));
        }

        // For now, always return true (no backpressure handling yet)
        return true;
    } // Complete response with optional final data
    pub fn end(self: *HttpResponse, data: []const u8) !void {
        if ((self.state & HTTP_RESPONSE_ENDED) != 0) return; // Already ended, ignore

        if (data.len > 0) {
            if ((self.state & HTTP_BODY_STARTED) == 0) {
                // Ensure status is written and add content-length
                if ((self.state & HTTP_STATUS_WRITTEN) == 0) {
                    _ = self.writeStatus(200);
                }

                // Build content-length header
                self.header_buffer.writer().print("Content-Length: {d}\r\n\r\n", .{data.len}) catch return;

                // Use us_socket_write2() for optimal header+body write - single syscall!
                // TODO: When SSL support is added, use separate us_socket_write() calls since us_socket_write2() is non-SSL only
                _ = usockets.us_socket_write2(SSL, self.socket, self.header_buffer.items.ptr, @intCast(self.header_buffer.items.len), data.ptr, @intCast(data.len));
            } else {
                // Final chunk in chunked encoding
                _ = try self.write(data);
                _ = try self.write(""); // Terminating chunk
            }
        } else {
            if ((self.state & HTTP_CHUNKED_ENCODING) != 0) {
                // Terminating chunk only
                _ = usockets.us_socket_write(SSL, self.socket, "0\r\n\r\n", 5, 0);
            } else if ((self.state & HTTP_BODY_STARTED) == 0) {
                // Headers only response - ensure we have status line
                if ((self.state & HTTP_STATUS_WRITTEN) == 0) {
                    _ = self.writeStatus(200);
                }
                self.header_buffer.writer().writeAll("\r\n") catch return;
                _ = usockets.us_socket_write(SSL, self.socket, self.header_buffer.items.ptr, @intCast(self.header_buffer.items.len), 0);
                self.state |= HTTP_HEADERS_WRITTEN;
            }
        }

        self.state |= HTTP_RESPONSE_ENDED;
    }

    // TODO: Implement tryEnd for backpressure handling
    // pub fn tryEnd(self: *HttpResponse, data: []const u8) !bool {
    //     // Should check if socket write buffer has space
    //     // Return false if would block, queue data for later
    //     return false;
    // }

    //TODO: this is incomplete and needs to be reworked and expanded to support more status codes
    fn getStatusText(code: u16) []const u8 {
        return switch (code) {
            200 => "OK",
            201 => "Created",
            400 => "Bad Request",
            404 => "Not Found",
            500 => "Internal Server Error",
            else => "Unknown",
        };
    }
};

// HTTP socket extension data
const HttpSocket = struct {
    offset: i32 = 0,
    response: ?*HttpResponse = null, // TODO: Use for queued writes in backpressure handling
};

// HTTP context extension data
const HttpContext = struct {
    allocator: std.mem.Allocator, // Changed from pre-built response to allocator
};

// Event loop callbacks (empty implementations for now)
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
    _ = http_socket; // TODO: Use for queued writes in backpressure handling

    // TODO: Implement backpressure handling - should continue writing queued data
    // TODO: This callback is triggered when socket is ready for more data after write() returned false
    // For now, this is just a placeholder

    return socket;
}

fn onHttpSocketClose(socket: ?*usockets.us_socket_t, code: i32, reason: ?*anyopaque) callconv(.C) ?*usockets.us_socket_t {
    _ = code;
    _ = reason;
    log.debug("Client disconnected", .{});
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

    const socket_context = usockets.us_socket_context(SSL, socket);
    const http_context: *HttpContext = @ptrCast(@alignCast(usockets.us_socket_context_ext(SSL, socket_context)));

    // Use ArenaAllocator for this request - all allocations freed at once
    var arena = std.heap.ArenaAllocator.init(http_context.allocator);
    defer arena.deinit(); // Single cleanup for entire request!

    const arena_allocator = arena.allocator();

    // Create response with arena allocator
    var response = HttpResponse.create(arena_allocator, socket.?);

    //TODO: Build dynamic response - this is where user code would go
    _ = response.writeStatus(200);
    _ = response.writeHeader("Content-Type", "text/plain");
    _ = response.writeHeader("Server", "Gotham/0.1");

    response.end("Hello from Dynamic Gotham Server!") catch |err| {
        log.err("Failed to send response: {}", .{err});
    };

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

    log.debug("Client connected", .{});

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
        log.err("Could not create socket context", .{});
        return;
    }

    const http_context_ext: *HttpContext = @ptrCast(@alignCast(usockets.us_socket_context_ext(SSL, http_context)));
    http_context_ext.allocator = allocator;

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
        log.info("Listening on localhost:3000...", .{});
        usockets.us_loop_run(loop);
    } else {
        log.err("Failed to listen on port 3000!", .{});
    }
}
