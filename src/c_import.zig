pub const c = @cImport({
    @cInclude("libusockets.h");
    @cInclude("picohttpparser.h");
});