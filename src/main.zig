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

const CORK_BUFFER_SIZE: u16 = 16 * 1024;

// Loop data for corking (I need to figure out a better name for this)
const LoopData = struct {
    cork_buffer: [CORK_BUFFER_SIZE]u8 = undefined,
    cork_offset: u16 = 0,
    corked_socket: ?*usockets.us_socket_t = null,

    fn getCorkBuffer(self: *LoopData, bytes: u16) ?[]u8 {
        if (self.cork_offset + bytes <= CORK_BUFFER_SIZE) {
            const start = self.cork_offset;
            self.cork_offset += bytes;
            return self.cork_buffer[start..self.cork_offset];
        }
        return null;
    }

    fn flushCork(self: *LoopData) void {
        if (self.corked_socket != null and self.cork_offset > 0) {
            _ = usockets.us_socket_write(SSL, self.corked_socket, &self.cork_buffer[0], @intCast(self.cork_offset), 0);
            self.cork_offset = 0;
        }
    }

    fn uncork(self: *LoopData, socket: *usockets.us_socket_t) void {
        if (self.corked_socket == socket) {
            self.flushCork();
            self.corked_socket = null;
        }
    }

    fn cork(self: *LoopData, socket: *usockets.us_socket_t) void {
        if (self.corked_socket != socket) {
            self.flushCork(); // Flush any previous socket
            self.corked_socket = socket;
            self.cork_offset = 0;
        }
    }
};

// Get loop data from us_loop_t
fn getLoopData(loop: *usockets.us_loop_t) *LoopData {
    return @ptrCast(@alignCast(usockets.us_loop_ext(loop)));
}

