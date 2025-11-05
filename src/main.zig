const std = @import("std");
const dish = @import("dish");
const posix = std.posix;
const linux = std.os.linux;

fn helloCmd(_: []const []const u8, out: dish.Output) void {
    out("Hello World\r\n");
}

pub fn output(str: []const u8) void {
    var stdout = std.fs.File.stdout().writerStreaming(&.{});
    stdout.interface.print("{s}", .{str}) catch @panic("Cannot Write to Output\r\n");
}

fn enableRaw(fd: posix.fd_t) !posix.termios {
    var tio = try posix.tcgetattr(fd);
    const orig = tio; // save to restore

    // ----- Make "raw" (cfmakeraw-equivalent) via bitfields -----
    // input flags
    tio.iflag.IGNBRK = false;
    tio.iflag.BRKINT = false;
    tio.iflag.ICRNL = true; // default to using '\n' for newline
    tio.iflag.INLCR = false;
    tio.iflag.PARMRK = false;
    tio.iflag.ISTRIP = false;
    tio.iflag.IXON = false;

    // output flags
    tio.oflag.OPOST = false;

    // local flags
    tio.lflag.ECHO = false;
    tio.lflag.ECHONL = false;
    tio.lflag.ICANON = false;
    tio.lflag.IEXTEN = false;
    tio.lflag.ISIG = true; // Allow for easy exit vai signals

    // control flags
    //
    //tio.cflag.CSIZE = false; // clear size bits first (bitfield API exposes them as flags)
    tio.cflag.PARENB = false;
    //tio.cflag.CS8 = true; // set 8-bit chars

    // read returns per keystroke
    tio.cc[@intFromEnum(linux.V.MIN)] = 1;
    tio.cc[@intFromEnum(linux.V.TIME)] = 0;

    try posix.tcsetattr(fd, .FLUSH, tio);
    return orig;
}

pub fn main() !void {
    try dish.register_cmd("hello", "Prints 'Hello World'", helloCmd);
    try dish.register_output(output, true);

    //var stdin = std.fs.File.stdin().readerStreaming(&.{});

    //var buf: [10]u8 = undefined;
    //var vec = [_][]u8{buf[0..]};
    //while (stdin.interface.readVec(vec[0..])) |r| {
    //    if (r > 0) {
    //        (dish.register_input())(buf[0..r]);
    //    }
    //} else |e| return e;
    //
    const stdin_file = std.fs.File.stdin();
    const fd = stdin_file.handle;

    // Put TTY into raw mode; restore on exit.
    const orig = try enableRaw(fd);
    defer posix.tcsetattr(fd, .FLUSH, orig) catch {};

    // Read raw bytes and feed directly to your CLI
    var buf: [256]u8 = undefined;
    while (true) {
        const n = try posix.read(fd, &buf);
        if (n == 0) break; // EOF
        (dish.register_input())(buf[0..n]);
    }
}
