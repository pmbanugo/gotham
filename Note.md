# Gotham Project - uSockets Integration

## uSockets Build Configuration

This project integrates [uSockets](https://github.com/uNetworking/uSockets) as a high-performance networking library with configurable SSL and event loop support.

### Build Options

The build system supports the following configuration flags:

#### SSL Support

- **`-Dssl=true`** - Enable SSL/TLS support (default: `false`)
- **`-Dssl-backend=openssl`** - Use OpenSSL as SSL backend (default)
- **`-Dssl-backend=wolfssl`** - Use WolfSSL as SSL backend

#### Event Loop Configuration

- **`-Dio-uring=true`** - Enable io_uring support on Linux (default: `false`)

### Platform-Specific Event Loops

The build automatically selects the optimal event loop for each platform:

- **Linux**:
  - io_uring (if `-Dio-uring=true` is specified)
  - epoll (default fallback)
- **macOS/FreeBSD/OpenBSD/NetBSD/DragonFlyBSD**: kqueue
- **Other Unix-like systems**: epoll

### Build Examples

#### Basic build (no SSL, platform default event loop)

```bash
zig build
```

#### Build with SSL support using OpenSSL

```bash
zig build -Dssl=true
```

#### Build with SSL support using WolfSSL

```bash
zig build -Dssl=true -Dssl-backend=wolfssl
```

#### Build with io_uring on Linux

```bash
zig build -Dio-uring=true
```

#### Build with SSL and io_uring (Linux only)

```bash
zig build -Dssl=true -Dio-uring=true
```

#### Release build with SSL

```bash
zig build -Doptimize=ReleaseFast -Dssl=true
```

### System Dependencies

#### For SSL Support

**OpenSSL (default)**:

- Ubuntu/Debian: `sudo apt install libssl-dev`
- macOS: `brew install openssl`
- Fedora/RHEL: `sudo dnf install openssl-devel`

**WolfSSL**:

- Ubuntu/Debian: `sudo apt install libwolfssl-dev`
- macOS: `brew install wolfssl`
- Build from source: [WolfSSL Installation Guide](https://www.wolfssl.com/documentation/manuals/wolfssl/chapter02.html)

#### For io_uring Support (Linux only)

- Ubuntu/Debian 20.04+: `sudo apt install liburing-dev`
- Fedora 32+: `sudo dnf install liburing-devel`
- Requires Linux kernel 5.1+ for basic support, 5.4+ recommended

### Usage in Zig Code

Include the uSockets header in your Zig code:

```zig
const c = @cImport({
    @cInclude("libusockets.h");
});

// Example usage
const loop = c.us_create_loop(null, null, null, null);
defer c.us_loop_free(loop);
```

### Library Structure

- **Public Header**: `libusockets.h` - The only header you need to include
- **Static Library**: `usockets` - Automatically linked to your executable
- **C++ Support**: Automatically enabled when SSL is used (required for SSL implementations)

### Notes

- The build excludes Windows-specific libuv support as we focus on native event loops
- SSL support requires C++ linking due to the SSL implementation (`sni_tree.cpp`)
- io_uring provides the best performance on modern Linux systems but requires recent kernel versions
- The library is compiled with `-fno-sanitize=undefined` to handle potential undefined behavior in uSockets (according to Claude Sonnet 4, but I don't know yet what that means. The original Makefile has sanitizer set to addess.)
- There are other folks who have tried to use uSockets with Zig, but their repos has not been updated for a while, and their build scripts are configured different from how I want to use this library. See:
  - https://github.com/glingy/uSockets-zig
  - https://github.com/lithdew/usockets-zig, with [BoringSSL build](https://github.com/lithdew/boringssl-zig) to work with it.

## Extra Notes

- The plan is to support http 1.1 with and without TLS, and http3/QUIC. H3 should be straight forward once I'm done with the http 1.1 implementation, because the library supports it. I'm omitting H2 because I think folks should use HTTP/1.1 or HTTP/3, and H2 might be slow on some systems (I think I saw that somewhere, but I don't remember where).
