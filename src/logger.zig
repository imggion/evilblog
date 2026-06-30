//! Tiny structured logging wrapper over `std.log`.
const std = @import("std");

pub const Level = std.log.Level;

pub const Logger = struct {
    level: Level,

    pub fn init(level: Level) Logger {
        return .{ .level = level };
    }

    pub fn enabled(self: Logger, level: Level) bool {
        return @intFromEnum(level) <= @intFromEnum(self.level);
    }

    pub fn err(self: Logger, comptime event: []const u8, comptime fields_format: []const u8, args: anytype) void {
        self.write(.err, event, fields_format, args);
    }

    pub fn warn(self: Logger, comptime event: []const u8, comptime fields_format: []const u8, args: anytype) void {
        self.write(.warn, event, fields_format, args);
    }

    pub fn info(self: Logger, comptime event: []const u8, comptime fields_format: []const u8, args: anytype) void {
        self.write(.info, event, fields_format, args);
    }

    pub fn debug(self: Logger, comptime event: []const u8, comptime fields_format: []const u8, args: anytype) void {
        self.write(.debug, event, fields_format, args);
    }

    fn write(self: Logger, comptime level: Level, comptime event: []const u8, comptime fields_format: []const u8, args: anytype) void {
        if (!self.enabled(level)) return;

        const timestamp = isoTimestampUtc(std.Io.Clock.Timestamp.now(std.Options.debug_io, .real).raw.toSeconds());
        if (comptime fields_format.len == 0) {
            switch (level) {
                .err => std.log.err("timestamp={s} event=" ++ event, .{timestamp}),
                .warn => std.log.warn("timestamp={s} event=" ++ event, .{timestamp}),
                .info => std.log.info("timestamp={s} event=" ++ event, .{timestamp}),
                .debug => std.log.debug("timestamp={s} event=" ++ event, .{timestamp}),
            }
            return;
        }

        switch (level) {
            .err => std.log.err("timestamp={s} event=" ++ event ++ " " ++ fields_format, .{timestamp} ++ args),
            .warn => std.log.warn("timestamp={s} event=" ++ event ++ " " ++ fields_format, .{timestamp} ++ args),
            .info => std.log.info("timestamp={s} event=" ++ event ++ " " ++ fields_format, .{timestamp} ++ args),
            .debug => std.log.debug("timestamp={s} event=" ++ event ++ " " ++ fields_format, .{timestamp} ++ args),
        }
    }
};

fn isoTimestampUtc(seconds: i64) [20]u8 {
    const unix_seconds: u64 = @intCast(@max(seconds, 0));
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = unix_seconds };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    var buffer: [20]u8 = undefined;
    _ = std.fmt.bufPrint(&buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch unreachable;
    return buffer;
}

test "info level suppresses debug" {
    const log = Logger.init(.info);

    try std.testing.expect(log.enabled(.err));
    try std.testing.expect(log.enabled(.warn));
    try std.testing.expect(log.enabled(.info));
    try std.testing.expect(!log.enabled(.debug));
}

test "debug level allows debug" {
    const log = Logger.init(.debug);

    try std.testing.expect(log.enabled(.debug));
}

test "formats UTC timestamp as ISO 8601" {
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", &isoTimestampUtc(0));
    try std.testing.expectEqualStrings("2021-06-05T20:28:26Z", &isoTimestampUtc(1622924906));
}
