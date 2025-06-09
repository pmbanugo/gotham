const c = @cImport({
    @cInclude("picohttpparser.h");
});

const std = @import("std");

/// Represents a single HTTP header.
/// The name and value slices point directly into the original request buffer.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Represents a parsed HTTP request.
/// String fields (method, path, header names/values) are slices
/// pointing directly into the original request buffer for zero-copy.
pub const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    body_chunk: []const u8,
    minor_version: c_int,
    _embedded_header_storage: [MAX_HEADERS]Header, // Fixed Array to hold parsed headers. This way we don't have to allocate memory dynamically.... but.... is there a better alternative that avoids heap allocation?
    headers: []Header, // Slice pointing into _embedded_header_storage

    /// Helper function to get the value of the first header with the given name.
    /// Performs a case-insensitive comparison for the header name.
    pub fn getHeader(self: HttpRequest, comptime name_to_find: []const u8) ?[]const u8 {
        for (self.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name_to_find)) {
                return header.value;
            }
        }
        return null;
    }
};

/// Errors that can occur during request parsing.
pub const ParseError = error{
    PartialRequest,
    ParserError,
    OutOfMemory,
    TooManyHeaders, // If a fixed-size buffer for phr_header is used and overflows
};

const MAX_HEADERS = 64; // Maximum number of headers we'll parse. Adjust as needed or make it configurable at startup.

/// Parses an HTTP request from the given buffer.
///
/// Parameters:
///   - http_request: The pre-allocated HttpRequest object to populate.
///   - buffer: The raw byte buffer containing the HTTP request.
///   - previous_buffer_len: The length of the previously parsed incomplete request, or 0 if this is a new request.
///
/// Returns:
///   - A ParseError if parsing fails or the request is incomplete.
///   - The number of bytes consumed by the headers from the buffer.
pub fn parseRequest(
    http_request: *HttpRequest,
    buffer: []const u8,
    previous_buffer_len: usize,
) ParseError!usize {
    var method_ptr: [*c]const u8 = undefined;
    var method_len: usize = 0;
    var path_ptr: [*c]const u8 = undefined;
    var path_len: usize = 0;
    var minor_version: c_int = 0;

    // picohttpparser requires a mutable array of phr_header structs.
    // We can use a stack-allocated array if MAX_HEADERS is reasonably small.
    var phr_headers_buf: [MAX_HEADERS]c.phr_header = undefined;
    var num_headers: usize = MAX_HEADERS; // picohttpparser expects capacity, returns actual count

    const ret = c.phr_parse_request(
        buffer.ptr,
        buffer.len,
        &method_ptr,
        &method_len,
        &path_ptr,
        &path_len,
        &minor_version,
        &phr_headers_buf[0], // Pass pointer to the first element
        &num_headers, // Will be updated with the actual number of parsed headers
        previous_buffer_len,
    );

    if (ret == -1) {
        return ParseError.ParserError;
    }
    if (ret == -2) {
        // request is incomplete, continue the http/socket loop
        return ParseError.PartialRequest;
    }

    // ret now holds the number of bytes consumed.
    const consumed_by_headers: usize = @intCast(ret);

    // Populate the HttpRequest object
    http_request.method = method_ptr[0..method_len];
    http_request.path = path_ptr[0..path_len];
    http_request.minor_version = minor_version;
    http_request.body_chunk = buffer[consumed_by_headers..];

    // Populate the embedded header storage
    for (phr_headers_buf[0..num_headers], 0..) |phr_h, i| {
        http_request._embedded_header_storage[i] = Header{
            .name = phr_h.name[0..phr_h.name_len],
            .value = phr_h.value[0..phr_h.value_len],
        };
    }
    // Set the headers slice to point to the populated part of the embedded storage
    http_request.headers = http_request._embedded_header_storage[0..num_headers];

    return consumed_by_headers;
}

