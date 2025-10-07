const std = @import("std");
const microzig = @import("microzig");
const rtt = microzig.cpu.rtt;
const irq = @import("irq.zig");
const rp2040 = microzig.hal;
const time = rp2040.time;
const HeaterControl = @import("HeaterControl.zig");
const TemperatureRegulation = @import("TemperatureRegulation.zig");
const RtdMeasurement = @import("RtdMeasurement.zig");
const DataLogger = @import("DataLogger.zig");
const Cli = @import("Cli.zig");

const rtt_inst = rtt.RTT(.{});
var rtt_logger: ?rtt_inst.Writer = null;
// This implies a max line size of 128 characters for RTT reading
var read_buffer: [128]u8 = undefined;
var rtt_reader = rtt_inst.reader(0, &read_buffer);

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_prefix = comptime "[{}.{:0>6}] " ++ level.asText();
    const prefix = comptime level_prefix ++ switch (scope) {
        .default => ": ",
        else => " (" ++ @tagName(scope) ++ "): ",
    };

    if (rtt_logger) |*writer| {
        const current_time = time.get_time_since_boot();
        const seconds = current_time.to_us() / std.time.us_per_s;
        const microseconds = current_time.to_us() % std.time.us_per_s;

        writer.interface.print(prefix ++ format ++ "\r\n", .{ seconds, microseconds } ++ args) catch {};
    }
}

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {

    // ALWAYS turn off heater
    HeaterControl.heater_gpio.put(0);

    // utilize logging functions
    std.log.err("PANIC: {s}", .{message});

    var index: usize = 0;
    var iter = std.debug.StackIterator.init(@returnAddress(), null);
    while (iter.next()) |address| : (index += 1) {
        if (index == 0) {
            std.log.err("stack trace:", .{});
        }
        std.log.err("{d: >3}: 0x{X:0>8}", .{ index, address });
    }

    if (@import("builtin").mode == .Debug) {
        // attach a breakpoint, this might trigger another
        // panic internally, so only do that in debug mode.
        std.log.info("triggering breakpoint...", .{});
        @breakpoint();
    }

    microzig.hang();
}

pub const microzig_options = microzig.Options{
    .logFn = log,
    .interrupts = .{
        .IO_IRQ_BANK0 = .{ .c = &irq.gpio },
        .HardFault = .{ .c = &irq.hardFault },
        .TIMER_IRQ_0 = .{ .c = &irq.alarmExpired },
    },
};

const Blink = struct {
    const onboard_led_gpio = rp2040.gpio.num(25);
    const blink_period_ms = 1000;
    blink_deadline: u64 = 0,

    pub fn init(self: *Blink, timestamp_us: u64) void {
        onboard_led_gpio.set_direction(.out);
        onboard_led_gpio.set_function(.sio);
        onboard_led_gpio.put(1);
        self.blink_deadline = timestamp_us + blink_period_ms * 1000;
    }

    pub fn doWork(self: *Blink, timestamp_us: u64) void {
        if (timestamp_us >= self.blink_deadline) {
            onboard_led_gpio.toggle();
            self.blink_deadline = timestamp_us + blink_period_ms * 1000;
        }
    }
};

pub const AppState = struct {
    blink: Blink = .{},
    data_logger: DataLogger = .{},
    temperature_regulation: TemperatureRegulation = .{},
    rtd_measurement: RtdMeasurement = .{},
    cli: Cli = .{ .reader = &rtt_reader.interface },
    temperature_logging: bool = false,
    pub fn init(self: *AppState, timestamp_us: u64) void {
        self.rtd_measurement.init();
        self.blink.init(timestamp_us);
        self.data_logger.init(timestamp_us);
        self.temperature_regulation.init();
    }
};

pub var app_state: AppState = .{};

pub fn main() !void {
    rtt_inst.init();
    rtt_logger = rtt_inst.writer(0, &.{});
    irq.init();
    app_state.init(time.get_time_since_boot().to_us());
    std.log.info("BOOT", .{});

    // Steam switch detection via zero crossing signal is handled entirely by interrupts, this variable caches
    // value to only change regulation mode when value changes
    var cached_steam_state: bool = false;

    while (true) {
        if (cached_steam_state != irq.steam_enabled) {
            cached_steam_state = irq.steam_enabled;
            if (cached_steam_state) {
                std.log.info("Switching to Steam setpoint", .{});
                app_state.temperature_regulation.steamMode();
            } else {
                std.log.info("Switching to Coffee setpoint", .{});
                app_state.temperature_regulation.coffeeMode();
            }
        }

        try app_state.cli.doWork();
        app_state.blink.doWork(time.get_time_since_boot().to_us());
        app_state.rtd_measurement.doWork(time.get_time_since_boot().to_us());
        if (app_state.rtd_measurement.current_temperature) |v| {
            try app_state.data_logger.doWork(
                time.get_time_since_boot().to_us(),
                v,
                app_state.temperature_regulation.heater_control.duty_cycle,
                app_state.temperature_regulation.setpoint,
                app_state.temperature_logging,
            );
            app_state.temperature_regulation.doWork(time.get_time_since_boot().to_us(), v);
        }
    }
}
