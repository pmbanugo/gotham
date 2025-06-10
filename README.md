# Gotham - High-performance HTTP Server Library

Gotham is a concurrent, high-performance HTTP server library written in Zig. It is designed to be lightweight, efficient, and easy to use, making it an excellent choice for building web applications and frameworks. The design principles/style are largely inspired by uWebSockets and h2o, with the aim to deliver similar performance and scalability.

## Goals

Its goal is to provide a robust foundation for developers who need a fast and reliable HTTP server without the overhead of larger frameworks. Those can be broken down to include:

- **Performance**: Achieve high throughput and low latency for handling HTTP requests.
- **Simplicity and Extensibility**: Provide a simple interface that allows developers to easily build custom frameworks, use custom routing, and other enhancements.
- **Security**: Provide options for secure connections using TLS.
- **Standard Compliance**: Ensure compliance with HTTP/1.1 standards while providing a foundation for future HTTP/3 support.
- **Flexible Request Handling**: Developers can easily define custom request handlers to suit their application's needs.

## Current Status

Gotham is in early development but functional for experimentation and hobby projects. Here's what's currently available:

- ✅ Basic HTTP/1.x server implementation
- ✅ Custom request handler support
- ✅ High-performance async I/O using uSockets
- ✅ Simple response writing API
- ❌ No built-in routing system (custom handlers required)
- ❌ No TLS/HTTPS support yet

The library is transitioning from experimental code to a usable library interface. Performance testing shows promising results (~122k req/s, single-threaded), but more optimization and features are planned.

## Getting Started

Gotham isn't ready to be used as a library yet. However, you can run the example to see how it works.

> I believe I've reached a point of my experimentation where I can start tuning it to be used as a library. The current code is still in an early stage, but it is functional.

The current example demonstrates a simple HTTP server that responds with a "Hello World" message. To run the example, open your terminal and execute the following commands:

```bash
git clone git@github.com:pmbanugo/gotham.git
cd gotham
zig build run
curl -v http://localhost:8080
```

You can change what the response is by modifying the `defaultRequestHandler` function in `src/main.zig`. For example, you can change it to return the request path:

```zig
fn defaultRequestHandler(arena_allocator: std.mem.Allocator, request: *const parser.HttpRequest, response: *HttpResponse) void {
    _ = arena_allocator; // Allocator might be used for dynamic responses

    _ = response.writeStatus(.ok);
    _ = response.writeHeader("Content-Type", "text/plain");
    _ = response.writeHeader("Server", "Gotham/0.1");
    response.end(request.path) catch |err| {
        log.err("Failed to send response in default handler: {}", .{err});
    };
}
```

Then, run the server (`zig build -Doptimize=ReleaseFast run`) and make a request to see the new response.

## FAQ

- **How fast is it?**
  - The exact performance depends on your usage. On my M1 MacBook Pro (16GB), it can handle around 122,503 requests per second with `Hello via default handler!` response (measured with `zig build -Doptimize=ReleaseFast` and `oha -z 20s --no-tui http://localhost:3000`). Those will likely change as I work on adding more features and optimizations.
- **Is it production-ready?**
  - Not yet. While it is functional for hobby projects, it requires more testing, optimizations, and features before it can be considered production-ready.
- **Can I contribute?**
  - Perhaps! One way to contribute would be extending the build script to add more compile flags for its use of [uSockets](https://github.com/pmbanugo/uSockets.zig), or just by providing feedback on the design and implementation as things progress (pls use the Discussions tab for that).