test "parse simple GET request" {
    const allocator = std.testing.allocator;
    var request_instance = try allocator.create(HttpRequest);
    defer allocator.destroy(request_instance);

    const request_data = "GET /hello HTTP/1.1\r\nHost: example.com\r\nUser-Agent: test\r\n\r\n";
    const buffer = request_data;

    const consumed_bytes = try parseRequest(request_instance, buffer, 0);

    try std.testing.expectEqualSlices(u8, "GET", request_instance.method);
    try std.testing.expectEqualSlices(u8, "/hello", request_instance.path);
    try std.testing.expectEqual(@as(c_int, 1), request_instance.minor_version);
    try std.testing.expectEqual(@as(usize, 2), request_instance.headers.len);

    try std.testing.expectEqualSlices(u8, "Host", request_instance.headers[0].name);
    try std.testing.expectEqualSlices(u8, "example.com", request_instance.headers[0].value);
    try std.testing.expectEqualSlices(u8, "User-Agent", request_instance.headers[1].name);
    try std.testing.expectEqualSlices(u8, "test", request_instance.headers[1].value);

    const host = request_instance.getHeader("Host");
    try std.testing.expect(host != null);
    try std.testing.expectEqualSlices(u8, "example.com", host.?);

    const user_agent_ci = request_instance.getHeader("user-agent"); // Case-insensitive check
    try std.testing.expect(user_agent_ci != null);
    try std.testing.expectEqualSlices(u8, "test", user_agent_ci.?);

    const non_existent = request_instance.getHeader("Non-Existent");
    try std.testing.expect(non_existent == null);

    // For a GET request with no body, body_chunk should be empty.
    try std.testing.expectEqualSlices(u8, "", request_instance.body_chunk);

    // Check consumed bytes
    const expected_consumed_for_headers = request_data.len;
    try std.testing.expectEqual(@as(usize, expected_consumed_for_headers), consumed_bytes);
}

test "parse POST request with body" {
    const allocator = std.testing.allocator;
    var request_instance = try allocator.create(HttpRequest);
    defer allocator.destroy(request_instance);

    const request_body_content = "{\"key\": \"value\"}";

    const request_data = "POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Type: application/json\r\nContent-Length: 16\r\n\r\n{\"key\": \"value\"}";
    const buffer = request_data;

    const consumed_bytes = try parseRequest(request_instance, buffer, 0);

    try std.testing.expectEqualSlices(u8, "POST", request_instance.method);
    try std.testing.expectEqualSlices(u8, "/submit", request_instance.path);
    try std.testing.expectEqual(@as(c_int, 1), request_instance.minor_version);
    try std.testing.expectEqual(@as(usize, 3), request_instance.headers.len);

    const content_length_header = request_instance.getHeader("Content-Length");
    try std.testing.expect(content_length_header != null);
    try std.testing.expectEqualSlices(u8, @tagName(request_body_content.len), content_length_header.?);

    try std.testing.expectEqualSlices(u8, request_body_content, request_instance.body_chunk);

    const expected_header_bytes = request_data.len - request_body_content.len;
    try std.testing.expectEqual(@as(usize, expected_header_bytes), consumed_bytes);
}

test "parse partial request" {
    const allocator = std.testing.allocator;
    const request_instance = try allocator.create(HttpRequest); // Still need an instance to pass
    defer allocator.destroy(request_instance);

    const partial_request_data = "GET /partial HT"; // Incomplete
    const buffer = partial_request_data;

    const result = parseRequest(request_instance, buffer, 0);
    try std.testing.expectError(ParseError.PartialRequest, result);
}

test "parse error request" {
    const allocator = std.testing.allocator;
    const request_instance = try allocator.create(HttpRequest); // Still need an instance to pass
    defer allocator.destroy(request_instance);

    const error_request_data = "GET /error\nInvalid\n"; // Invalid HTTP
    const buffer = error_request_data;

    const result = parseRequest(request_instance, buffer, 0);
    try std.testing.expectError(ParseError.ParserError, result);
}
