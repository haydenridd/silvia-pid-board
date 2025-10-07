/// Provides a simple state machine for taking periodic temperature measurements without blocking waiting on a
/// conversion to finish. Performs periodic "one shot" measurements and sets bias according to datasheet timing
/// requirements.
const RtdMeasurement = @This();

const std = @import("std");
const microzig = @import("microzig");
const rp2040 = microzig.hal;
const spi = rp2040.spi;
const time = rp2040.time;

const State = enum {
    idle,
    vbias_settling,
    waiting_for_rdy,
};

state: State = .idle,
current_deadline_us: u64 = 0,
current_temperature: ?f32 = null,

const measurement_holdoff_ms = 100;

pub fn doWork(self: *RtdMeasurement, timestamp_us: u64) void {
    switch (self.state) {
        .idle => {
            if (timestamp_us >= self.current_deadline_us) {
                max31865.setBias(true);
                self.state = .vbias_settling;
                self.current_deadline_us = timestamp_us + max31865.vbias_settling_time_ms * 1000;
            }
        },
        .vbias_settling => {
            if (timestamp_us >= self.current_deadline_us) {
                max31865.startOneShot();
                self.state = .waiting_for_rdy;
            }
        },
        .waiting_for_rdy => {
            if (max31865.ready_pin.read() == 0) {
                self.current_temperature = max31865.temperatureFromRawRtd(max31865.readRtdRegs());
                self.current_deadline_us = timestamp_us + measurement_holdoff_ms * 1000;
                max31865.setBias(false);
                self.state = .idle;
            }
        },
    }
}

pub fn init(_: RtdMeasurement) void {
    max31865.init();
}

/// Implements a driver for the MAX31865 RTD sensor chip
pub const max31865 = struct {
    const Mask = struct {
        const one_shot: u8 = 0b00100000;
        const clear_fault: u8 = 0b00000010;
        const vbias: u8 = 0b10000000;
        const default_config: u8 = 0b00000000;
    };

    const Register = enum(u8) {
        config = 0x0,
        rtd_msb = 0x1,
        rtd_lsb = 0x2,
        high_fault_msb = 0x3,
        high_fault_lsb = 0x4,
        low_fault_msb = 0x5,
        low_fault_lsb = 0x6,
        fault_status = 0x7,

        pub fn writeReg(self: Register) u8 {
            return @intFromEnum(self) | 0x80;
        }
    };

    const spi0 = spi.instance.SPI0;
    const csn = rp2040.gpio.num(17);
    pub const ready_pin = rp2040.gpio.num(20);
    pub const vbias_settling_time_ms = 65;

    pub fn init() void {
        csn.set_function(.sio);
        csn.set_direction(.out);
        csn.put(1);

        ready_pin.set_function(.sio);
        ready_pin.set_direction(.in);

        const mosi = rp2040.gpio.num(19);
        const miso = rp2040.gpio.num(16);
        const sck = rp2040.gpio.num(18);
        inline for (&.{ mosi, miso, sck }) |pin| {
            pin.set_function(.spi);
        }

        const baud_rate = 500_000;
        const cfg = spi.Config{
            .clock_config = rp2040.clock_config,
            .baud_rate = baud_rate,
            .frame_format = .{ .motorola = .{ .clock_phase = .second_edge } },
        };
        spi0.apply(cfg) catch unreachable;
        time.sleep_ms(10);
        clearFaults();
        setBias(false);
        time.sleep_ms(vbias_settling_time_ms);
        // Clear out any pending reads that might be holding RDY pin low
        _ = readRtdRegs();
    }

    pub fn clearFaults() void {
        const data: u8 = Mask.default_config | Mask.clear_fault;
        csn.put(0);
        spi0.write_blocking(u8, &.{ Register.config.writeReg(), data });
        csn.put(1);
    }

    pub fn setBias(val: bool) void {
        const data: u8 = Mask.default_config | (if (val) Mask.vbias else 0);
        csn.put(0);
        spi0.write_blocking(u8, &.{ Register.config.writeReg(), data });
        csn.put(1);
    }

    pub fn startOneShot() void {
        // Have to leave bias on for oneshot conversion!
        const data: u8 = Mask.default_config | Mask.one_shot | Mask.vbias;
        csn.put(0);
        spi0.write_blocking(u8, &.{ Register.config.writeReg(), data });
        csn.put(1);
    }

    pub fn readFaultStatus() u8 {
        var data: [2]u8 = undefined;
        csn.put(0);
        spi0.transceive_blocking(u8, &.{ @intFromEnum(Register.fault_status), 0x0 }, &data);
        csn.put(1);
        return data[1];
    }

    pub fn readConfig() u8 {
        var data: [2]u8 = undefined;
        csn.put(0);
        spi0.transceive_blocking(u8, &.{ @intFromEnum(Register.config), 0x0 }, &data);
        csn.put(1);
        return data[1];
    }

    /// Combines RTD regs into a single u15, as bit0 (whether a fault occurred) is discarded
    pub fn readRtdRegs() u15 {
        var data: [3]u8 = undefined;
        csn.put(0);
        spi0.transceive_blocking(u8, &.{ @intFromEnum(Register.rtd_msb), 0x0, 0x0 }, &data);
        csn.put(1);
        const ret: u15 = (@as(u15, data[1]) << 7) | @as(u15, data[2] >> 1);
        return ret;
    }

    pub fn pollForReady() !void {
        var elapsed_time: usize = 0;
        const increment_us = 100;
        const timeout_us = 60 * 1000;
        while ((ready_pin.read() > 0) and (elapsed_time < timeout_us)) {
            time.sleep_us(increment_us);
            elapsed_time += increment_us;
        }
        if (elapsed_time >= timeout_us) return error.Timeout;
    }

    pub fn convertAndReadRtdBlocking() u15 {
        setBias(true);
        time.sleep_ms(vbias_settling_time_ms);
        startOneShot();
        pollForReady() catch std.debug.panic("Timeout waiting for RDY pin", .{});
        const val = readRtdRegs();
        setBias(false);
        return val;
    }

    pub fn temperatureFromRawRtd(rtd_raw: u15) f32 {
        const rtd_a = 3.9083e-3;
        const rtd_b = -5.775e-7;
        const z1 = -rtd_a;
        const z2 = rtd_a * rtd_a - (4 * rtd_b);
        const z3 = (4 * rtd_b) / 100.0;
        const z4 = 2 * rtd_b;
        const reference_resistor = 430;
        const rt: f32 = (@as(f32, @floatFromInt(rtd_raw)) / 32768.0) * reference_resistor;
        const temp: f32 = (std.math.sqrt(z2 + (z3 * rt)) + z1) / z4;
        // TODO: If this ever hits, need to implement Adafruit's method, but
        // we shouldn't need to since we are always looking at temperatures > 0
        std.debug.assert(temp > 0);
        return temp;
    }

    pub fn getTemperatureBlocking() f32 {
        const rtd_raw = convertAndReadRtdBlocking();
        return temperatureFromRawRtd(rtd_raw);
    }
};