const HttpResponse = struct {
    socket: *usockets.us_socket_t,
    state: u8 = 0, // state with bit flags
    status_code: u16 = 200,

    pub fn create(socket: *usockets.us_socket_t) HttpResponse {
        return HttpResponse{
            .socket = socket,
        };
    }

    // Cork this socket and execute handler, then uncork
    pub fn cork(self: *HttpResponse, handler: *const fn (*HttpResponse) void) void {
        const socket_context = usockets.us_socket_context(SSL, self.socket);
        const loop = usockets.us_socket_context_loop(SSL, socket_context);
        const loop_data = getLoopData(loop.?);

        loop_data.cork(self.socket);
        handler(self);
        loop_data.uncork(self.socket);
    }

    // Efficient write - tries cork buffer first, then direct syscall
    fn writeEfficiently(self: *HttpResponse, data: []const u8) bool {
        if (data.len == 0) return true;

        const socket_context = usockets.us_socket_context(SSL, self.socket);
        const loop = usockets.us_socket_context_loop(SSL, socket_context);
        const loop_data = getLoopData(loop.?);

        // If this socket is corked, try to use cork buffer
        if (loop_data.corked_socket == self.socket) {
            if (loop_data.getCorkBuffer(@intCast(data.len))) |buffer| {
                @memcpy(buffer[0..data.len], data);
                return true; // Successfully buffered
            }
            // Cork buffer full, flush and continue to direct write
            loop_data.flushCork();
        }

        // Direct syscall
        const result = usockets.us_socket_write(SSL, self.socket, data.ptr, @intCast(data.len), 0);
        return result != 0; // Return false if write would block (future backpressure handling)
    }

    pub fn writeStatus(self: *HttpResponse, code: u16) *HttpResponse {
        if ((self.state & HTTP_STATUS_WRITTEN) != 0 or (self.state & HTTP_RESPONSE_ENDED) != 0) return self;

        self.status_code = code;
        const status_text = getStatusText(code);

        // Build status line directly and write via efficient write
        var status_buffer: [128]u8 = undefined;
        const status_line = std.fmt.bufPrint(&status_buffer, "HTTP/1.1 {d} {s}\r\n", .{ code, status_text }) catch return self;

        _ = self.writeEfficiently(status_line);
        self.state |= HTTP_STATUS_WRITTEN;

        return self;
    }

    pub fn writeHeader(self: *HttpResponse, name: []const u8, value: []const u8) *HttpResponse {
        if ((self.state & HTTP_HEADERS_WRITTEN) != 0 or (self.state & HTTP_RESPONSE_ENDED) != 0) return self;

        if ((self.state & HTTP_STATUS_WRITTEN) == 0) {
            _ = self.writeStatus(200);
        }

        // Build header line directly and write via efficient write
        var header_buffer: [512]u8 = undefined;
        const header_line = std.fmt.bufPrint(&header_buffer, "{s}: {s}\r\n", .{ name, value }) catch return self;

        _ = self.writeEfficiently(header_line);

        return self;
    }

    fn endHeaders(self: *HttpResponse) void {
        if ((self.state & HTTP_HEADERS_WRITTEN) == 0) {
            // Write final CRLF to end headers section
            _ = self.writeEfficiently("\r\n");
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
            self.endHeaders(); // End headers section
            self.state |= HTTP_BODY_STARTED | HTTP_CHUNKED_ENCODING;
        }

        // Handle zero-length write (end chunked encoding)
        if (data.len == 0 and (self.state & HTTP_CHUNKED_ENCODING) != 0) {
            _ = self.writeEfficiently("0\r\n\r\n");
            self.state |= HTTP_RESPONSE_ENDED;
            return true;
        }

        if ((self.state & HTTP_CHUNKED_ENCODING) != 0 and data.len > 0) {
            // Build chunk header
            var chunk_header: [32]u8 = undefined;
            const chunk_size_str = std.fmt.bufPrint(&chunk_header, "{X}\r\n", .{data.len}) catch return false;

            // Write chunk header
            _ = self.writeEfficiently(chunk_size_str);

            // Write chunk data
            _ = self.writeEfficiently(data);

            // Write chunk trailer
            _ = self.writeEfficiently("\r\n");
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

                // Build content-length header and write CRLF to end headers
                var content_length_buffer: [64]u8 = undefined;
                const content_length_header = std.fmt.bufPrint(&content_length_buffer, "Content-Length: {d}\r\n\r\n", .{data.len}) catch return;

                _ = self.writeEfficiently(content_length_header);
                _ = self.writeEfficiently(data);

                self.state |= HTTP_HEADERS_WRITTEN | HTTP_BODY_STARTED;
            } else {
                // Final chunk in chunked encoding
                _ = try self.write(data);
                _ = try self.write(""); // Terminating chunk
            }
        } else {
            if ((self.state & HTTP_CHUNKED_ENCODING) != 0) {
                // Terminating chunk only
                _ = self.writeEfficiently("0\r\n\r\n");
            } else if ((self.state & HTTP_BODY_STARTED) == 0) {
                // Headers only response - ensure we have status line
                if ((self.state & HTTP_STATUS_WRITTEN) == 0) {
                    _ = self.writeStatus(200);
                }
                self.endHeaders();
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

    // Create response directly
    var response = HttpResponse.create(socket.?);

    // Handler function for corked response
    const handleRequest = struct {
        fn handle(res: *HttpResponse) void {
            //TODO: Build dynamic response - this is where user code would go
            _ = res.writeStatus(200);
            _ = res.writeHeader("Content-Type", "text/plain");
            _ = res.writeHeader("Server", "Gotham/0.1");

            res.end("Hello from Gotham Server!") catch |err| {
                log.err("Failed to send response: {}", .{err});
            };
        }
    }.handle;

    // Cork socket for optimal batching
    response.cork(handleRequest);

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

    // Create the event loop with LoopData for corking
    const loop = usockets.us_create_loop(null, onWakeup, onPre, onPost, @sizeOf(LoopData));
    if (loop == null) {
        log.err("Could not create event loop", .{});
        return;
    }
    defer usockets.us_loop_free(loop);

    // Initialize loop data for corking
    const loop_data = getLoopData(loop.?);
    loop_data.* = LoopData{};

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
