/// Provides a simple CLI for changing the behavior of firmware while running
/// Takes in a std.Io.Reader pointer to allow for changing input method
const Cli = @This();

const std = @import("std");
const main = @import("main.zig");
const heater_gpio = @import("HeaterControl.zig").heater_gpio;
const app_state: *main.AppState = &main.app_state;

reader: *std.Io.Reader,
const ErrAndUsage = struct {
    err_msg: []const u8,
    usage: []const u8,
};

fn logHandler(argv: []const []const u8) ?ErrAndUsage {
    const usage =
        \\log on - Turn on periodic logging of temperature, setpoint and heater duty cycle
        \\log off - Turn off logging
    ;

    if (argv.len < 1) return .{ .err_msg = "Expected \"on\" or \"off\"", .usage = usage };
    if (std.mem.eql(u8, argv[0], "on")) {
        app_state.temperature_logging = true;
    } else if (std.mem.eql(u8, argv[0], "off")) {
        app_state.temperature_logging = false;
    } else {
        return .{ .err_msg = "Expected \"on\" or \"off\"", .usage = usage };
    }

    return null;
}

fn tempHandler(_: []const []const u8) ?ErrAndUsage {
    if (app_state.rtd_measurement.current_temperature) |temp| {
        std.log.info("Temperature: {d:.1}", .{temp});
    } else {
        // It is incredibly unlikely a user is fast enough to see this :)
        return .{ .err_msg = "Wait for first temperature reading to be taken", .usage = "" };
    }

    return null;
}

fn heaterHandler(argv: []const []const u8) ?ErrAndUsage {
    const usage =
        \\heater on - Turn on heater
        \\heater off - Turn off heater
        \\Note this also stops temperature regulation loop
    ;

    if (argv.len < 1) return .{ .err_msg = "Expected \"on\" or \"off\"", .usage = usage };
    if (std.mem.eql(u8, argv[0], "on")) {
        std.log.info("Heater ON", .{});
        app_state.temperature_regulation.stop();
        heater_gpio.put(1);
    } else if (std.mem.eql(u8, argv[0], "off")) {
        std.log.info("Heater OFF", .{});
        app_state.temperature_regulation.stop();
        heater_gpio.put(0);
    } else {
        return .{ .err_msg = "Expected \"on\" or \"off\"", .usage = usage };
    }

    return null;
}

fn regHandler(argv: []const []const u8) ?ErrAndUsage {
    const usage =
        \\reg on - Turn on temperature regulation loop
        \\reg off - Turn off temperature regulation loop
        \\reg coffee - Change setpoint to coffee setpoint
        \\reg steam - Change setpoint to steam setpoint
    ;
    const err_msg = "Expected \"on\", \"off\", \"coffee\", or \"steam\"";
    if (argv.len < 1) return .{ .err_msg = err_msg, .usage = usage };
    if (std.mem.eql(u8, argv[0], "on")) {
        std.log.info("Starting temperature regulation loop", .{});
        app_state.temperature_regulation.start();
    } else if (std.mem.eql(u8, argv[0], "off")) {
        std.log.info("Stopping temperature regulation loop", .{});
        app_state.temperature_regulation.stop();
    } else if (std.mem.eql(u8, argv[0], "coffee")) {
        std.log.info("Changing setpoint to coffee", .{});
        app_state.temperature_regulation.coffeeMode();
    } else if (std.mem.eql(u8, argv[0], "steam")) {
        std.log.info("Changing setpoint to steam", .{});
        app_state.temperature_regulation.steamMode();
    } else {
        return .{ .err_msg = err_msg, .usage = usage };
    }

    return null;
}

const CommandHandlers = struct {
    const HandlerFnType = fn ([]const []const u8) ?ErrAndUsage;
    log: HandlerFnType = logHandler,
    temp: HandlerFnType = tempHandler,
    heater: HandlerFnType = heaterHandler,
    reg: HandlerFnType = regHandler,
};

const command_handlers: CommandHandlers = .{};

fn commandParser(cmd_line: []const u8) void {
    var line_reader = std.Io.Reader.fixed(cmd_line);

    // Hitting stream too long just means there aren't any args
    const cmd_slice =
        line_reader.takeDelimiterExclusive(' ') catch |err|
            switch (err) {
                error.EndOfStream, error.StreamTooLong => cmd_line,
                else => unreachable,
            };

    // Get the remainder of the args, maximum of 10 args is supported
    const max_num_args = 10;
    var args: [max_num_args][]const u8 = undefined;
    var curr_idx: usize = 0;
    while (line_reader.takeDelimiterExclusive(' ')) |arg| {
        // Accounts for multiple spaces in a row
        if (arg.len > 0) {
            std.debug.assert(curr_idx < max_num_args);
            args[curr_idx] = arg;
            curr_idx += 1;
        }
    } else |err| {
        switch (err) {
            error.EndOfStream, error.StreamTooLong => {},
            else => unreachable,
        }
    }

    // comptime loop selects the correct command handler based on its field name in CommandHandlers
    const ch_typeinfo = @typeInfo(CommandHandlers);
    inline for (ch_typeinfo.@"struct".fields) |field| {
        if (std.mem.eql(u8, cmd_slice, field.name)) {
            if (@field(command_handlers, field.name)(args[0..curr_idx])) |err_and_usage| {
                std.log.err("Command: {s} produced Error: {s}", .{ cmd_slice, err_and_usage.err_msg });
                std.log.err("Usage:\n{s}", .{err_and_usage.usage});
            }
            return;
        }
    }
    std.log.err("Unknown command: {s}", .{cmd_line});
}

pub fn doWork(self: *@This()) !void {
    const line_slice = self.reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return,
        else => return err,
    };

    // Trim any leading whitespace then send received line to parser
    var i: usize = 0;
    while (line_slice[i] == ' ') {
        i += 1;
    }
    commandParser(line_slice[i .. line_slice.len - 2]);
}
