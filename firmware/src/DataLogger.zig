/// Outputs streaming temperature data to a UART pin
/// Also optionally outputs this data in human readable format to std.log.info
const DataLogger = @This();

const std = @import("std");
const microzig = @import("microzig");
const rp2040 = microzig.hal;
const Duration = microzig.drivers.time.Duration;
const baud_rate = 115200;
const uart = rp2040.uart.instance.num(0);
const temp_sample_period_ms = 500;

temp_log_deadline_us: u64 = 0,

pub fn init(self: *DataLogger, timestamp_us: u64) void {
    self.temp_log_deadline_us = timestamp_us + temp_sample_period_ms * 1000;
    const uart_tx_pin = rp2040.gpio.num(12);
    uart_tx_pin.set_function(.uart);
    uart.apply(.{
        .baud_rate = baud_rate,
        .clock_config = rp2040.clock_config,
    });
}

pub fn doWork(
    self: *DataLogger,
    timestamp_us: u64,
    current_temperature: f32,
    heater_dc: u7,
    setpoint: f32,
    debug_log: bool,
) !void {
    if (timestamp_us >= self.temp_log_deadline_us) {
        var buf: [20]u8 = undefined;
        const uart_slice = try std.fmt.bufPrint(&buf, "{d:.1},{d},{d:.1}\r\n", .{ current_temperature, heater_dc, setpoint });
        try uart.write_blocking(uart_slice, Duration.from_ms(50));
        self.temp_log_deadline_us = timestamp_us + temp_sample_period_ms * 1000;
        if (debug_log) std.log.info("Temperature: {d:.1} Duty Cycle: {d} Setpoint: {d:.1}", .{ current_temperature, heater_dc, setpoint });
    }
}
